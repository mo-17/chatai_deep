import { Inject, Injectable, OnApplicationShutdown } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { randomBytes, randomUUID } from 'node:crypto';
import { DataSource, type EntityManager } from 'typeorm';
import { AUTH_KIT_OPTIONS } from '../auth-kit.tokens';
import type { AuthKitModuleOptions } from '../auth-kit.module';
import type { AuthenticatedPrincipal } from '../contracts/access-token-verifier.interface';
import { SmtpProvider } from '../verification/entities/smtp-provider.entity';
import {
  MicrosoftSmtpConnection,
  MicrosoftSmtpFlow,
} from './microsoft-smtp.entities';
import {
  MicrosoftSmtpCipher,
  digest,
  equalDigest,
} from './microsoft-smtp.crypto';
import { MicrosoftSmtpStore } from './microsoft-smtp.store';
import {
  MS_AUTHORIZE,
  MS_SCOPE,
  MicrosoftSmtpError,
  MicrosoftSmtpTransport,
} from './microsoft-smtp.transport';

export const MICROSOFT_SMTP_TRANSPORT = Symbol('MICROSOFT_SMTP_TRANSPORT');
export interface MicrosoftSession {
  principal: AuthenticatedPrincipal;
  bearer: string;
  cookie: string;
}
export interface MicrosoftAccess {
  token: string;
  generation: number;
  fence: number;
  configRevision: number;
  expiresAt: number;
}
const ttl = 300000,
  leaseMs = 20000;
const fail = (code = 'microsoft_authorization_invalid'): never => {
  throw new MicrosoftSmtpError(code);
};

