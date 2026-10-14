import { createPublicKey } from 'node:crypto';
import * as jwt from 'jsonwebtoken';
import { digest } from './microsoft-smtp.crypto';

export const MS_TENANT = '9188040d-6c67-4c5b-b112-36a304b66dad';
export const MS_ISSUER = `https://login.microsoftonline.com/${MS_TENANT}/v2.0`;
export const MS_AUTHORIZE =
  'https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize';
export const MS_TOKEN =
  'https://login.microsoftonline.com/consumers/oauth2/v2.0/token';
export const MS_DISCOVERY =
  'https://login.microsoftonline.com/consumers/v2.0/.well-known/openid-configuration';
export const MS_JWKS =
  'https://login.microsoftonline.com/consumers/discovery/v2.0/keys';
export const MS_SCOPE =
  'https://outlook.office.com/SMTP.Send offline_access openid profile email';
export class MicrosoftSmtpError extends Error {
  readonly name = 'MicrosoftSmtpError';
  constructor(
    readonly safeCode: string,
    readonly kind: 'known' | 'unknown' | 'reauth' | 'stale' = 'known',
  ) {
    super(safeCode);
  }
}
export interface MicrosoftTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  idToken?: string;
}
export type MicrosoftFetch = (
  url: string,
  init: RequestInit,
) => Promise<Response>;

/** 固定端点/一次fetch/有界解码。synthetic transport只能代码注入，生产无env地址开关。 */
export class MicrosoftSmtpTransport {
  constructor(
    private readonly request: MicrosoftFetch = (url, init) => fetch(url, init),
  ) {}
  private async json(
    url: string,
    init: RequestInit,
  ): Promise<Record<string, unknown>> {
    let response: Response;
    try {
      response = await this.request(url, { ...init, redirect: 'error' });
    } catch {
      throw new MicrosoftSmtpError('microsoft_response_unknown', 'unknown');
    }
    let text = '';
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let bytes = 0;
    try {
      if (!response.body) throw Error('missing_body');
      const reader = response.body.getReader();
      try {
        for (;;) {
          const r = await reader.read();
          if (r.done) break;
          bytes += r.value.byteLength;
          if (bytes > 131072) throw Error('limit');
          text += decoder.decode(r.value, { stream: true });
        }
        text += decoder.decode();
      } finally {
        if (bytes > 131072) void reader.cancel().catch(() => {});
        reader.releaseLock();
      }
    } catch {
      throw new MicrosoftSmtpError('microsoft_response_unknown', 'unknown');
    }
    let value: unknown;
    try {
      value = JSON.parse(text);
    } catch {
      throw new MicrosoftSmtpError('microsoft_response_invalid');
    }
    if (!value || Array.isArray(value) || typeof value !== 'object')
      throw new MicrosoftSmtpError('microsoft_response_invalid');
    const data = value as Record<string, unknown>;
    if (response.status >= 500)
      throw new MicrosoftSmtpError('microsoft_temporarily_unavailable');
    if (!response.ok)
      throw new MicrosoftSmtpError(
        data.error === 'invalid_grant'
          ? 'microsoft_needs_reauth'
          : 'microsoft_request_failed',
        data.error === 'invalid_grant' ? 'reauth' : 'known',
      );
    return data;
  }
  async tokens(
    form: URLSearchParams,
    signal: AbortSignal,
    requireId: boolean,
  ): Promise<MicrosoftTokens> {
    const d = await this.json(MS_TOKEN, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
      signal,
    });
    const bounded = (v: unknown, max: number) =>
      typeof v === 'string' &&
      !!v &&
      Buffer.byteLength(v, 'utf8') <= max &&
      !/[\r\n\0]/.test(v);
    if (
      d.token_type !== 'Bearer' ||
      !bounded(d.access_token, 32768) ||
      !bounded(d.refresh_token, 32768) ||
      !Number.isSafeInteger(d.expires_in) ||
      Number(d.expires_in) < 120 ||
      Number(d.expires_in) > 86400 ||
      (requireId && !bounded(d.id_token, 16384))
    )
      throw new MicrosoftSmtpError('microsoft_response_invalid');
    if (
      typeof d.scope === 'string' &&
      !d.scope.split(' ').includes('https://outlook.office.com/SMTP.Send')
    )
      throw new MicrosoftSmtpError('microsoft_scope_invalid');
    return {
      accessToken: d.access_token as string,
      refreshToken: d.refresh_token as string,
      expiresIn: d.expires_in as number,
      idToken: typeof d.id_token === 'string' ? d.id_token : undefined,
    };
  }
  async identity(
    token: string,
    clientId: string,
    nonceHash: string | undefined,
    signal: AbortSignal,
  ): Promise<{ subject: string; issuer: string; emailHint: string | null }> {
    const metadata = await this.json(MS_DISCOVERY, { signal });
    if (
      metadata.issuer !== MS_ISSUER ||
      metadata.jwks_uri !== MS_JWKS ||
      metadata.token_endpoint !== MS_TOKEN ||
      metadata.authorization_endpoint !== MS_AUTHORIZE
    )
      throw new MicrosoftSmtpError('microsoft_discovery_invalid');
    const decoded = jwt.decode(token, { complete: true });
    if (
      !decoded ||
      typeof decoded === 'string' ||
      decoded.header.alg !== 'RS256' ||
      typeof decoded.header.kid !== 'string' ||
      decoded.header.kid.length > 128
    )
      throw new MicrosoftSmtpError('microsoft_identity_invalid');
    const jwks = await this.json(MS_JWKS, { signal });
    if (!Array.isArray(jwks.keys) || jwks.keys.length > 32)
      throw new MicrosoftSmtpError('microsoft_jwks_invalid');
    const keys = jwks.keys as Array<Record<string, unknown>>;
    const selected = keys.filter(
      (k) =>
        k.kid === decoded.header.kid &&
        k.kty === 'RSA' &&
        (k.use === undefined || k.use === 'sig') &&
        (k.alg === undefined || k.alg === 'RS256'),
    );
    if (
      selected.length !== 1 ||
      typeof selected[0].n !== 'string' ||
      selected[0].n.length > 2048 ||
      typeof selected[0].e !== 'string' ||
      selected[0].e.length > 16
    )
      throw new MicrosoftSmtpError('microsoft_jwks_invalid');
    try {
      const key = createPublicKey({
        key: { kty: 'RSA', n: selected[0].n, e: selected[0].e },
        format: 'jwk',
      });
      if ((key.asymmetricKeyDetails?.modulusLength ?? 0) < 2048)
        throw Error('weak_key');
      const p = jwt.verify(token, key, {
        algorithms: ['RS256'],
        issuer: MS_ISSUER,
        audience: clientId,
        clockTimestamp: Math.floor(Date.now() / 1000),
      }) as jwt.JwtPayload;
      if (
        !Number.isSafeInteger(p.exp) ||
        p.exp! <= Date.now() / 1000 ||
        p.tid !== MS_TENANT ||
        typeof p.sub !== 'string' ||
        !p.sub ||
        p.sub.length > 512 ||
        (nonceHash !== undefined &&
          (typeof p.nonce !== 'string' || digest(p.nonce) !== nonceHash))
      )
        throw Error('invalid_claims');
      return {
        subject: p.sub,
        issuer: MS_ISSUER,
        emailHint:
          typeof p.email === 'string' &&
          p.email.length <= 320 &&
          !/[\r\n\0]/.test(p.email)
            ? p.email
            : null,
      };
    } catch {
      throw new MicrosoftSmtpError('microsoft_identity_invalid');
    }
  }
}
