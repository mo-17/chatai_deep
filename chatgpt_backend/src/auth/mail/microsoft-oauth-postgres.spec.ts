import { DataSource, type EntityManager } from 'typeorm';
import { MicrosoftSmtpStore } from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.store';
import { createServer, type Server } from 'node:http';
import { createHash, generateKeyPairSync } from 'node:crypto';
import * as jwt from 'jsonwebtoken';
import { User } from '../../user/user.entity';
import { ChatGptUserResolver } from '../chatgpt-user.resolver';
import { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import {
  MicrosoftSmtpService,
  type MicrosoftSession,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.service';
import {
  MicrosoftSmtpConnection,
  MicrosoftSmtpFlow,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.entities';
import {
  MicrosoftSmtpTransport,
  MS_TOKEN,
  MS_JWKS,
  MS_DISCOVERY,
  MS_ISSUER,
  MS_AUTHORIZE,
  MS_TENANT,
} from '../../../libs/auth-kit/src/microsoft/microsoft-smtp.transport';
import type { AuthKitModuleOptions } from '../../../libs/auth-kit/src/auth-kit.module';
import {
  pgSuite,
  privateDatabase,
  deferred,
  evidence,
  writeEvidence,
} from './microsoft-private-pg.fixture';
pgSuite('O1 real PG with synthetic HTTP Microsoft consumers OAuth', () => {
  jest.setTimeout(20000);
  let db: DataSource,
    server: Server,
    base: string,
    a: MicrosoftSmtpService,
    b: MicrosoftSmtpService,
    options: AuthKitModuleOptions,
    s: MicrosoftSession,
    p: SmtpProvider;
  let calls: number,
    refreshes: number,
    nonce: string,
    challenge: string,
    mode: 'ok' | 'invalid_grant' | 'temporary' | 'wrong_identity',
    gate: ReturnType<typeof deferred> | undefined,
    entered: ReturnType<typeof deferred> | undefined;
  const pair = generateKeyPairSync('rsa', { modulusLength: 2048 }),
    client = 'f03291c6-5cbc-4c03-a67b-5a18934a4321';
  const pub = pair.publicKey.export({ format: 'jwk' });
  beforeAll(async () => {
    db = await privateDatabase();
    const user = await db.getRepository(User).save({
      userName: 'synthetic-admin',
      role: 'admin',
      banned: false,
      tokenVersion: 0,
      password: null,
      avatar: '',
      email: null,
    });
    options = {
      appSecretKey: 'synthetic-mail-contract-app-key-0123456789abcdef',
      microsoftSmtpRedirectUri:
        'https://admin.synthetic.invalid/api/auth/microsoft/callback',
      userResolver: new ChatGptUserResolver(db.getRepository(User)),
      jwtSigner: {} as never,
      accessTokenVerifier: {} as never,
    };
    s = {
      principal: {
        userId: user.id,
        userName: user.userName,
        role: 'admin',
        tokenVersion: 0,
        expiresAt: Date.now() + 600000,
      },
      bearer: 'synthetic-original-admin-bearer',
      cookie: '',
    };
    server = createServer((req, res) => {
      void (async () => {
        let body = '';
        for await (const chunk of req) body += String(chunk);
        res.setHeader('Content-Type', 'application/json');
        if (req.url === '/discovery') {
          res.end(
            JSON.stringify({
              issuer: MS_ISSUER,
              jwks_uri: MS_JWKS,
              token_endpoint: MS_TOKEN,
              authorization_endpoint: MS_AUTHORIZE,
            }),
          );
          return;
        }
        if (req.url === '/jwks') {
          res.end(
            JSON.stringify({
              keys: [{ ...pub, kid: 'fixture-rsa', use: 'sig', alg: 'RS256' }],
            }),
          );
          return;
        }
        const form = new URLSearchParams(body);
        calls++;
        if (form.get('grant_type') === 'refresh_token') refreshes++;
        if (entered) entered.resolve();
        if (gate) await gate.promise;
        if (mode === 'invalid_grant') {
          res.statusCode = 400;
          res.end(
            JSON.stringify({
              error: 'invalid_grant',
              error_description: 'RAW_SECRET_NOT_PROPAGATED',
            }),
          );
          return;
        }
        if (mode === 'temporary') {
          res.statusCode = 503;
          res.end(
            JSON.stringify({
              error: 'server_error',
              error_description: 'RAW_SECRET_NOT_PROPAGATED',
            }),
          );
          return;
        }
        if (form.get('grant_type') === 'authorization_code') {
          if (
            createHash('sha256')
              .update(form.get('code_verifier')!)
              .digest('base64url') !== challenge ||
            form.get('redirect_uri') !== options.microsoftSmtpRedirectUri ||
            form.get('client_id') !== client
          ) {
            res.statusCode = 400;
            res.end('{}');
            return;
          }
        }
        res.end(
          JSON.stringify({
            token_type: 'Bearer',
            access_token: 'synthetic-opaque-access-' + calls,
            refresh_token: 'synthetic-rotated-refresh-' + calls,
            expires_in: 3600,
            scope: 'https://outlook.office.com/SMTP.Send',
            ...(form.get('grant_type') === 'authorization_code' ||
            mode === 'wrong_identity'
              ? {
                  id_token: jwt.sign(
                    {
                      sub:
                        mode === 'wrong_identity'
                          ? 'other-subject'
                          : 'stable-subject',
                      tid: MS_TENANT,
                      nonce,
                    },
                    pair.privateKey,
                    {
                      algorithm: 'RS256',
                      keyid: 'fixture-rsa',
                      issuer: MS_ISSUER,
                      audience: client,
                      expiresIn: 300,
                    },
                  ),
                }
              : {}),
          }),
        );
      })().catch(() => {
        res.statusCode = 500;
        res.end('{}');
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    const address = server.address();
    if (!address || typeof address === 'string')
      throw Error('synthetic_http_required');
    base = 'http://127.0.0.1:' + address.port;
  });
  function service() {
    return new MicrosoftSmtpService(
      db,
      options,
      new MicrosoftSmtpTransport((url, init) =>
        fetch(
          base +
            (url === MS_TOKEN
              ? '/token'
              : url === MS_DISCOVERY
                ? '/discovery'
                : url === MS_JWKS
                  ? '/jwks'
                  : '/invalid'),
          init,
        ),
      ),
    );
  }
  beforeEach(async () => {
    calls = 0;
    refreshes = 0;
    mode = 'ok';
    gate = undefined;
    entered = undefined;
    await db
      .getRepository(MicrosoftSmtpFlow)
      .createQueryBuilder()
      .delete()
      .execute();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .createQueryBuilder()
      .delete()
      .execute();
    await db
      .getRepository(SmtpProvider)
      .createQueryBuilder()
      .delete()
      .execute();
    a = service();
    b = service();
    p = await db.getRepository(SmtpProvider).save({
      key: 'generic',
      authMode: 'microsoft_oauth',
      configRevision: 1,
      microsoftClientId: client,
      displayName: 'fixture',
      host: 'smtp-mail.outlook.com',
      port: 587,
      secure: false,
      username: 'sender@synthetic.invalid',
      passwordEncrypted: '',
      fromName: 'fixture',
      fromAddress: 'sender@synthetic.invalid',
      enabled: false,
    });
    p.microsoftClientSecretEncrypted = a.cipher.seal(
      'synthetic-client-secret',
      p.id,
      'client-secret',
    );
    await db.getRepository(SmtpProvider).save(p);
    s = {
      ...s,
      principal: { ...s.principal, expiresAt: Date.now() + 600000 },
      cookie: '',
    };
    await db.getRepository(User).update(s.principal.userId, {
      banned: false,
      role: 'admin',
      tokenVersion: 0,
    });
  });
  afterEach(async () => {
    gate?.resolve();
    await a?.onApplicationShutdown();
    await b?.onApplicationShutdown();
  });
  afterAll(async () => {
    server?.closeAllConnections();
    await new Promise<void>((r) => server?.close(() => r()));
    writeEvidence();
    await db?.destroy();
  });
  async function start() {
    const f = await a.start(s);
    const u = new URL(f.authorizeUrl);
    nonce = u.searchParams.get('nonce')!;
    challenge = u.searchParams.get('code_challenge')!;
    s.cookie = f.cookie;
    return { f, u };
  }
  async function received() {
    const { f, u } = await start();
    await a.callback(
      u.searchParams.get('state')!,
      'synthetic-authorization-code',
    );
    return f;
  }
  async function connected() {
    const f = await received();
    await a.complete(f.flowId, s);
    return f;
  }
  it('start uses consumers/S256/form_post and hashes/encrypts all transient secrets', async () => {
    const { f, u } = await start(),
      row = await db
        .getRepository(MicrosoftSmtpFlow)
        .findOneByOrFail({ id: f.flowId });
    expect(u.origin + u.pathname).toBe(MS_AUTHORIZE);
    expect(u.searchParams.get('response_mode')).toBe('form_post');
    expect(u.searchParams.get('code_challenge_method')).toBe('S256');
    expect(u.searchParams.get('scope')).toContain('SMTP.Send');
    expect(JSON.stringify(row)).not.toContain(f.cookie);
    expect(row.verifierEncrypted).toMatch(/^v1:/);
    expect(calls).toBe(0);
    evidence.push({ case: 'PKCE/state/bearer/cookie binding', calls: 0 });
  });
  it('callback only stores encrypted code once; replay never exchanges', async () => {
    const { f, u } = await start(),
      state = u.searchParams.get('state')!;
    await a.callback(state, 'synthetic-code');
    await expect(a.callback(state, 'synthetic-other')).rejects.toThrow();
    const row = await db
      .getRepository(MicrosoftSmtpFlow)
      .findOneByOrFail({ id: f.flowId });
    expect(row.codeEncrypted).toMatch(/^v1:/);
    expect(JSON.stringify(row)).not.toContain('synthetic-code');
    expect(calls).toBe(0);
  });
  it.each(['cookie', 'bearer', 'admin'] as const)(
    'complete rejects a changed %s before network',
    async (kind) => {
      const f = await received(),
        wrong = { ...s, principal: { ...s.principal } };
      if (kind === 'admin') wrong.principal.userId++;
      else wrong[kind] = 'different-synthetic-session';
      await expect(b.complete(f.flowId, wrong)).rejects.toThrow();
      expect(calls).toBe(0);
    },
  );
  it('callback with unknown state and cancellation do not exchange or activate', async () => {
    const { f, u } = await start();
    await expect(a.callback('x'.repeat(43), 'synthetic')).rejects.toThrow();
    await a.callback(u.searchParams.get('state')!, undefined, true);
    expect((await a.flowStatus(f.flowId, s)).status).toBe('cancelled');
    await a.complete(f.flowId, s);
    expect(calls).toBe(0);
    expect(
      (await db.getRepository(SmtpProvider).findOneByOrFail({ id: p.id }))
        .enabled,
    ).toBe(false);
  });
  it('successful complete is one-use and persists encrypted stable OIDC identity without activating', async () => {
    const f = await connected();
    await b.complete(f.flowId, s);
    expect(calls).toBe(1);
    const c = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    expect(c.subject).toBe('stable-subject');
    expect(c.issuer).toBe(MS_ISSUER);
    expect(c.accessEncrypted).toMatch(/^v1:/);
    expect(c.refreshEncrypted).toMatch(/^v1:/);
    expect(JSON.stringify(c)).not.toMatch(/synthetic-opaque|synthetic-rotated/);
    const flow = await db
      .getRepository(MicrosoftSmtpFlow)
      .findOneByOrFail({ id: f.flowId });
    expect(flow.codeEncrypted).toBeNull();
    expect(flow.verifierEncrypted).toBeNull();
    expect(
      (await db.getRepository(SmtpProvider).findOneByOrFail({ id: p.id }))
        .enabled,
    ).toBe(false);
    expect((await a.access(p)).token).toBe('synthetic-opaque-access-1');
    expect(calls).toBe(1);
  });
  it('two instances refresh single-flight and rotate encrypted RT atomically', async () => {
    await connected();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .update(p.id, { expiresAt: new Date(Date.now() + 1000) });
    entered = deferred();
    gate = deferred();
    const x = a.access(p);
    await entered.promise;
    const y = b.access(p);
    gate.resolve();
    const [one, two] = await Promise.all([x, y]);
    expect(one.token).toBe(two.token);
    expect(refreshes).toBe(1);
    const c = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    expect(
      a.cipher.open(c.refreshEncrypted!, p.id, 'refresh', String(c.generation)),
    ).toBe('synthetic-rotated-refresh-2');
    expect(c.leaseOwner).toBeNull();
    evidence.push({
      case: 'cross-instance refresh',
      refreshes,
      rotation: true,
    });
  });
  it('disconnect during refresh fences the late response and clears token/flow state', async () => {
    await connected();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .update(p.id, { expiresAt: new Date(Date.now() + 1000) });
    entered = deferred();
    gate = deferred();
    const x = a.access(p);
    const result = x.then(
      () => false,
      () => true,
    );
    await entered.promise;
    await b.disconnect(s);
    gate.resolve();
    expect(await result).toBe(true);
    const c = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    expect(c.status).toBe('not_connected');
    expect(c.accessEncrypted).toBeNull();
    expect(c.refreshEncrypted).toBeNull();
    await expect(a.access(p)).rejects.toThrow();
    expect(refreshes).toBe(1);
    evidence.push({ case: 'disconnect refresh fencing', lateRejected: true });
  });
  it('a superseded refresh lease/fence rejects the older network result', async () => {
    await connected();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .update(p.id, { expiresAt: new Date(Date.now() + 1000) });
    entered = deferred();
    gate = deferred();
    const x = a.access(p);
    const result = x.then(
      () => false,
      () => true,
    );
    await entered.promise;
    await db
      .getRepository(MicrosoftSmtpConnection)
      .createQueryBuilder()
      .update()
      .set({ fence: () => 'fence+1', leaseOwner: null, leaseExpiresAt: null })
      .where('"providerId"=:id', { id: p.id })
      .execute();
    gate.resolve();
    expect(await result).toBe(true);
    expect(refreshes).toBe(1);
  });
  it.each(['banned', 'role', 'version'] as const)(
    'original admin %s changed during exchange cannot connect',
    async (kind) => {
      const f = await received();
      entered = deferred();
      gate = deferred();
      const result = a.complete(f.flowId, s).then(
        () => false,
        () => true,
      );
      await entered.promise;
      await db
        .getRepository(User)
        .update(
          s.principal.userId,
          kind === 'banned'
            ? { banned: true }
            : kind === 'role'
              ? { role: 'user' }
              : { tokenVersion: 1 },
        );
      gate.resolve();
      expect(await result).toBe(true);
      expect(
        (
          await db
            .getRepository(MicrosoftSmtpConnection)
            .findOneByOrFail({ providerId: p.id })
        ).status,
      ).toBe('not_connected');
      expect(calls).toBe(1);
    },
  );
  it('original admin deadline crossing the network barrier rolls back connection', async () => {
    s.principal.expiresAt = Date.now() + 300000;
    const f = await received();
    entered = deferred();
    gate = deferred();
    const clock = jest.spyOn(Date, 'now');
    let now = Date.now();
    clock.mockImplementation(() => now);
    try {
      const result = a.complete(f.flowId, s).then(
        () => false,
        () => true,
      );
      await entered.promise;
      now = s.principal.expiresAt + 1;
      gate.resolve();
      expect(await result).toBe(true);
      expect(
        (
          await db
            .getRepository(MicrosoftSmtpConnection)
            .findOneByOrFail({ providerId: p.id })
        ).status,
      ).toBe('not_connected');
    } finally {
      clock.mockRestore();
    }
  });
  it('config generation changed during exchange cannot resurrect the connection', async () => {
    const f = await received();
    entered = deferred();
    gate = deferred();
    const result = a.complete(f.flowId, s).then(
      () => false,
      () => true,
    );
    await entered.promise;
    await b.disconnect(s);
    gate.resolve();
    expect(await result).toBe(true);
    const row = await db
      .getRepository(MicrosoftSmtpFlow)
      .findOneByOrFail({ id: f.flowId });
    expect(row.status).toBe('cancelled');
    expect(calls).toBe(1);
  });
  it('invalid_grant requires reauth; temporary HTTP failure preserves RT/config', async () => {
    await connected();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .update(p.id, { expiresAt: new Date(Date.now() + 1000) });
    const before = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    mode = 'temporary';
    await expect(a.access(p)).rejects.toThrow(
      'microsoft_temporarily_unavailable',
    );
    let c = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    expect(c.refreshEncrypted).toBe(before.refreshEncrypted);
    expect(c.status).toBe('connected');
    mode = 'invalid_grant';
    await expect(b.access(p)).rejects.toThrow('microsoft_needs_reauth');
    c = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    expect(c.status).toBe('needs_reauth');
    expect(c.refreshEncrypted).toBeNull();
    expect(
      (await db.getRepository(SmtpProvider).findOneByOrFail({ id: p.id }))
        .authMode,
    ).toBe('microsoft_oauth');
  });
  it('refresh OIDC cannot replace the original connection subject', async () => {
    await connected();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .update(p.id, { expiresAt: new Date(Date.now() + 1000) });
    mode = 'wrong_identity';
    await expect(a.access(p)).rejects.toThrow('microsoft_identity_changed');
    expect(
      (
        await db
          .getRepository(MicrosoftSmtpConnection)
          .findOneByOrFail({ providerId: p.id })
      ).subject,
    ).toBe('stable-subject');
  });
  it('shutdown aborts a pending exchange as unknown and never replays code', async () => {
    const f = await received();
    entered = deferred();
    gate = deferred();
    const result = a.complete(f.flowId, s).then(
      () => false,
      () => true,
    );
    await entered.promise;
    await a.onApplicationShutdown();
    gate.resolve();
    expect(await result).toBe(true);
    expect(calls).toBe(1);
    const row = await db
      .getRepository(MicrosoftSmtpFlow)
      .findOneByOrFail({ id: f.flowId });
    expect(row.status).toBe('exchanging');
    const status = await b.flowStatus(f.flowId, s);
    expect(status.status).toBe('exchanging');
    await b.complete(f.flowId, s);
    expect(calls).toBe(1);
    evidence.push({ case: 'shutdown', codeExchangeCalls: 1, replay: false });
  });
  it.each(['authorization', 'lease'] as const)(
    'complete %s expiry after final actual flow save rolls back token installation',
    async (kind) => {
      const f = await received();
      let now = Date.now();
      const clock = jest.spyOn(Date, 'now').mockImplementation(() => now);
      const store = (a as unknown as { store: MicrosoftSmtpStore }).store,
        original = store.transaction.bind(
          store,
        ) as MicrosoftSmtpStore['transaction'];
      const intercept = jest
        .spyOn(store, 'transaction')
        .mockImplementation((action) =>
          original(async (m: EntityManager) => {
            const save = m.save.bind(m) as (
              ...args: unknown[]
            ) => Promise<unknown>;
            m.save = (async (...args: unknown[]) => {
              const result: unknown = await Reflect.apply(save, m, args);
              if (
                args[0] instanceof MicrosoftSmtpFlow &&
                args[0].status === 'connected'
              )
                now =
                  kind === 'authorization'
                    ? s.principal.expiresAt! + 1
                    : now + 21000;
              return result;
            }) as EntityManager['save'];
            return action(m);
          }),
        );
      try {
        await expect(a.complete(f.flowId, s)).rejects.toThrow(
          kind === 'authorization'
            ? 'microsoft_authorization_expired'
            : 'microsoft_flow_stale',
        );
        const c = await db
          .getRepository(MicrosoftSmtpConnection)
          .findOneByOrFail({ providerId: p.id });
        expect(c.status).toBe('not_connected');
        expect(c.accessEncrypted).toBeNull();
        evidence.push({
          case: 'expiry after final real save',
          tokenInstallRolledBack: true,
        });
      } finally {
        clock.mockRestore();
        intercept.mockRestore();
      }
    },
  );
  it('refresh lease expiry after final actual connection save rolls back rotation', async () => {
    await connected();
    await db
      .getRepository(MicrosoftSmtpConnection)
      .update(p.id, { expiresAt: new Date(Date.now() + 1000) });
    const before = await db
      .getRepository(MicrosoftSmtpConnection)
      .findOneByOrFail({ providerId: p.id });
    let now = Date.now();
    const clock = jest.spyOn(Date, 'now').mockImplementation(() => now);
    const store = (a as unknown as { store: MicrosoftSmtpStore }).store,
      original = store.transaction.bind(
        store,
      ) as MicrosoftSmtpStore['transaction'];
    const intercept = jest
      .spyOn(store, 'transaction')
      .mockImplementation((action) =>
        original(async (m: EntityManager) => {
          const save = m.save.bind(m) as (
            ...args: unknown[]
          ) => Promise<unknown>;
          m.save = (async (...args: unknown[]) => {
            const result: unknown = await Reflect.apply(save, m, args);
            if (
              args[0] instanceof MicrosoftSmtpConnection &&
              args[0].refreshEncrypted !== before.refreshEncrypted &&
              args[0].leaseOwner === null
            )
              now += 21000;
            return result;
          }) as EntityManager['save'];
          return action(m);
        }),
      );
    try {
      await expect(a.access(p)).rejects.toThrow('microsoft_connection_stale');
      const c = await db
        .getRepository(MicrosoftSmtpConnection)
        .findOneByOrFail({ providerId: p.id });
      expect(c.refreshEncrypted).toBe(before.refreshEncrypted);
      expect(c.accessEncrypted).toBe(before.accessEncrypted);
      evidence.push({
        case: 'lease expiry after final real save',
        rotationRolledBack: true,
      });
    } finally {
      clock.mockRestore();
      intercept.mockRestore();
    }
  });
  it('HTTP exchange timeout is bounded/unknown and original code cannot be exchanged again', async () => {
    const f = await received();
    gate = deferred();
    const begin = Date.now();
    await expect(a.complete(f.flowId, s)).rejects.toThrow(
      'microsoft_response_unknown',
    );
    expect(Date.now() - begin).toBeLessThan(16000);
    expect((await b.flowStatus(f.flowId, s)).status).toBe('unknown');
    await b.complete(f.flowId, s);
    expect(calls).toBe(1);
    gate.resolve();
    evidence.push({
      case: 'real HTTP timeout',
      exchangeCalls: 1,
      replayed: false,
    });
  });
  it('HTTP exchange holds no SQL locks; another instance can read configuration while it waits', async () => {
    const f = await received();
    entered = deferred();
    gate = deferred();
    const result = a.complete(f.flowId, s);
    await entered.promise;
    const begin = Date.now();
    expect((await b.status()).configured).toBe(true);
    expect(Date.now() - begin).toBeLessThan(1500);
    gate.resolve();
    await result;
    evidence.push({
      case: 'network outside PG transaction',
      otherInstanceStatus: true,
    });
  });
  it('dedicated store initializes once across concurrent calls and does not inherit migration/subscriber/logging options', async () => {
    const store = (a as unknown as { store: MicrosoftSmtpStore }).store,
      pool = (store as unknown as { pool: DataSource }).pool,
      initialize = jest.spyOn(pool, 'initialize');
    await Promise.all([a.status(), a.status()]);
    expect(initialize).toHaveBeenCalledTimes(1);
    expect(pool.options).toMatchObject({
      synchronize: false,
      migrationsRun: false,
      dropSchema: false,
      logging: false,
      migrations: [],
      subscribers: [],
      installExtensions: false,
      extra: { max: 2, connectionTimeoutMillis: 3000 },
    });
    const closing = store.close();
    expect(store.close()).toBe(closing);
    await closing;
    expect(pool.isInitialized).toBe(false);
    await expect(a.status()).rejects.toThrow('邮件授权服务已停止');
  });
  it('shutdown during lazy initialization closes the new pool and prevents any post-shutdown operation', async () => {
    const store = (a as unknown as { store: MicrosoftSmtpStore }).store,
      pool = (store as unknown as { pool: DataSource }).pool,
      original = pool.initialize.bind(pool) as () => Promise<DataSource>,
      ready = deferred(),
      release = deferred();
    const initialize = jest
      .spyOn(pool, 'initialize')
      .mockImplementation(async () => {
        ready.resolve();
        await release.promise;
        return original();
      });
    const status = a.status().then(
      () => false,
      () => true,
    );
    await ready.promise;
    const close = a.onApplicationShutdown();
    release.resolve();
    await close;
    expect(await status).toBe(true);
    expect(pool.isInitialized).toBe(false);
    expect(initialize).toHaveBeenCalledTimes(1);
    await expect(a.status()).rejects.toThrow();
    evidence.push({
      case: 'pool shutdown/initialization barrier',
      closed: true,
    });
  });
  it('dedicated store sanitizes real SQL error/bind data before it can reach exceptions', async () => {
    const store = (a as unknown as { store: MicrosoftSmtpStore }).store;
    let error: unknown;
    try {
      await store.transaction((m) =>
        m.query('SELECT nonexistent_fixture_column, $1 AS secret', [
          'synthetic-private-bind',
        ]),
      );
    } catch (e) {
      error = e;
    }
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toBe('邮件授权存储暂不可用');
    expect(error).not.toHaveProperty('query');
    expect(error).not.toHaveProperty('parameters');
    expect(JSON.stringify(error)).not.toContain('synthetic-private-bind');
  });
});
