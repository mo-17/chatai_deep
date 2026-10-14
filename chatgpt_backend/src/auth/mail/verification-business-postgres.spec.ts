import { DataSource, type QueryRunner, type EntityManager } from 'typeorm';
import { readFileSync, writeFileSync, statSync } from 'node:fs';
import bcrypt from 'bcryptjs';
import { VerificationService } from '../../../libs/auth-kit/src/verification/verification.service';
import { VerificationCode } from '../../../libs/auth-kit/src/verification/entities/verification-code.entity';
import { AuthSettings } from '../../../libs/auth-kit/src/verification/entities/auth-settings.entity';
import { SmtpProvider } from '../../../libs/auth-kit/src/verification/entities/smtp-provider.entity';
import { EmailTemplate } from '../../../libs/auth-kit/src/verification/entities/email-template.entity';
import { User } from '../../user/user.entity';
import { ChatGptUserResolver } from '../chatgpt-user.resolver';
import { AuthSettingsService } from '../../../libs/auth-kit/src/settings/auth-settings.service';
import { CreateCoreBaseline1783990000000 } from '../../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../../migrations/1784020000000-AddAppVersionSha256';
import { AddUserTokenVersion1784030000000 } from '../../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudDispatchPermit1784050000000 } from '../../migrations/1784050000000-AddCloudDispatchPermit';
import { AddCloudSchedulerGate1784060000000 } from '../../migrations/1784060000000-AddCloudSchedulerGate';
import { AddVerificationDeliveryState1784070000000 } from '../../migrations/1784070000000-AddVerificationDeliveryState';
import { runMigrationsWithAdvisoryLock } from '../../database/migration-runner';

