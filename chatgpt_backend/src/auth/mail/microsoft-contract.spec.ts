import { createHash, generateKeyPairSync } from 'node:crypto';
import * as jwt from 'jsonwebtoken';
import {
  MicrosoftSmtpCipher,
  digest,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.crypto';
import {
  MicrosoftSmtpTransport,
  MicrosoftSmtpError,
  MS_AUTHORIZE,
  MS_DISCOVERY,
  MS_ISSUER,
  MS_JWKS,
  MS_TENANT,
  MS_TOKEN,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.transport';
import {
  MicrosoftSmtpCallbackController,
  MicrosoftSmtpAdminController,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.controller';
import { MicrosoftSmtpService } from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.service';
import { isAuthPath, logUrl } from '../../common/auth-log-safety';
const client = 'f03291c6-5cbc-4c03-a67b-5a18934a4321',
  nonce = 'synthetic-nonce',
  secret = 'synthetic-mail-contract-app-key-0123456789abcdef';
const pair = generateKeyPairSync('rsa', { modulusLength: 2048 }),
  other = generateKeyPairSync('rsa', { modulusLength: 2048 });
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
const metadata = {
  issuer: MS_ISSUER,
  authorization_endpoint: MS_AUTHORIZE,
  token_endpoint: MS_TOKEN,
  jwks_uri: MS_JWKS,
};
const jwks = {
  keys: [
    {
      ...pair.publicKey.export({ format: 'jwk' }),
      kid: 'fixture-rsa',
      use: 'sig',
      alg: 'RS256',
    },
  ],
};
const claims = () => ({
  sub: 'stable-subject',
  tid: MS_TENANT,
  nonce,
  exp: Math.floor(Date.now() / 1000) + 120,
});
function signed(
  patch: Record<string, unknown> = {},
  config: jwt.SignOptions = {},
) {
  return jwt.sign({ ...claims(), ...patch }, pair.privateKey, {
    algorithm: 'RS256',
    keyid: 'fixture-rsa',
    issuer: MS_ISSUER,
    audience: client,
    ...config,
  });
}
function transport(change?: (url: string) => Response) {
  return new MicrosoftSmtpTransport(async (url, init) => {
    await Promise.resolve();
    expect(init.redirect).toBe('error');
    return change?.(url) ?? json(url === MS_DISCOVERY ? metadata : jwks);
  });
}
describe('O1 fixed endpoint, encrypted secrets, OIDC and callback contract', () => {
  it('cipher AAD rejects wrong provider/purpose/context/tamper and supports long RT', () => {
    const c = new MicrosoftSmtpCipher(secret),
      value = 'synthetic-refresh'.repeat(1000),
      sealed = c.seal(value, 1, 'refresh', '2');
    expect(c.open(sealed, 1, 'refresh', '2')).toBe(value);
    expect(() => c.open(sealed, 2, 'refresh', '2')).toThrow();
    expect(() => c.open(sealed, 1, 'access', '2')).toThrow();
    expect(() => c.open(sealed, 1, 'refresh', '3')).toThrow();
    expect(() =>
      c.open(sealed.slice(0, -2) + 'ff', 1, 'refresh', '2'),
    ).toThrow();
    expect(sealed).not.toContain(value);
  });
  it('missing/default APP_SECRET fails closed', () => {
    expect(() => new MicrosoftSmtpCipher('CHANGE_ME')).toThrow();
  });
  it('PKCE SHA256 has standard S256 encoding', () => {
    expect(
      Buffer.from(
        digest('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'hex',
      ).toString('base64url'),
    ).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });
  it('valid RS256 consumers identity uses stable subject and issuer', async () => {
    expect(
      await transport().identity(
        signed(),
        client,
        digest(nonce),
        new AbortController().signal,
      ),
    ).toEqual({
      subject: 'stable-subject',
      issuer: MS_ISSUER,
      emailHint: null,
    });
  });
  it.each([
    'issuer',
    'audience',
    'expiry',
    'nonce',
    'tenant',
    'subject',
    'kid',
    'algorithm',
    'signature',
  ] as const)('rejects invalid OIDC %s', async (kind) => {
    let token: string;
    if (kind === 'issuer')
      token = signed({}, { issuer: 'https://evil.synthetic.invalid' });
    else if (kind === 'audience')
      token = signed({}, { audience: 'other-client' });
    else if (kind === 'expiry')
      token = signed({ exp: Math.floor(Date.now() / 1000) - 1 });
    else if (kind === 'nonce') token = signed({ nonce: 'other-nonce' });
    else if (kind === 'tenant') token = signed({ tid: 'enterprise-tenant' });
    else if (kind === 'subject') token = signed({ sub: '' });
    else if (kind === 'kid') token = signed({}, { keyid: 'other-key' });
    else if (kind === 'algorithm')
      token = jwt.sign(claims(), 'synthetic-hmac-secret', {
        algorithm: 'HS256',
        keyid: 'fixture-rsa',
        issuer: MS_ISSUER,
        audience: client,
      });
    else
      token = jwt.sign(claims(), other.privateKey, {
        algorithm: 'RS256',
        keyid: 'fixture-rsa',
        issuer: MS_ISSUER,
        audience: client,
      });
    await expect(
      transport().identity(
        token,
        client,
        digest(nonce),
        new AbortController().signal,
      ),
    ).rejects.toBeInstanceOf(MicrosoftSmtpError);
  });
  it.each(['discovery', 'duplicate_key', 'weak_key'] as const)(
    'rejects unsafe %s metadata',
    async (kind) => {
      const small = generateKeyPairSync('rsa', {
        modulusLength: 1024,
      }).publicKey.export({ format: 'jwk' });
      const t = transport((url) =>
        json(
          url === MS_DISCOVERY
            ? kind === 'discovery'
              ? { ...metadata, jwks_uri: 'http://attacker.invalid' }
              : metadata
            : kind === 'duplicate_key'
              ? { keys: [jwks.keys[0], jwks.keys[0]] }
              : { keys: [{ ...small, kid: 'fixture-rsa' }] },
        ),
      );
      await expect(
        t.identity(
          signed(),
          client,
          digest(nonce),
          new AbortController().signal,
        ),
      ).rejects.toThrow();
    },
  );
  it('token HTTP is once, fixed endpoint, redirect:error and access opaque', async () => {
    const call = jest.fn(async (url: string, init: RequestInit) => {
      await Promise.resolve();
      expect(url).toBe(MS_TOKEN);
      expect(init.redirect).toBe('error');
      return json({
        token_type: 'Bearer',
        access_token: 'opaque-synthetic',
        refresh_token: 'synthetic-rt',
        expires_in: 3600,
      });
    });
    const t = new MicrosoftSmtpTransport(call);
    const tokens = await t.tokens(
      new URLSearchParams({ grant_type: 'refresh_token' }),
      new AbortController().signal,
      false,
    );
    expect(tokens.accessToken).toBe('opaque-synthetic');
    expect(call).toHaveBeenCalledTimes(1);
  });
  it.each([
    'missing_refresh',
    'wrong_type',
    'bad_expiry',
    'wrong_scope',
    'oversized',
    'malformed',
    'redirect',
    'network',
    'invalid_grant',
    'server_error',
  ] as const)('token response %s has safe error and no retry', async (kind) => {
    const payload: Record<string, unknown> = {
      token_type: 'Bearer',
      access_token: 'synthetic-access',
      refresh_token: 'synthetic-rt',
      expires_in: 3600,
    };
    if (kind === 'missing_refresh') delete payload.refresh_token;
    if (kind === 'wrong_type') payload.token_type = 'mac';
    if (kind === 'bad_expiry') payload.expires_in = 0;
    if (kind === 'wrong_scope') payload.scope = 'mail.read';
    if (kind === 'oversized') payload.access_token = 'x'.repeat(131073);
    const call = jest.fn(async () => {
      await Promise.resolve();
      if (kind === 'network' || kind === 'redirect') throw Error('RAW_SECRET');
      if (kind === 'invalid_grant')
        return json(
          { error: 'invalid_grant', error_description: 'RAW_SECRET' },
          400,
        );
      if (kind === 'server_error')
        return json(
          { error: 'server_error', error_description: 'RAW_SECRET' },
          503,
        );
      if (kind === 'malformed') return new Response('RAW_SECRET');
      return json(payload);
    });
    const t = new MicrosoftSmtpTransport(call);
    let error: unknown;
    try {
      await t.tokens(
        new URLSearchParams(),
        new AbortController().signal,
        false,
      );
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(MicrosoftSmtpError);
    expect(JSON.stringify(error)).not.toContain('RAW_SECRET');
    expect(call).toHaveBeenCalledTimes(1);
  });
  it('public form_post has no cookie/bearer dependency and redirects with no query', async () => {
    const callback = jest.fn().mockResolvedValue(undefined);
    const c = new MicrosoftSmtpCallbackController({
        callback,
        redirectUri: () =>
          'https://admin.synthetic.invalid/api/auth/microsoft/callback',
      } as unknown as MicrosoftSmtpService),
      res = { setHeader: jest.fn(), redirect: jest.fn() };
    await c.callback(
      { state: 's'.repeat(43), code: 'synthetic-code' },
      res as never,
    );
    expect(callback).toHaveBeenCalledWith(
      's'.repeat(43),
      'synthetic-code',
      false,
    );
    expect(res.redirect).toHaveBeenCalledWith(
      303,
      'https://admin.synthetic.invalid/auth/microsoft/result',
    );
  });
  it('start never exposes cookie/code/tokens; sets secure HttpOnly Lax host cookie', async () => {
    const start = jest.fn().mockResolvedValue({
      flowId: 'synthetic-flow',
      cookie: 'synthetic-cookie',
      authorizeUrl: MS_AUTHORIZE,
      expiresAt: Date.now() + 10000,
    });
    const c = new MicrosoftSmtpAdminController({
        origin: jest.fn(),
        start,
      } as unknown as MicrosoftSmtpService),
      res = { cookie: jest.fn() },
      req = {
        headers: {
          authorization: 'Bearer synthetic-bearer',
          origin: 'https://admin.synthetic.invalid',
        },
        user: { userId: 1 },
      };
    const r = await c.start(req as never, res as never);
    expect(r.data).not.toHaveProperty('cookie');
    expect(res.cookie).toHaveBeenCalledWith(
      '__Host-ms-smtp-flow',
      'synthetic-cookie',
      expect.objectContaining({
        secure: true,
        httpOnly: true,
        sameSite: 'lax',
        path: '/',
      }),
    );
  });
  it('auth log keeps pathname only, including callback code/state', () => {
    const url =
      '/uapi/auth/microsoft/callback?state=RAW_SECRET&code=RAW_SECRET';
    expect(isAuthPath(url)).toBe(true);
    expect(logUrl(url)).toBe('/uapi/auth/microsoft/callback');
    expect(logUrl('/uapi/admin/auth/providers?token=RAW_SECRET')).toBe(
      '/uapi/admin/auth/providers',
    );
  });
  it('endpoint constants and opaque token do not use any env token/SMTP endpoint', () => {
    expect(MS_TOKEN).toContain('/consumers/');
    expect(MS_AUTHORIZE).toContain('/consumers/');
    expect(createHash('sha256').update(secret).digest()).toHaveLength(32);
  });
});