/** 网络不进入事务，所有跨实例变更复用178409短锁。 */
@Injectable()
export class MicrosoftSmtpService implements OnApplicationShutdown {
  private readonly store: MicrosoftSmtpStore;
  readonly cipher: MicrosoftSmtpCipher;
  private stopped = false;
  private readonly requests = new Set<AbortController>();
  private readonly listeners = new Set<(key?: string) => void>();
  constructor(
    @InjectDataSource() source: DataSource,
    @Inject(AUTH_KIT_OPTIONS) private readonly options: AuthKitModuleOptions,
    @Inject(MICROSOFT_SMTP_TRANSPORT)
    private readonly transport = new MicrosoftSmtpTransport(),
  ) {
    this.store = new MicrosoftSmtpStore(source);
    this.cipher = new MicrosoftSmtpCipher(options.appSecretKey);
  }
  subscribe(listener: (key?: string) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  invalidate(key?: string): void {
    for (const listener of this.listeners) listener(key);
  }
  private live(): void {
    if (this.stopped) fail('microsoft_service_stopped');
  }
  redirectUri(): string {
    const raw = this.options.microsoftSmtpRedirectUri;
    let u: URL;
    try {
      u = new URL(raw ?? '');
    } catch {
      return fail('microsoft_redirect_not_configured');
    }
    if (
      u.protocol !== 'https:' ||
      u.username ||
      u.password ||
      u.search ||
      u.hash ||
      ![
        '/api/auth/microsoft/callback',
        '/uapi/auth/microsoft/callback',
      ].includes(u.pathname) ||
      raw !== u.href
    )
      fail('microsoft_redirect_not_configured');
    return u.href;
  }
  origin(origin?: string): void {
    if (origin !== new URL(this.redirectUri()).origin)
      fail('microsoft_origin_invalid');
  }
  private deadline(expiresAt: number): void {
    this.live();
    if (!Number.isSafeInteger(expiresAt) || expiresAt <= Date.now())
      fail('microsoft_authorization_expired');
  }
  private async admin(
    m: EntityManager,
    userId: number,
    version: number,
    expiresAt?: number,
  ): Promise<void> {
    if (expiresAt !== undefined) this.deadline(expiresAt);
    const user = await this.options.userResolver
      .withManager(m)
      .findById(userId);
    if (
      !user ||
      user.banned ||
      user.role !== 'admin' ||
      user.tokenVersion !== version
    )
      fail();
    if (expiresAt !== undefined) this.deadline(expiresAt);
  }
  private async provider(
    m: EntityManager,
    key = 'generic',
  ): Promise<SmtpProvider> {
    const p = await m.findOne(SmtpProvider, {
      where: { key: key as SmtpProvider['key'] },
      lock: { mode: 'pessimistic_write' },
    });
    if (!p) fail('smtp_provider_missing');
    return p!;
  }
  private configured(p: SmtpProvider): void {
    if (
      p.key !== 'generic' ||
      p.authMode !== 'microsoft_oauth' ||
      !p.microsoftClientId ||
      !p.microsoftClientSecretEncrypted ||
      !p.fromAddress ||
      p.username !== p.fromAddress ||
      p.host !== 'smtp-mail.outlook.com' ||
      p.port !== 587 ||
      p.secure
    )
      fail('microsoft_not_configured');
  }
  private async connection(
    m: EntityManager,
    p: SmtpProvider,
  ): Promise<MicrosoftSmtpConnection> {
    const c = await m.findOne(MicrosoftSmtpConnection, {
      where: { providerId: p.id },
      lock: { mode: 'pessimistic_write' },
    });
    return (
      c ??
      m.create(MicrosoftSmtpConnection, {
        providerId: p.id,
        schemaVersion: 1,
        generation: 0,
        configRevision: p.configRevision,
        status: 'not_connected',
        fence: 0,
      })
    );
  }
  private clear(c: MicrosoftSmtpConnection): void {
    c.accessEncrypted = null;
    c.refreshEncrypted = null;
    c.expiresAt = null;
    c.leaseOwner = null;
    c.leaseExpiresAt = null;
    c.adminId = null;
    c.securityVersion = null;
    c.subject = null;
    c.issuer = null;
    c.emailHint = null;
    c.errorCode = null;
  }
  async disconnectWith(m: EntityManager, p: SmtpProvider): Promise<void> {
    const c = await this.connection(m, p);
    c.generation++;
    c.fence++;
    c.configRevision = p.configRevision;
    c.status = 'not_connected';
    this.clear(c);
    await m.save(c);
    await m
      .createQueryBuilder()
      .update(MicrosoftSmtpFlow)
      .set({
        status: 'cancelled',
        codeEncrypted: null,
        verifierEncrypted: null,
        leaseOwner: null,
        leaseExpiresAt: null,
      })
      .where('"providerId" = :id', { id: p.id })
      .execute();
  }
  async mutate<T>(action: (m: EntityManager) => Promise<T>): Promise<T> {
    this.live();
    return this.store.transaction(action);
  }
  async start(session: MicrosoftSession): Promise<{
    flowId: string;
    cookie: string;
    authorizeUrl: string;
    expiresAt: number;
  }> {
    const redirect = this.redirectUri(),
      state = randomBytes(32).toString('base64url'),
      nonce = randomBytes(32).toString('base64url'),
      verifier = randomBytes(32).toString('base64url'),
      cookie = randomBytes(32).toString('base64url');
    const result = await this.store.transaction(async (m) => {
      await this.admin(
        m,
        session.principal.userId,
        session.principal.tokenVersion,
        session.principal.expiresAt ?? 0,
      );
      const p = await this.provider(m);
      this.configured(p);
      await this.disconnectWith(m, p);
      const c = await this.connection(m, p);
      const id = randomUUID(),
        expiresAt = Math.min(Date.now() + ttl, session.principal.expiresAt!);
      const flow = m.create(MicrosoftSmtpFlow, {
        id,
        schemaVersion: 1,
        providerId: p.id,
        generation: c.generation,
        configRevision: p.configRevision,
        adminId: session.principal.userId,
        securityVersion: session.principal.tokenVersion,
        authorizationExpiresAt: new Date(session.principal.expiresAt!),
        bearerHash: digest(session.bearer),
        cookieHash: digest(cookie),
        stateHash: digest(state),
        nonceHash: digest(nonce),
        redirectUri: redirect,
        verifierEncrypted: this.cipher.seal(verifier, p.id, 'verifier', id),
        codeEncrypted: null,
        status: 'started',
        expiresAt: new Date(expiresAt),
        fence: 0,
      });
      await m.save(flow);
      this.deadline(session.principal.expiresAt!);
      const u = new URL(MS_AUTHORIZE);
      u.search = new URLSearchParams({
        client_id: p.microsoftClientId!,
        response_type: 'code',
        response_mode: 'form_post',
        redirect_uri: redirect,
        scope: MS_SCOPE,
        state,
        nonce,
        code_challenge: Buffer.from(digest(verifier), 'hex').toString(
          'base64url',
        ),
        code_challenge_method: 'S256',
        prompt: 'select_account',
      }).toString();
      return { flowId: id, cookie, authorizeUrl: u.href, expiresAt };
    });
    this.invalidate('generic');
    return result;
  }
  /** 跨站POST只接收一次code；不读取cookie、不兑换、不激活。 */
  async callback(
    state: string,
    code?: string,
    cancelled = false,
  ): Promise<void> {
    if (
      !/^[A-Za-z0-9_-]{43}$/.test(state) ||
      (!cancelled &&
        (typeof code !== 'string' ||
          !code ||
          Buffer.byteLength(code) > 16384 ||
          /[\r\n\0]/.test(code)))
    )
      fail('microsoft_callback_invalid');
    await this.store.transaction(async (m) => {
      const f = await m.findOne(MicrosoftSmtpFlow, {
        where: { stateHash: digest(state) },
        lock: { mode: 'pessimistic_write' },
      });
      if (!f || f.status !== 'started') fail('microsoft_callback_invalid');
      const p = await this.provider(m);
      const c = await this.connection(m, p);
      this.flowCurrent(f!, p, c);
      f!.status = cancelled ? 'cancelled' : 'received';
      f!.codeEncrypted = cancelled
        ? null
        : this.cipher.seal(code!, p.id, 'code', f!.id);
      if (cancelled) f!.verifierEncrypted = null;
      await m.save(f);
      this.deadline(f!.expiresAt.getTime());
    });
  }
  private flowCurrent(
    f: MicrosoftSmtpFlow,
    p: SmtpProvider,
    c: MicrosoftSmtpConnection,
  ): void {
    this.configured(p);
    this.deadline(f.expiresAt.getTime());
    this.deadline(f.authorizationExpiresAt.getTime());
    if (
      f.providerId !== p.id ||
      f.configRevision !== p.configRevision ||
      f.generation !== c.generation ||
      f.redirectUri !== this.redirectUri()
    )
      fail('microsoft_flow_stale');
  }
  private sessionFlow(f: MicrosoftSmtpFlow, s: MicrosoftSession): void {
    if (
      f.adminId !== s.principal.userId ||
      f.securityVersion !== s.principal.tokenVersion ||
      !equalDigest(s.bearer, f.bearerHash) ||
      !equalDigest(s.cookie, f.cookieHash) ||
      f.authorizationExpiresAt.getTime() !== s.principal.expiresAt
    )
      fail();
  }
  private async network<T>(
    run: (signal: AbortSignal) => Promise<T>,
  ): Promise<T> {
    this.live();
    const controller = new AbortController();
    this.requests.add(controller);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const cancelled = new Promise<never>((_, reject) => {
      controller.signal.addEventListener(
        'abort',
        () =>
          reject(
            new MicrosoftSmtpError('microsoft_response_unknown', 'unknown'),
          ),
        { once: true },
      );
      timer = setTimeout(() => controller.abort(), 12000);
    });
    try {
      return await Promise.race([run(controller.signal), cancelled]);
    } finally {
      if (timer) clearTimeout(timer);
      controller.abort();
      this.requests.delete(controller);
    }
  }
  async complete(
    flowId: string,
    s: MicrosoftSession,
  ): Promise<{ status: string }> {
    if (!/^[a-f0-9-]{36}$/.test(flowId)) fail();
    const claim = await this.store.transaction(async (m) => {
      const p = await this.provider(m),
        c = await this.connection(m, p);
      const f = await m.findOne(MicrosoftSmtpFlow, {
        where: { id: flowId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!f) fail();
      this.sessionFlow(f!, s);
      this.flowCurrent(f!, p, c);
      await this.admin(
        m,
        f!.adminId,
        f!.securityVersion,
        f!.authorizationExpiresAt.getTime(),
      );
      if (f!.status !== 'received') return null;
      if (!f!.codeEncrypted || !f!.verifierEncrypted) fail();
      const code = this.cipher.open(f!.codeEncrypted!, p.id, 'code', f!.id),
        verifier = this.cipher.open(
          f!.verifierEncrypted!,
          p.id,
          'verifier',
          f!.id,
        );
      f!.status = 'exchanging';
      f!.leaseOwner = randomUUID();
      f!.leaseExpiresAt = new Date(Date.now() + leaseMs);
      f!.fence++;
      f!.codeEncrypted = null;
      f!.verifierEncrypted = null;
      await m.save(f);
      this.deadline(f!.expiresAt.getTime());
      this.deadline(f!.authorizationExpiresAt.getTime());
      return { p, f: f!, code, verifier };
    });
    if (!claim) return this.flowStatus(flowId, s);
    const { p, f, code, verifier } = claim;
    try {
      const result = await this.network(async (signal) => {
        const tokens = await this.transport.tokens(
          new URLSearchParams({
            grant_type: 'authorization_code',
            client_id: p.microsoftClientId!,
            client_secret: this.cipher.open(
              p.microsoftClientSecretEncrypted!,
              p.id,
              'client-secret',
            ),
            code,
            code_verifier: verifier,
            redirect_uri: f.redirectUri,
            scope: MS_SCOPE,
          }),
          signal,
          true,
        );
        const identity = await this.transport.identity(
          tokens.idToken!,
          p.microsoftClientId!,
          f.nonceHash,
          signal,
        );
        return { tokens, identity };
      });
      await this.store.transaction(async (m) => {
        const current = await this.provider(m),
          c = await this.connection(m, current),
          flow = await m.findOne(MicrosoftSmtpFlow, {
            where: { id: flowId },
            lock: { mode: 'pessimistic_write' },
          });
        if (
          !flow ||
          flow.status !== 'exchanging' ||
          flow.leaseOwner !== f.leaseOwner ||
          flow.fence !== f.fence ||
          !flow.leaseExpiresAt ||
          flow.leaseExpiresAt.getTime() <= Date.now()
        )
          fail('microsoft_flow_stale');
        this.sessionFlow(flow!, s);
        this.flowCurrent(flow!, current, c);
        await this.admin(
          m,
          flow!.adminId,
          flow!.securityVersion,
          flow!.authorizationExpiresAt.getTime(),
        );
        c.status = 'connected';
        c.configRevision = current.configRevision;
        c.adminId = f.adminId;
        c.securityVersion = f.securityVersion;
        c.subject = result.identity.subject;
        c.issuer = result.identity.issuer;
        c.emailHint = result.identity.emailHint;
        c.fence++;
        c.errorCode = null;
        c.accessEncrypted = this.cipher.seal(
          result.tokens.accessToken,
          p.id,
          'access',
          String(c.generation),
        );
        c.refreshEncrypted = this.cipher.seal(
          result.tokens.refreshToken,
          p.id,
          'refresh',
          String(c.generation),
        );
        c.expiresAt = new Date(Date.now() + result.tokens.expiresIn * 1000);
        c.leaseOwner = null;
        c.leaseExpiresAt = null;
        await m.save(c);
        flow!.status = 'connected';
        flow!.leaseOwner = null;
        flow!.leaseExpiresAt = null;
        await m.save(flow);
        this.flowCurrent(flow!, current, c);
        this.deadline(flow!.authorizationExpiresAt.getTime());
        if (f.leaseExpiresAt!.getTime() <= Date.now())
          fail('microsoft_flow_stale');
      });
      this.invalidate('generic');
      return { status: 'connected' };
    } catch (error) {
      const e =
        error instanceof MicrosoftSmtpError
          ? error
          : new MicrosoftSmtpError('microsoft_exchange_failed');
      await this.store.transaction(async (m) => {
        const flow = await m.findOne(MicrosoftSmtpFlow, {
          where: { id: flowId },
          lock: { mode: 'pessimistic_write' },
        });
        if (
          flow?.status === 'exchanging' &&
          flow.leaseOwner === f.leaseOwner &&
          flow.fence === f.fence
        ) {
          flow.status = e.kind === 'unknown' ? 'unknown' : 'failed';
          flow.errorCode = e.safeCode;
          flow.leaseOwner = null;
          flow.leaseExpiresAt = null;
          await m.save(flow);
        }
      });
      throw e;
    }
  }
  async flowStatus(
    id: string,
    s: MicrosoftSession,
  ): Promise<{ status: string }> {
    return this.store.transaction(async (m) => {
      const f = await m.findOne(MicrosoftSmtpFlow, { where: { id } });
      if (!f) fail();
      this.sessionFlow(f!, s);
      await this.admin(
        m,
        f!.adminId,
        f!.securityVersion,
        f!.authorizationExpiresAt.getTime(),
      );
      return {
        status:
          f!.expiresAt.getTime() <= Date.now()
            ? 'expired'
            : f!.status === 'exchanging' &&
                f!.leaseExpiresAt!.getTime() <= Date.now()
              ? 'unknown'
              : f!.status,
      };
    });
  }
  async status(): Promise<{
    status: string;
    configured: boolean;
    emailHint: string | null;
  }> {
    return this.store.transaction(async (m) => {
      const p = await this.provider(m),
        c = await this.connection(m, p);
      const configured =
        p.authMode === 'microsoft_oauth' &&
        !!p.microsoftClientId &&
        !!p.microsoftClientSecretEncrypted &&
        !!p.fromAddress;
      return {
        status: !configured ? 'not_configured' : c.status,
        emailHint: c.emailHint,
        configured,
      };
    });
  }
  async disconnect(s: MicrosoftSession): Promise<void> {
    await this.store.transaction(async (m) => {
      await this.admin(
        m,
        s.principal.userId,
        s.principal.tokenVersion,
        s.principal.expiresAt ?? 0,
      );
      const p = await this.provider(m);
      await this.disconnectWith(m, p);
      await m.update(SmtpProvider, { id: p.id }, { enabled: false });
      this.deadline(s.principal.expiresAt!);
    });
    this.invalidate('generic');
  }
  private async connected(
    m: EntityManager,
    p: SmtpProvider,
    c: MicrosoftSmtpConnection,
  ): Promise<void> {
    this.configured(p);
    if (
      c.status !== 'connected' ||
      c.configRevision !== p.configRevision ||
      c.adminId === null ||
      c.securityVersion === null ||
      !c.accessEncrypted ||
      !c.refreshEncrypted
    )
      fail('microsoft_needs_reauth');
    await this.admin(m, c.adminId!, c.securityVersion!);
    this.live();
  }
  async activationReady(m: EntityManager, p: SmtpProvider): Promise<void> {
    const c = await this.connection(m, p);
    await this.connected(m, p, c);
  }
  async assertAccess(p: SmtpProvider, a: MicrosoftAccess): Promise<void> {
    await this.store.transaction(async (m) => {
      const current = await this.provider(m, p.key),
        c = await this.connection(m, current);
      await this.connected(m, current, c);
      if (
        current.configRevision !== p.configRevision ||
        current.enabled !== p.enabled ||
        c.generation !== a.generation ||
        c.fence !== a.fence ||
        !c.expiresAt ||
        c.expiresAt.getTime() <= Date.now() + 1000
      )
        fail('microsoft_connection_stale');
    });
  }
  async access(p: SmtpProvider): Promise<MicrosoftAccess> {
    const deadline = Date.now() + 5000;
    for (;;) {
      const claim = await this.store.transaction(async (m) => {
        const current = await this.provider(m, p.key),
          c = await this.connection(m, current);
        await this.connected(m, current, c);
        if (current.configRevision !== p.configRevision)
          fail('microsoft_connection_stale');
        if (c.expiresAt && c.expiresAt.getTime() > Date.now() + 60000)
          return {
            access: {
              token: this.cipher.open(
                c.accessEncrypted!,
                p.id,
                'access',
                String(c.generation),
              ),
              generation: c.generation,
              fence: c.fence,
              configRevision: c.configRevision,
              expiresAt: c.expiresAt.getTime(),
            },
          };
        if (
          c.leaseOwner &&
          c.leaseExpiresAt &&
          c.leaseExpiresAt.getTime() > Date.now()
        )
          return { wait: true };
        c.leaseOwner = randomUUID();
        c.leaseExpiresAt = new Date(Date.now() + leaseMs);
        c.fence++;
        await m.save(c);
        this.live();
        return { p: current, c };
      });
      if ('access' in claim && claim.access) return claim.access;
      if ('wait' in claim) {
        if (Date.now() >= deadline) fail('microsoft_refresh_busy');
        await new Promise((r) => setTimeout(r, 75));
        this.live();
        continue;
      }
      const { c, p: current } = claim as {
        p: SmtpProvider;
        c: MicrosoftSmtpConnection;
      };
      try {
        const t = await this.network(async (signal) => {
          const tokens = await this.transport.tokens(
            new URLSearchParams({
              grant_type: 'refresh_token',
              client_id: current.microsoftClientId!,
              client_secret: this.cipher.open(
                current.microsoftClientSecretEncrypted!,
                p.id,
                'client-secret',
              ),
              refresh_token: this.cipher.open(
                c.refreshEncrypted!,
                p.id,
                'refresh',
                String(c.generation),
              ),
              scope: MS_SCOPE,
            }),
            signal,
            false,
          );
          if (tokens.idToken) {
            const identity = await this.transport.identity(
              tokens.idToken,
              current.microsoftClientId!,
              undefined,
              signal,
            );
            if (identity.subject !== c.subject || identity.issuer !== c.issuer)
              fail('microsoft_identity_changed');
          }
          return tokens;
        });
        const access = await this.store.transaction(async (m) => {
          const now = await this.provider(m, p.key),
            row = await this.connection(m, now);
          await this.connected(m, now, row);
          if (
            row.generation !== c.generation ||
            row.fence !== c.fence ||
            row.leaseOwner !== c.leaseOwner ||
            !row.leaseExpiresAt ||
            row.leaseExpiresAt.getTime() <= Date.now() ||
            now.configRevision !== current.configRevision
          )
            fail('microsoft_connection_stale');
          row.accessEncrypted = this.cipher.seal(
            t.accessToken,
            p.id,
            'access',
            String(row.generation),
          );
          row.refreshEncrypted = this.cipher.seal(
            t.refreshToken,
            p.id,
            'refresh',
            String(row.generation),
          );
          row.expiresAt = new Date(Date.now() + t.expiresIn * 1000);
          row.leaseOwner = null;
          row.leaseExpiresAt = null;
          row.errorCode = null;
          await m.save(row);
          this.live();
          if (c.leaseExpiresAt!.getTime() <= Date.now())
            fail('microsoft_connection_stale');
          return {
            token: t.accessToken,
            generation: row.generation,
            fence: row.fence,
            configRevision: row.configRevision,
            expiresAt: row.expiresAt.getTime(),
          };
        });
        this.invalidate(p.key);
        return access;
      } catch (error) {
        const e =
          error instanceof MicrosoftSmtpError
            ? error
            : new MicrosoftSmtpError('microsoft_refresh_failed');
        await this.store.transaction(async (m) => {
          const now = await this.provider(m, p.key),
            row = await this.connection(m, now);
          if (
            row.generation === c.generation &&
            row.fence === c.fence &&
            row.leaseOwner === c.leaseOwner
          ) {
            row.leaseOwner = null;
            row.leaseExpiresAt = null;
            row.errorCode = e.safeCode;
            if (e.kind === 'reauth') {
              row.status = 'needs_reauth';
              row.accessEncrypted = null;
              row.refreshEncrypted = null;
              row.expiresAt = null;
            }
            await m.save(row);
          }
        });
        this.invalidate(p.key);
        throw e;
      }
    }
  }
  async onApplicationShutdown(): Promise<void> {
    this.stopped = true;
    for (const c of this.requests) c.abort();
    this.invalidate();
    await this.store.close();
  }
}