import { AuthController } from '../../../libs/auth-kit/src/controllers/auth.controller';
import { ThirdPartyController } from '../../../libs/auth-kit/src/controllers/third-party.controller';
import { TokenAuthenticationService } from '../token-authentication.service';
import { JWT_SECRET } from '../jwt.const';
import type { IUserResolver } from '../../../libs/auth-kit/src/contracts/user-resolver.interface';
import type { AuthKitModuleOptions } from '../../../libs/auth-kit/src/auth-kit.module';
import type { Request } from 'express';
import * as jwt from 'jsonwebtoken';
const suite = process.env.MAIL_V2_PG_TEST === '1' ? describe : describe.skip;
const kinds = [
  'login',
  'register',
  'bind',
  'reset',
  'huawei',
  'apple',
] as const;
type Kind = (typeof kinds)[number];
const secret = 'synthetic-V2-bind-ticket-key-0123456789abcdef';
suite(
  'V2 actual controllers/resolver/code transaction (private PG; no network)',
  () => {
    jest.setTimeout(15000);
    let db: DataSource,
      verified = false,
      now: number;
    let hash: string;
    const runners: QueryRunner[] = [];
    const evidence: unknown[] = [];
    const policies = () =>
      new AuthSettingsService(db.getRepository(AuthSettings));
    const service = () =>
      new VerificationService(
        db.getRepository(VerificationCode),
        policies(),
        {
          send: () => {
            throw Error('real_send_forbidden');
          },
        } as never,
        { now: () => now },
      );
    function controllers() {
      const managers: EntityManager[] = [];
      const resolver = new ChatGptUserResolver(db.getRepository(User));
      // 红轮同一 fixture 可在 V1 宿主运行；新生产路径必须在 sign 断言中证明真实事务已释放。
      if (typeof resolver.withManager === 'function') {
        const bindManager = resolver.withManager.bind(resolver) as (
          manager: EntityManager,
        ) => IUserResolver;
        jest.spyOn(resolver, 'withManager').mockImplementation((manager) => {
          managers.push(manager);
          return bindManager(manager);
        });
      }
      const sign = jest.fn().mockImplementation(() => {
        expect(managers.length).toBeGreaterThan(0);
        expect(managers.at(-1)?.queryRunner?.isTransactionActive).toBe(false);
        expect(managers.at(-1)?.queryRunner?.isReleased).toBe(true);
        return 'synthetic-committed-jwt';
      });
      const options = {
        userResolver: resolver,
        jwtSigner: { sign },
        appSecretKey: secret,
        accessTokenVerifier: new TokenAuthenticationService(
          db.getRepository(User),
        ),
      } as AuthKitModuleOptions;
      return {
        normal: new AuthController(service(), policies(), options),
        third: new ThirdPartyController(
          service(),
          {} as never,
          {} as never,
          options,
        ),
        sign,
      };
    }
    const rows = () =>
      db.getRepository(VerificationCode).find({ order: { id: 'ASC' } });
    const users = () => db.getRepository(User).find({ order: { id: 'ASC' } });
    async function makeCase(kind: Kind, channel: 'email' | 'sms' = 'email') {
      const repo = db.getRepository(User);
      const email = 'Proof@example.com';
      const identifier = channel === 'email' ? email : '+1 2025550199';
      const userIdentity =
        channel === 'email'
          ? { email }
          : { countryCode: '+1', phoneNumber: '2025550199' };
      let actor: User | undefined;
      if (kind === 'bind')
        actor = await repo.save(
          repo.create({ userName: 'actor', password: null }),
        );
      if (kind === 'reset')
        actor = await repo.save(
          repo.create({
            userName: 'reset',
            ...userIdentity,
            password: 'old-hash',
            tokenVersion: 0,
          }),
        );
      if (kind === 'huawei' || kind === 'apple')
        actor = await repo.save(
          repo.create({
            userName: 'pending',
            password: null,
            ...(kind === 'huawei'
              ? { huaweiUnionId: 'synthetic-union' }
              : { appleSubject: 'synthetic-sub' }),
          }),
        );
      const purpose =
        kind === 'login'
          ? 'login'
          : kind === 'register'
            ? 'register'
            : kind === 'reset'
              ? 'reset_password'
              : 'bind';
      const code = await db.getRepository(VerificationCode).save({
        channel,
        identifier,
        purpose,
        codeHash: hash,
        deliveryStatus: 'sent',
        createdAt: new Date(now),
        expiresAt: new Date(now + 300000),
        sentAt: new Date(now),
      });
      const c = controllers();
      const common = {
        channel,
        identifier,
        code: '123456',
      };
      const invoke = () => {
        if (kind === 'login') return c.normal.loginByCode(common);
        if (kind === 'register')
          return c.normal.register({
            ...common,
            password: 'synthetic-password',
          });
        if (kind === 'reset')
          return c.normal.resetPassword({
            ...common,
            newPassword: 'synthetic-new-password',
          });
        if (kind === 'bind')
          return c.normal.bind(common, {
            user: { userId: actor!.id, tokenVersion: 0 },
          } as Request & { user: { userId: number; tokenVersion: number } });
        const bindTicket = jwt.sign(
          { purpose: 'third_party_bind', provider: kind },
          secret,
          {
            algorithm: 'HS256',
            audience: 'auth-kit:third-party-bind',
            issuer: 'auth-kit',
            subject: String(actor!.id),
            expiresIn: '10m',
            jwtid: 'synthetic-ticket',
          },
        );
        return kind === 'huawei'
          ? c.third.huaweiBindAndLogin({ ...common, bindTicket })
          : c.third.appleBindAndLogin({ ...common, bindTicket });
      };
      return { kind, actor, code, invoke, sign: c.sign, common };
    }
    async function waitForLock() {
      const end = Date.now() + 2000;
      for (;;) {
        const [r] = await db.query<Array<{ count: number }>>(
          "SELECT count(*)::int count FROM pg_stat_activity WHERE datname=current_database() AND application_name='mail-v2-test' AND wait_event_type='Lock'",
        );
        if (r.count) {
          evidence.push({ realPgLockWait: r.count });
          return;
        }
        if (Date.now() > end) throw Error('real_pg_lock_wait_missing');
        await new Promise((r) => setTimeout(r, 5));
      }
    }
    async function lockUser(id: number) {
      const q = db.createQueryRunner();
      runners.push(q);
      await q.connect();
      await q.startTransaction();
      await q.query('SELECT id FROM users WHERE id=$1 FOR UPDATE', [id]);
      return q;
    }
    async function trigger(target: 'business' | 'consume', kind: Kind) {
      const table = target === 'consume' ? 'ak_verification_codes' : 'users';
      const condition =
        target === 'consume'
          ? 'NEW."invalidationReason"=\'consumed\''
          : kind === 'reset'
            ? 'NEW.password IS DISTINCT FROM OLD.password'
            : kind === 'login' || kind === 'register'
              ? 'NEW."emailVerifiedAt" IS NOT NULL'
              : 'NEW.email IS DISTINCT FROM OLD.email';
      await db.query(
        'CREATE FUNCTION fixture_v2_reject() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF ' +
          condition +
          " THEN RAISE EXCEPTION 'synthetic_business_failure'; END IF; RETURN NEW; END $$",
      );
      await db.query(
        'CREATE TRIGGER fixture_v2_reject BEFORE UPDATE ON ' +
          table +
          ' FOR EACH ROW EXECUTE FUNCTION fixture_v2_reject()',
      );
      return async () => {
        await db.query('DROP TRIGGER fixture_v2_reject ON ' + table);
        await db.query('DROP FUNCTION fixture_v2_reject()');
      };
    }
    beforeAll(async () => {
      const e = process.env,
        nonce = e.MAIL_PG_NONCE,
        socket = e.MAIL_PG_SOCKET;
      if (
        !nonce ||
        !socket?.startsWith('/tmp/chatai-mail-V2-') ||
        !e.MAIL_PG_DATA_DIRECTORY?.startsWith('/tmp/chatai-mail-V2-') ||
        e.MAIL_PG_DATABASE !== 'chatai_mail_test_' + nonce ||
        e.MAIL_PG_USER !== 'mail_' + nonce ||
        !e.MAIL_PG_PORT
      )
        throw Error('private_mail_nonce_config_required');
      expect(statSync(socket).mode & 0o777).toBe(0o700);
      const sentinel = JSON.parse(
        readFileSync(socket + '/fixture-sentinel.json', 'utf8'),
      ) as { nonce: string };
      expect(sentinel.nonce).toBe(nonce);
      db = new DataSource({
        type: 'postgres',
        host: socket,
        port: Number(e.MAIL_PG_PORT),
        username: e.MAIL_PG_USER,
        database: e.MAIL_PG_DATABASE,
        password: '',
        synchronize: false,
        migrationsRun: false,
        logging: false,
        entities: [
          VerificationCode,
          AuthSettings,
          SmtpProvider,
          EmailTemplate,
          User,
        ],
        migrations: [
          CreateCoreBaseline1783990000000,
          CreateSyncV21784000000000,
          AddAppVersionSha2561784020000000,
          AddUserTokenVersion1784030000000,
          CreateCloudWorkflows1784040000000,
          AddCloudDispatchPermit1784050000000,
          AddCloudSchedulerGate1784060000000,
          AddVerificationDeliveryState1784070000000,
        ],
        extra: {
          max: 8,
          connectionTimeoutMillis: 3000,
          application_name: 'mail-v2-test',
        },
      });
      await db.initialize();
      const [identity] = await db.query<Array<Record<string, string>>>(
        "SELECT current_database() db,current_user usr,current_setting('data_directory') directory,current_setting('listen_addresses') tcp",
      );
      expect(identity).toEqual({
        db: e.MAIL_PG_DATABASE,
        usr: e.MAIL_PG_USER,
        directory: e.MAIL_PG_DATA_DIRECTORY,
        tcp: '',
      });
      verified = true;
      evidence.push({ identity, nonce, tcpEnabled: false, socketMode: '0700' });
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(8);
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(0);
      evidence.push({
        migrationApply: 8,
        migrationNoop: 0,
        sharedRunner: true,
      });
    });

    beforeEach(async () => {
      if (!verified) throw Error('private_identity_not_verified');
      await db.query('DELETE FROM ak_verification_codes');
      await db.query('DELETE FROM users');
      await db.query('DELETE FROM ak_auth_settings');
      await policies().get();
      now = Date.now();
      hash = await bcrypt.hash('123456', 4);
    });
    afterEach(async () => {
      jest.restoreAllMocks();
      for (const q of runners.splice(0)) {
        if (q.isTransactionActive) await q.rollbackTransaction();
        if (!q.isReleased) await q.release();
      }
      if (verified)
        evidence.push({
          test: expect.getState().currentTestName,
          codes: (await rows()).map((r) => ({
            id: r.id,
            purpose: r.purpose,
            attempts: r.attempts,
            consumed: !!r.consumedAt,
            reason: r.invalidationReason,
          })),
          users: (await users()).map((u) => ({
            id: u.id,
            tokenVersion: u.tokenVersion,
            emailVerified: !!u.emailVerifiedAt,
            banned: u.banned,
            provider: u.huaweiUnionId
              ? 'huawei'
              : u.appleSubject
                ? 'apple'
                : null,
          })),
          realNetworkCalls: 0,
        });
    });
    afterAll(async () => {
      if (process.env.MAIL_PG_EVIDENCE)
        writeFileSync(
          process.env.MAIL_PG_EVIDENCE,
          JSON.stringify(
            {
              classification:
                'real isolated PostgreSQL; actual controller/resolver/service; synthetic JWT and sent-code rows; zero SMTP/OAuth/model',
              evidence,
            },
            null,
            2,
          ),
        );
      if (db?.isInitialized) await db.destroy();
    });
    it.each(kinds)(
      '%s concurrent correct code commits exactly one business and JWT only after commit',
      async (kind) => {
        const c = await makeCase(kind);
        const outcomes = await Promise.allSettled([c.invoke(), c.invoke()]);
        expect(outcomes.filter((r) => r.status === 'fulfilled')).toHaveLength(
          1,
        );
        expect(c.sign).toHaveBeenCalledTimes(
          kind === 'bind' || kind === 'reset' ? 0 : 1,
        );
        const saved = await users();
        expect(saved).toHaveLength(1);
        expect(saved[0].email).toBe(c.common.identifier);
        if (kind === 'reset') {
          expect(saved[0].tokenVersion).toBe(1);
          expect(
            await bcrypt.compare('synthetic-new-password', saved[0].password!),
          ).toBe(true);
        } else expect(saved[0].emailVerifiedAt).not.toBeNull();
        expect((await rows())[0].invalidationReason).toBe('consumed');
      },
    );
    it.each(kinds)(
      '%s synthetic SMS sent-row uses same transactional account/consumption path',
      async (kind) => {
        const c = await makeCase(kind, 'sms');
        await c.invoke();
        const saved = await users();
        expect(saved).toHaveLength(1);
        expect(saved[0]).toMatchObject({
          countryCode: '+1',
          phoneNumber: '2025550199',
        });
        if (kind === 'reset') expect(saved[0].tokenVersion).toBe(1);
        else expect(saved[0].phoneVerifiedAt).not.toBeNull();
        expect((await rows())[0].invalidationReason).toBe('consumed');
        expect(c.sign).toHaveBeenCalledTimes(
          kind === 'bind' || kind === 'reset' ? 0 : 1,
        );
      },
    );
    it.each(kinds)(
      '%s business write failure rolls back code/user and same code can be explicitly retried',
      async (kind) => {
        const c = await makeCase(kind),
          before = await users(),
          remove = await trigger('business', kind);
        try {
          await expect(c.invoke()).rejects.toThrow();
          expect(await users()).toEqual(before);
          expect((await rows())[0].consumedAt).toBeNull();
          expect(c.sign).not.toHaveBeenCalled();
        } finally {
          await remove();
        }
        await c.invoke();
        expect((await rows())[0].invalidationReason).toBe('consumed');
      },
    );
    it.each(kinds)(
      '%s final consume write failure rolls back all user changes and emits no JWT',
      async (kind) => {
        const c = await makeCase(kind),
          before = await users(),
          remove = await trigger('consume', kind);
        try {
          await expect(c.invoke()).rejects.toThrow();
          expect(await users()).toEqual(before);
          expect((await rows())[0].consumedAt).toBeNull();
          expect(c.sign).not.toHaveBeenCalled();
        } finally {
          await remove();
        }
      },
    );
    it.each(['bind', 'reset', 'huawei', 'apple'] as const)(
      '%s user lock crosses code expiry: no business/consumption/JWT',
      async (kind) => {
        const c = await makeCase(kind),
          before = await users(),
          q = await lockUser(c.actor!.id);
        const outcome = c.invoke().then(
          () => null,
          (e: unknown) => e,
        );
        await waitForLock();
        now = c.code.expiresAt.getTime() + 1;
        await q.commitTransaction();
        await q.release();
        expect(await outcome).toBeInstanceOf(Error);
        expect(await users()).toEqual(before);
        expect((await rows())[0].consumedAt).toBeNull();
        expect(c.sign).not.toHaveBeenCalled();
      },
    );
    it.each(['banned', 'tokenVersion'] as const)(
      'real verified bind JWT then user lock %s change cannot consume code',
      async (field) => {
        const c = await makeCase('bind');
        const token = jwt.sign(
          { userId: c.actor!.id, tokenVersion: 0 },
          JWT_SECRET,
          { algorithm: 'HS256', expiresIn: '10m' },
        );
        const principal = await new TokenAuthenticationService(
          db.getRepository(User),
        ).verify(token);
        expect(principal).not.toBeNull();
        const q = await lockUser(c.actor!.id);
        const outcome = controllers()
          .normal.bind(c.common, { user: principal } as never)
          .then(
            () => null,
            (e: unknown) => e,
          );
        await waitForLock();
        await q.query(
          field === 'banned'
            ? 'UPDATE users SET banned=true WHERE id=$1'
            : 'UPDATE users SET "tokenVersion"=1 WHERE id=$1',
          [c.actor!.id],
        );
        await q.commitTransaction();
        await q.release();
        expect(await outcome).toBeInstanceOf(Error);
        expect((await rows())[0].consumedAt).toBeNull();
        expect((await users())[0].email).toBeNull();
      },
    );
    it.each(['reset', 'huawei', 'apple'] as const)(
      '%s ban during held user lock rejects without code consumption',
      async (kind) => {
        const c = await makeCase(kind),
          q = await lockUser(c.actor!.id);
        const outcome = c.invoke().then(
          () => null,
          (e: unknown) => e,
        );
        await waitForLock();
        await q.query('UPDATE users SET banned=true WHERE id=$1', [
          c.actor!.id,
        ]);
        await q.commitTransaction();
        await q.release();
        expect(await outcome).toBeInstanceOf(Error);
        expect((await rows())[0].consumedAt).toBeNull();
        expect(c.sign).not.toHaveBeenCalled();
        if (kind !== 'reset') expect((await users())[0].email).toBeNull();
        else expect((await users())[0].password).toBe('old-hash');
      },
    );
    it('verified bind JWT expires while waiting for user lock: no binding or consumption', async () => {
      const c = await makeCase('bind');
      const token = jwt.sign(
        { userId: c.actor!.id, tokenVersion: 0 },
        JWT_SECRET,
        { algorithm: 'HS256', expiresIn: '10m' },
      );
      const principal = await new TokenAuthenticationService(
        db.getRepository(User),
      ).verify(token);
      expect(principal?.expiresAt).toEqual(expect.any(Number));
      const q = await lockUser(c.actor!.id);
      const outcome = controllers()
        .normal.bind(c.common, { user: principal } as never)
        .then(
          () => null,
          (e: unknown) => e,
        );
      await waitForLock();
      jest.spyOn(Date, 'now').mockReturnValue(principal!.expiresAt! + 1);
      await q.commitTransaction();
      await q.release();
      expect(await outcome).toBeInstanceOf(Error);
      expect((await rows())[0].consumedAt).toBeNull();
      expect((await users())[0].email).toBeNull();
    });
    it.each(['huawei', 'apple'] as const)(
      '%s consumed pending identity cannot replay ticket with another code',
      async (kind) => {
        const c = await makeCase(kind);
        await c.invoke();
        await db.getRepository(VerificationCode).save({
          channel: 'email',
          identifier: 'Second@example.com',
          purpose: 'bind',
          codeHash: hash,
          deliveryStatus: 'sent',
          createdAt: new Date(now + 1),
          expiresAt: new Date(now + 300000),
        });
        const bindTicket = jwt.sign(
          { purpose: 'third_party_bind', provider: kind },
          secret,
          {
            algorithm: 'HS256',
            audience: 'auth-kit:third-party-bind',
            issuer: 'auth-kit',
            subject: String(c.actor!.id),
            expiresIn: '10m',
          },
        );
        const c2 = controllers(),
          body = {
            channel: 'email' as const,
            identifier: 'Second@example.com',
            code: '123456',
            bindTicket,
          };
        await expect(
          kind === 'huawei'
            ? c2.third.huaweiBindAndLogin(body)
            : c2.third.appleBindAndLogin(body),
        ).rejects.toThrow('已使用');
        expect((await users())[0].email).toBe(c.common.identifier);
        expect((await rows())[1].consumedAt).toBeNull();
        expect(c2.sign).not.toHaveBeenCalled();
      },
    );
    it('login existing banned user never consumes or signs', async () => {
      const c = await makeCase('login');
      await db.getRepository(User).save({
        userName: 'blocked',
        email: c.common.identifier,
        banned: true,
        password: null,
      });
      await expect(c.invoke()).rejects.toThrow('封禁');
      expect((await rows())[0].consumedAt).toBeNull();
      expect(c.sign).not.toHaveBeenCalled();
    });
    it('register duplicate and bind ownership conflict preserve usable code without partial mutation', async () => {
      const c = await makeCase('bind');
      await db.getRepository(User).save({
        userName: 'existing',
        email: c.common.identifier,
        password: null,
      });
      const before = await users();
      await expect(c.invoke()).rejects.toThrow('其他账号');
      expect(await users()).toEqual(before);
      expect((await rows())[0].consumedAt).toBeNull();
      const r = await makeCase('register');
      await expect(r.invoke()).rejects.toThrow('注册');
      expect((await rows())[1].consumedAt).toBeNull();
      expect(r.sign).not.toHaveBeenCalled();
    });
    it('wrong code counters commit independently while business callback is never invoked', async () => {
      const c = await makeCase('register'),
        action = jest.fn();
      const outcomes = await Promise.allSettled(
        Array.from({ length: 5 }, () =>
          service().consumeWith(
            'email',
            c.common.identifier,
            'register',
            '000000',
            action,
          ),
        ),
      );
      expect(outcomes.every((r) => r.status === 'rejected')).toBe(true);
      expect(action).not.toHaveBeenCalled();
      expect(await users()).toHaveLength(0);
      expect((await rows())[0]).toMatchObject({
        attempts: 5,
        invalidationReason: 'locked',
      });
      await expect(c.invoke()).rejects.toThrow('验证码');
    });
    it.each(['expired', 'locked'] as const)(
      'latest %s does not fall back to older sent code in controller',
      async (state) => {
        const c = await makeCase('login'),
          r = db.getRepository(VerificationCode);
        await r.save({
          channel: 'email',
          identifier: c.common.identifier,
          purpose: 'login',
          codeHash: hash,
          deliveryStatus: 'sent',
          createdAt: new Date(now + 1),
          expiresAt: new Date(state === 'expired' ? now - 1 : now + 300000),
          attempts: state === 'locked' ? 5 : 0,
        });
        await expect(c.invoke()).rejects.toThrow('验证码');
        expect((await rows())[0].consumedAt).toBeNull();
        expect(await users()).toHaveLength(0);
        expect(c.sign).not.toHaveBeenCalled();
      },
    );
    it('business finishes after expiry rolls back its write instead of consuming or committing half user', async () => {
      const c = await makeCase('register'),
        before = await users();
      await expect(
        service().consumeWith(
          'email',
          c.common.identifier,
          'register',
          '123456',
          async (manager) => {
            await new ChatGptUserResolver(db.getRepository(User))
              .withManager(manager)
              .createUser({ email: c.common.identifier, userName: 'late' });
            now = c.code.expiresAt.getTime() + 1;
          },
        ),
      ).rejects.toThrow('过期');
      expect(await users()).toEqual(before);
      expect((await rows())[0].consumedAt).toBeNull();
    });
    it('different purposes share identifier lock and cannot create duplicate accounts', async () => {
      const login = await makeCase('login'),
        register = await makeCase('register');
      const outcomes = await Promise.allSettled([
        login.invoke(),
        register.invoke(),
      ]);
      expect(await users()).toHaveLength(1);
      expect(
        outcomes.filter((r) => r.status === 'fulfilled').length,
      ).toBeGreaterThanOrEqual(1);
      expect(
        (await rows()).filter((r) => r.invalidationReason === 'consumed')
          .length,
      ).toBeGreaterThanOrEqual(1);
    });
    it('bound resolver rejects a manager outside transaction and never falls back to global repository', () => {
      expect(() =>
        new ChatGptUserResolver(db.getRepository(User)).withManager(db.manager),
      ).toThrow('事务');
    });
  },
);
