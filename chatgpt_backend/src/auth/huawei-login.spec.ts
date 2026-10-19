import { HuaweiService } from '../../libs/auth-kit/src/third-party/huawei/huawei.service';
import { ThirdPartyController } from '../../libs/auth-kit/src/controllers/third-party.controller';
import type { AuthKitModuleOptions } from '../../libs/auth-kit/src/auth-kit.module';
import * as jwt from 'jsonwebtoken';

const info = {
  type: 0,
  client_id: '123456',
  expire_in: 3600,
  union_id: 'verified-union',
  open_id: 'verified-open',
};
const token = {
  token_type: 'Bearer',
  access_token: 'server-access-token',
  expires_in: 3600,
};
const response = (body: unknown, init?: ResponseInit) =>
  new Response(JSON.stringify(body), init);

describe('Huawei server verification', () => {
  const savedEnv = { ...process.env };
  let fetchMock: jest.SpiedFunction<typeof fetch>;
  let service: HuaweiService;
  beforeEach(() => {
    process.env.HUAWEI_CLIENT_ID = '123456';
    process.env.HUAWEI_CLIENT_SECRET = 'test-secret';
    delete process.env.HUAWEI_APP_ID;
    delete process.env.HUAWEI_APP_SECRET;
    fetchMock = jest.spyOn(globalThis, 'fetch');
    service = new HuaweiService();
  });
  afterEach(() => {
    process.env = savedEnv;
    jest.restoreAllMocks();
    jest.useRealTimers();
  });

  it('exchanges code once using form encoding, then verifies audience and user identity', async () => {
    fetchMock
      .mockResolvedValueOnce(response(token))
      .mockResolvedValueOnce(response(info));
    await expect(service.verifyAuthCode('A+/=code')).resolves.toEqual({
      unionId: 'verified-union',
      openId: 'verified-open',
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const [url, request] = fetchMock.mock.calls[0];
    expect(url).toBe('https://oauth-login.cloud.huawei.com/oauth2/v3/token');
    expect(request).toMatchObject({ method: 'POST', redirect: 'error' });
    const body = new URLSearchParams(request!.body as string);
    expect(Object.fromEntries(body)).toEqual({
      grant_type: 'authorization_code',
      client_id: '123456',
      client_secret: 'test-secret',
      code: 'A+/=code',
      supportAlg: 'PS256',
    });
    expect(fetchMock.mock.calls[1][0]).toBe(
      'https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo',
    );
    expect(
      Object.fromEntries(
        new URLSearchParams(fetchMock.mock.calls[1][1]!.body as string),
      ),
    ).toEqual({ access_token: 'server-access-token', open_id: 'OPENID' });
  });
  it('legacy env aliases remain supported', async () => {
    delete process.env.HUAWEI_CLIENT_ID;
    delete process.env.HUAWEI_CLIENT_SECRET;
    process.env.HUAWEI_APP_ID = '123456';
    process.env.HUAWEI_APP_SECRET = 'legacy-test-secret';
    fetchMock
      .mockResolvedValueOnce(response(token))
      .mockResolvedValueOnce(response(info));
    await service.verifyAuthCode('code');
  });
  it('missing credentials fail before contacting Huawei', async () => {
    delete process.env.HUAWEI_CLIENT_SECRET;
    await expect(service.verifyAuthCode('code')).rejects.toMatchObject({
      status: 503,
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it.each([undefined, null, {}, '', 'space code', 'x'.repeat(16385)])(
    'rejects malformed credential %#',
    async (value) => {
      await expect(
        service.verifyAuthCode(value as string),
      ).rejects.toMatchObject({ status: 400 });
      expect(fetchMock).not.toHaveBeenCalled();
    },
  );
  it.each([
    { ...info, client_id: 'another-app' },
    { ...info, type: 1 },
    { ...info, expire_in: 0 },
    { ...info, union_id: '' },
    { ...info, open_id: null },
    { ...info, type: '0' },
  ])('rejects untrusted audience/type/identity %#', async (data) => {
    fetchMock.mockResolvedValueOnce(response(data));
    await expect(
      service.verifyQuickLoginToken('client-token'),
    ).rejects.toMatchObject({ status: 400 });
  });
  it.each([
    response({ error: 'secret-provider-detail' }),
    response(info, { headers: { NSP_STATUS: '102' } }),
    response({ error_description: 'secret-provider-detail' }, { status: 400 }),
  ])(
    'rejects provider business errors including HTTP 200 %#',
    async (result) => {
      fetchMock.mockResolvedValueOnce(result);
      await expect(
        service.verifyQuickLoginToken('client-token'),
      ).rejects.toMatchObject({
        status: 400,
        message: '华为账号授权无效，请重新登录',
      });
    },
  );
  it('invalid token exchange never proceeds to identity lookup', async () => {
    fetchMock.mockResolvedValueOnce(
      response({ ...token, token_type: 'invalid' }),
    );
    await expect(service.verifyAuthCode('code')).rejects.toMatchObject({
      status: 400,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it('network exceptions are sanitized and never retried', async () => {
    fetchMock.mockRejectedValueOnce(new Error('secret-url-and-token'));
    await expect(service.verifyAuthCode('code')).rejects.toMatchObject({
      status: 502,
      message: '华为账号服务暂不可用，请稍后重试',
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it('aborts a stalled request at the deadline', async () => {
    jest.useFakeTimers();
    fetchMock.mockImplementationOnce(
      (_url, options) =>
        new Promise((_resolve, reject) => {
          options!.signal!.addEventListener('abort', () =>
            reject(new Error('aborted')),
          );
        }),
    );
    const result = expect(service.verifyAuthCode('code')).rejects.toMatchObject(
      { status: 502 },
    );
    await jest.advanceTimersByTimeAsync(8000);
    await result;
    expect(jest.getTimerCount()).toBe(0);
  });
  it('bounds streamed response bytes and cancels the body', async () => {
    let cancelled = false;
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(65537));
      },
      cancel() {
        cancelled = true;
      },
    });
    fetchMock.mockResolvedValueOnce(new Response(body));
    await expect(service.verifyQuickLoginToken('token')).rejects.toMatchObject({
      status: 502,
    });
    expect(cancelled).toBe(true);
  });
  it.each(['not-json', '[]', 'null'])(
    'rejects malformed upstream response %s',
    async (data) => {
      fetchMock.mockResolvedValueOnce(new Response(data));
      await expect(
        service.verifyQuickLoginToken('token'),
      ).rejects.toMatchObject({ status: 502 });
    },
  );
  it('server errors do not leak raw response bodies', async () => {
    fetchMock.mockResolvedValueOnce(new Response('secret', { status: 503 }));
    await expect(service.verifyAuthCode('code')).rejects.toMatchObject({
      status: 502,
      message: '华为账号服务暂不可用，请稍后重试',
    });
  });

  it.each([false, true])(
    'verified identity reaches existing login/bind flow (bound=%s)',
    async (bound) => {
      fetchMock
        .mockResolvedValueOnce(response(token))
        .mockResolvedValueOnce(response(info));
      const resolver = {
        findByHuaweiUnionId: jest
          .fn()
          .mockResolvedValue(
            bound
              ? { id: 7, userName: 'bound-user', role: 'user', tokenVersion: 1 }
              : null,
          ),
        createPendingThirdPartyUser: jest.fn().mockResolvedValue({ id: 8 }),
      };
      const signer = { sign: jest.fn().mockReturnValue('application-session') };
      const options = {
        userResolver: resolver,
        jwtSigner: signer,
        appSecretKey: 'huawei-test-binding-key-'.repeat(3),
      } as unknown as AuthKitModuleOptions;
      const controller = new ThirdPartyController(
        {} as never,
        service,
        {} as never,
        options,
      );
      const result = await controller.huaweiLogin({
        mode: 'getAuthCode',
        authCode: 'code',
      });
      expect(resolver.findByHuaweiUnionId).toHaveBeenCalledWith(
        'verified-union',
      );
      if (bound) {
        expect(result.data).toBe('application-session');
        expect(resolver.createPendingThirdPartyUser).not.toHaveBeenCalled();
      } else {
        expect(resolver.createPendingThirdPartyUser).toHaveBeenCalledWith({
          provider: 'huawei',
          unionId: 'verified-union',
          openId: 'verified-open',
        });
        const binding = result.data as {
          needBinding: boolean;
          bindTicket: string;
        };
        expect(binding.needBinding).toBe(true);
        expect(
          jwt.verify(binding.bindTicket, options.appSecretKey, {
            audience: 'auth-kit:third-party-bind',
            issuer: 'auth-kit',
          }),
        ).toMatchObject({ sub: '8', provider: 'huawei' });
        expect(signer.sign).not.toHaveBeenCalled();
      }
    },
  );
});

// 请求模式必须遵循对应开关，不能借另一个模式已启用绕过后台配置。
import { Reflector } from '@nestjs/core';
import {
  ThirdPartyEnabledGuard,
  HUAWEI_LOGIN_MODE_KEY,
  THIRD_PARTY_KEY,
} from '../../libs/auth-kit/src/third-party/third-party-enabled.guard';

describe('Huawei mode switches', () => {
  it.each([
    ['getAuthCode', true, false, true],
    ['getAuthCode', false, true, false],
    ['quickLogin', false, true, true],
    ['quickLogin', true, false, false],
    ['unexpected', true, true, false],
  ])(
    'mode %s respects independent settings',
    async (mode, codeEnabled, quickEnabled, allowed) => {
      const reflector = new Reflector();
      const handler = () => {};
      Reflect.defineMetadata(THIRD_PARTY_KEY, 'huawei', handler);
      Reflect.defineMetadata(HUAWEI_LOGIN_MODE_KEY, true, handler);
      const settings = {
        get: () =>
          Promise.resolve({
            huaweiGetAuthCodeEnabled: codeEnabled,
            huaweiQuickLoginEnabled: quickEnabled,
          }),
      };
      const guard = new ThirdPartyEnabledGuard(reflector, settings as never);
      const context = {
        getHandler: () => handler,
        getClass: () => Object,
        switchToHttp: () => ({ getRequest: () => ({ body: { mode } }) }),
      } as never;
      if (allowed) await expect(guard.canActivate(context)).resolves.toBe(true);
      else
        await expect(guard.canActivate(context)).rejects.toMatchObject({
          status: 403,
        });
    },
  );
  it('controller opts in to mode checking', () => {
    expect(
      Reflect.getMetadata(
        HUAWEI_LOGIN_MODE_KEY,
        // eslint-disable-next-line @typescript-eslint/unbound-method -- 仅读取方法上的 Nest 元数据，不调用方法。
        ThirdPartyController.prototype.huaweiLogin,
      ),
    ).toBe(true);
  });
});
