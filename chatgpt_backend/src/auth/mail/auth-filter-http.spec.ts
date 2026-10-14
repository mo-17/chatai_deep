import {
  BadRequestException,
  Controller,
  Get,
  Logger,
  ServiceUnavailableException,
  ValidationPipe,
  type INestApplication,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { QueryFailedError } from 'typeorm';
import { AllExceptionsFilter } from '../../common/all-exceptions.filter';
import { AuthController } from '../../../libs/auth-kit/src/controllers/auth.controller';
import { VerificationService } from '../../../libs/auth-kit/src/verification/verification.service';
import { AuthSettingsService } from '../../../libs/auth-kit/src/settings/auth-settings.service';
import { AUTH_KIT_OPTIONS } from '../../../libs/auth-kit/src/auth-kit.tokens';
import { AuthKitJwtGuard } from '../../../libs/auth-kit/src/guards/auth-kit-auth.guard';
let injected: Error;
@Controller('uapi/auth/filter-fixture')
class FailureController {
  @Get() fail() {
    throw injected;
  }
}
/** 生产global filter+实际HTTP/AuthController；验证码业务失败由合成service注入，不访问DB/邮箱。 */
describe('P2 production global filter safe feedback and generic auth logging', () => {
  let app: INestApplication, logs: jest.SpyInstance;
  beforeAll(async () => {
    logs = jest.spyOn(Logger.prototype, 'error').mockImplementation(() => {});
    const module = await Test.createTestingModule({
      controllers: [AuthController, FailureController],
      providers: [
        AuthKitJwtGuard,
        {
          provide: AUTH_KIT_OPTIONS,
          useValue: {
            userResolver: {
              findByEmail: () => Promise.resolve({ id: 1, password: null }),
            },
            jwtSigner: {},
            accessTokenVerifier: { verify: () => Promise.resolve(null) },
          },
        },
        {
          provide: VerificationService,
          useValue: {
            consumeWith: () => Promise.reject(injected),
            generateAndSendCode: () => Promise.reject(injected),
          },
        },
        { provide: AuthSettingsService, useValue: {} },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    await app.init();
  });
  beforeEach(() => logs.mockClear());
  afterAll(async () => {
    await app?.close();
    logs.mockRestore();
  });
  const http = () =>
    request(app.getHttpServer() as Parameters<typeof request>[0]);
  function expectSafeLogs() {
    expect(logs).toHaveBeenCalled();
    const data = JSON.stringify(logs.mock.calls);
    expect(data).not.toMatch(
      /synthetic-secret|synthetic-token|synthetic-code|SELECT|remainingPayload|123456/,
    );
    expect(data).toContain('authentication_request_failed');
    expect(data).not.toContain('?');
  }
  it.each([
    '验证码已过期，请重新获取',
    '验证码错误次数过多，已锁定，请重新获取',
    '验证码错误，剩余 3 次尝试',
  ])('real code-login HTTP preserves safe feedback: %s', async (message) => {
    injected = new BadRequestException(message);
    const r = await http()
      .post('/uapi/auth/login/code?token=synthetic-token&code=synthetic-code')
      .send({
        channel: 'email',
        identifier: 'User@synthetic.invalid',
        code: '123456',
      });
    expect(r.status).toBe(400);
    expect((r.body as { message: string }).message).toBe(message);
    expectSafeLogs();
  });
  it('real send-code HTTP preserves resend guidance', async () => {
    injected = new BadRequestException('请稍后再发送验证码');
    const r = await http()
      .post('/uapi/auth/code/send?secret=synthetic-secret')
      .send({
        channel: 'email',
        identifier: 'User@synthetic.invalid',
        purpose: 'login',
      });
    expect(r.status).toBe(400);
    expect((r.body as { message: string }).message).toBe('请稍后再发送验证码');
    expectSafeLogs();
  });
  it('real password-login HTTP tells a passwordless account to use code login', async () => {
    const r = await http()
      .post('/uapi/auth/login/password?token=synthetic-token')
      .send({
        channel: 'email',
        identifier: 'User@synthetic.invalid',
        password: 'synthetic-secret',
      });
    expect(r.status).toBe(400);
    expect((r.body as { message: string }).message).toBe(
      '该账号未设置密码，请使用验证码登录',
    );
    expectSafeLogs();
  });
  it('allowlisted Microsoft error is actionable and exposes its safe code only', async () => {
    injected = new ServiceUnavailableException({
      message: 'microsoft_needs_reauth',
      remainingPayload: 'synthetic-secret',
    });
    const r = await http().get(
      '/uapi/auth/filter-fixture?token=synthetic-token',
    );
    expect((r.body as { message: string; errorCode: string }).message).toBe(
      '邮箱授权已失效，请重新授权',
    );
    expect((r.body as { errorCode: string }).errorCode).toBe(
      'microsoft_needs_reauth',
    );
    expect(JSON.stringify(r.body)).not.toContain('synthetic-secret');
    expectSafeLogs();
  });
  it.each(['sql', 'http', 'prefix', 'suffix', 'numeric'] as const)(
    'unknown %s exception never exposes synthetic secrets/SQL/code/token',
    async (kind) => {
      injected =
        kind === 'sql'
          ? new QueryFailedError(
              'SELECT synthetic-secret',
              ['synthetic-token', 'synthetic-code'],
              Error('synthetic-secret'),
            )
          : new BadRequestException({
              message:
                kind === 'prefix'
                  ? 'microsoft_synthetic-secret'
                  : kind === 'suffix'
                    ? '验证码已过期，请重新获取 synthetic-token'
                    : kind === 'numeric'
                      ? '验证码错误，剩余 123456 次尝试'
                      : 'synthetic-secret synthetic-token synthetic-code SELECT',
              remainingPayload: 'synthetic-secret',
            });
      const r = await http().get(
        '/uapi/auth/filter-fixture?code=synthetic-code',
      );
      expect((r.body as { message: string }).message).toBe('认证请求失败');
      expect(JSON.stringify(r.body)).not.toMatch(
        /synthetic-secret|synthetic-token|synthetic-code|SELECT|123456/,
      );
      expectSafeLogs();
    },
  );
  it('safe message never brings arbitrary HttpException fields into response/log', async () => {
    injected = new BadRequestException({
      message: '验证码已过期，请重新获取',
      remainingPayload:
        'synthetic-secret SELECT synthetic-code synthetic-token',
    });
    const r = await http().get('/uapi/auth/filter-fixture?code=synthetic-code');
    expect((r.body as { message: string }).message).toBe(
      '验证码已过期，请重新获取',
    );
    expect(JSON.stringify(r.body)).not.toMatch(
      /remainingPayload|synthetic-secret|SELECT/,
    );
    expectSafeLogs();
  });
});
