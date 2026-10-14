import { createHash } from 'node:crypto';
import { DataSource, type QueryRunner } from 'typeorm';
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
import {
  runMigrationsWithAdvisoryLock,
  revertLastMigrationWithAdvisoryLock,
} from '../../database/migration-runner';

const suite = process.env.MAIL_V1_PG_TEST === '1' ? describe : describe.skip;
suite(
  'V1 private nonce PG verification state/quota (synthetic SMTP only)',
  () => {
    jest.setTimeout(15000);
    let db: DataSource,
      now: number,
      verified = false;
    let deliveries: Array<{ to: string; code: string }>;
    let sendImpl: () => Promise<void>;
    const runners: QueryRunner[] = [];
    const evidence: unknown[] = [];
    const policies = () =>
      new AuthSettingsService(db.getRepository(AuthSettings));
    const service = (timeout = 30000) =>
      new VerificationService(
        db.getRepository(VerificationCode),
        policies(),
        {
          send: async (to: string, _subject: string, html: string) => {
            const match = />(\d{6})</.exec(html);
            if (!match) throw Error('synthetic code fixture missing');
            deliveries.push({ to, code: match[1] });
            await sendImpl();
          },
        } as never,
        { now: () => now, deliveryTimeoutMs: timeout },
      );
    const send = (
      s = service(),
      to = 'User@example.com',
      purpose: 'login' | 'register' | 'bind' = 'register',
      ip = '127.0.0.1',
    ) => s.generateAndSendCode('email', to, purpose, ip);
    const rows = () =>
      db.getRepository(VerificationCode).find({ order: { id: 'ASC' } });
    const setPolicy = (patch: Partial<AuthSettings>) =>
      policies().update(patch);
    async function waitForLock() {
      const end = Date.now() + 1500;
      for (;;) {
        const [row] = await db.query<Array<{ count: number }>>(
          "SELECT count(*)::int count FROM pg_stat_activity WHERE datname=current_database() AND application_name='mail-v1-test' AND wait_event_type='Lock'",
        );
        if (row.count) {
          evidence.push({ realPgLockWait: row.count });
          return;
        }
        if (Date.now() > end) throw Error('real_pg_lock_wait_missing');
        await new Promise((r) => setTimeout(r, 5));
      }
    }
    async function barrier() {
      const q = db.createQueryRunner();
      runners.push(q);
      await q.connect();
      await q.startTransaction();
      await q.query(
        "SELECT pg_advisory_xact_lock(178408,hashtext('email:User@example.com'))",
      );
      return q;
    }
    beforeAll(async () => {
      const e = process.env,
        nonce = e.MAIL_PG_NONCE,
        socket = e.MAIL_PG_SOCKET;
      if (
        !nonce ||
        !socket?.startsWith('/tmp/chatai-mail-V1-') ||
        !e.MAIL_PG_DATA_DIRECTORY?.startsWith('/tmp/chatai-mail-V1-') ||
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
          application_name: 'mail-v1-test',
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
      for (const q of runners.splice(0)) {
        if (q.isTransactionActive) await q.rollbackTransaction();
        if (!q.isReleased) await q.release();
      }
      await db.query('DELETE FROM ak_verification_codes');
      await db.query('DELETE FROM ak_auth_settings');
      now = Date.now();
      deliveries = [];
      sendImpl = async () => {};
      await policies().get();
    });
    afterEach(async () => {
      if (verified) {
        const saved = await rows();
        evidence.push({
          test: expect.getState().currentTestName,
          syntheticDeliveryCalls: deliveries.length,
          reservations: saved.map((r) => ({
            id: r.id,
            channel: r.channel,
            purpose: r.purpose,
            identifierDigest: createHash('sha256')
              .update(r.identifier)
              .digest('hex'),
            deliveryStatus: r.deliveryStatus,
            deliveryErrorCode: r.deliveryErrorCode,
            invalidationReason: r.invalidationReason,
            attempts: r.attempts,
            consumed: !!r.consumedAt,
            invalidated: !!r.invalidatedAt,
            createdAt: r.createdAt,
            expiresAt: r.expiresAt,
          })),
        });
      }
      jest.restoreAllMocks();
      for (const q of runners.splice(0)) {
        if (q.isTransactionActive) await q.rollbackTransaction();
        if (!q.isReleased) await q.release();
      }
    });
    afterAll(async () => {
      if (process.env.MAIL_PG_EVIDENCE)
        writeFileSync(
          process.env.MAIL_PG_EVIDENCE,
          JSON.stringify(
            {
              classification:
                'real private nonce PostgreSQL; fake SMTP promise; no real SMTP/OAuth/model HTTP',
              modelPost: 0,
              realSmtpPost: 0,
              evidence,
            },
            null,
            2,
          ),
        );
      if (db?.isInitialized) await db.destroy();
    });

    it('migration safe down/up keeps legacy unconfirmed code unusable', async () => {
      await revertLastMigrationWithAdvisoryLock(db);
      const hash = await bcrypt.hash('123456', 4);
      await db.query(
        'INSERT INTO ak_verification_codes(channel,identifier,purpose,"codeHash","expiresAt") VALUES($1,$2,$3,$4,$5)',
        ['email', 'User@example.com', 'register', hash, new Date(now + 300000)],
      );
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(1);
      const [r] = await rows();
      expect(r.deliveryStatus).toBe('legacy');
      await expect(
        service().verifyCode('email', r.identifier, 'register', '123456'),
      ).rejects.toThrow('无效');
      evidence.push({ safeDownUp: 1, legacyNeverPromoted: true });
    });
    it('two instances same canonical scope reserve/send only once', async () => {
      const results = await Promise.allSettled([
        service().generateAndSendCode(
          'email',
          ' User@EXAMPLE.COM ',
          'register',
          '127.0.0.1',
        ),
        send(service(), 'User@example.com', 'register', '127.0.0.2'),
      ]);
      expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
      expect(deliveries).toHaveLength(1);
      expect(await rows()).toHaveLength(1);
      expect((await rows())[0].deliveryStatus).toBe('sent');
      expect((await rows())[0].identifier).toBe('User@example.com');
    });
    it('one remaining identifier quota is atomic across purposes and instances', async () => {
      await setPolicy({ codeDailyLimitPerIdentifier: 2 });
      await send(service(), 'User@example.com', 'login');
      const results = await Promise.allSettled([
        send(service(), 'User@example.com', 'register', '127.0.0.2'),
        send(service(), 'User@example.com', 'bind', '127.0.0.3'),
      ]);
      expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
      expect(deliveries).toHaveLength(2);
      expect(await rows()).toHaveLength(2);
    });
    it('different identifiers share persistent IP limit after service reconstruction', async () => {
      await setPolicy({ codeHourlyLimitPerIp: 2 });
      await send(service(), 'one@example.com');
      await send(service(), 'two@example.com');
      await expect(send(service(), 'three@example.com')).rejects.toThrow('IP');
      expect(deliveries).toHaveLength(2);
      expect(await rows()).toHaveLength(2);
    });
    it.each(['EAUTH', 'ETIMEDOUT'])(
      '%s failure preserves quota and no plaintext error',
      async (code) => {
        await setPolicy({ codeDailyLimitPerIdentifier: 1 });
        sendImpl = () =>
          Promise.reject(
            Object.assign(Error('SECRET_RESPONSE_SENTINEL'), { code }),
          );
        await expect(send()).rejects.toThrow('验证码');
        const [r] = await rows();
        expect(r.deliveryStatus).toBe(code === 'EAUTH' ? 'failed' : 'unknown');
        expect(JSON.stringify(r)).not.toContain('SECRET_RESPONSE_SENTINEL');
        await expect(
          send(service(), 'User@example.com', 'login', '127.0.0.2'),
        ).rejects.toThrow('UTC');
        expect(deliveries).toHaveLength(1);
        expect(await rows()).toHaveLength(1);
      },
    );
    it('pending/timeout and late SMTP completion never become verifiable or resend', async () => {
      let release!: () => void;
      sendImpl = () =>
        new Promise<void>((r) => {
          release = r;
        });
      const sending = send(service(150));
      const result = sending.then(
        () => null,
        (error: unknown) => error,
      );
      while (!deliveries.length) await new Promise((r) => setTimeout(r, 5));
      expect((await rows())[0].deliveryStatus).toBe('pending');
      await expect(
        service().verifyCode(
          'email',
          'User@example.com',
          'register',
          deliveries[0].code,
        ),
      ).rejects.toThrow('无效');
      expect(await result).toBeInstanceOf(Error);
      release();
      await new Promise((r) => setTimeout(r, 5));
      expect((await rows())[0].deliveryStatus).toBe('unknown');
      expect(deliveries).toHaveLength(1);
    });
    it('later sent code supersedes an earlier pending send even if its SMTP completes late', async () => {
      let release!: () => void;
      let entered = 0;
      sendImpl = async () => {
        if (++entered === 1)
          await new Promise<void>((r) => {
            release = r;
          });
      };
      const a = send(service(1000000));
      const aResult = a.then(
        () => null,
        (e: unknown) => e,
      );
      while (!deliveries.length) await new Promise((r) => setTimeout(r, 5));
      now += 61000;
      await send(service(1000000));
      release();
      expect(await aResult).toBeInstanceOf(Error);
      const [old, current] = await rows();
      expect(old.invalidationReason).toBe('superseded');
      expect(old.deliveryStatus).toBe('unknown');
      expect(current.deliveryStatus).toBe('sent');
      expect(deliveries).toHaveLength(2);
    });
    it.each(['consumed', 'locked', 'expired', 'failed'])(
      'latest %s never falls back to older code',
      async (terminal) => {
        await send();
        const oldCode = deliveries[0].code;
        now += 61000;
        if (terminal === 'failed')
          sendImpl = () =>
            Promise.reject(
              Object.assign(Error('synthetic'), { code: 'EAUTH' }),
            );
        await send().catch((e: unknown) => {
          if (terminal !== 'failed') throw e;
        });
        const list = await rows(),
          current = list[1];
        if (terminal === 'consumed')
          await service().verifyCode(
            'email',
            current.identifier,
            'register',
            deliveries[1].code,
          );
        if (terminal === 'locked') {
          await setPolicy({ codeMaxAttempts: 1 });
          await service()
            .verifyCode('email', current.identifier, 'register', '000000')
            .catch(() => {});
        }
        if (terminal === 'expired') {
          now = current.expiresAt.getTime() + 1;
          await service()
            .verifyCode(
              'email',
              current.identifier,
              'register',
              deliveries[1].code,
            )
            .catch(() => {});
        }
        // 合成旧 sent 行未带 invalidated 字段，证明 latest 选择本身也不会回落。
        await db.getRepository(VerificationCode).update(list[0].id, {
          invalidatedAt: null,
          invalidationReason: null,
        });
        await expect(
          service().verifyCode(
            'email',
            current.identifier,
            'register',
            oldCode,
          ),
        ).rejects.toThrow('验证码');
        expect((await rows())[0].consumedAt).toBeNull();
        expect((await rows())[1].id).toBe(current.id);
      },
    );
    it('concurrent wrong attempts persist five times and lock without counter rollback', async () => {
      await send();
      const attempts = await Promise.allSettled(
        Array.from({ length: 5 }, () =>
          service().verifyCode(
            'email',
            'User@example.com',
            'register',
            '000000',
          ),
        ),
      );
      expect(attempts.every((r) => r.status === 'rejected')).toBe(true);
      const [r] = await rows();
      expect(r.attempts).toBe(5);
      expect(r.invalidationReason).toBe('locked');
      await expect(
        service().verifyCode(
          'email',
          r.identifier,
          'register',
          deliveries[0].code,
        ),
      ).rejects.toThrow('验证码');
    });
    it('real PG lock wait crossing expiry rejects without consuming successful code', async () => {
      await send();
      const [r] = await rows(),
        q = await barrier();
      const outcome = service()
        .verifyCode('email', r.identifier, 'register', deliveries[0].code)
        .then(
          () => null,
          (e: unknown) => e,
        );
      await waitForLock();
      now = r.expiresAt.getTime() + 1;
      await q.commitTransaction();
      await q.release();
      expect(await outcome).toBeInstanceOf(Error);
      const [after] = await rows();
      expect(after.invalidationReason).toBe('expired');
      expect(after.attempts).toBe(0);
    });
    it('async bcrypt comparison crossing expiry is rechecked before consumption', async () => {
      await send();
      const [r] = await rows();
      const original = bcrypt.compare;
      const compareSpy = jest.spyOn(
        bcrypt,
        'compare',
      ) as unknown as jest.MockInstance<Promise<boolean>, [string, string]>;
      compareSpy.mockImplementationOnce(async (plain, hash) => {
        const valid = await original(plain, hash);
        now = r.expiresAt.getTime() + 1;
        return valid;
      });
      await expect(
        service().verifyCode(
          'email',
          r.identifier,
          'register',
          deliveries[0].code,
        ),
      ).rejects.toThrow('过期');
      expect((await rows())[0].invalidationReason).toBe('expired');
    });
    it('unacknowledged final DB update stays pending; reconstructing service never resends', async () => {
      await db.query(
        "CREATE FUNCTION fixture_reject_sent() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.\"deliveryStatus\"='sent' THEN RAISE EXCEPTION 'synthetic_update_failure'; END IF; RETURN NEW; END $$",
      );
      await db.query(
        'CREATE TRIGGER fixture_reject_sent BEFORE UPDATE ON ak_verification_codes FOR EACH ROW EXECUTE FUNCTION fixture_reject_sent()',
      );
      try {
        await expect(send()).rejects.toThrow('存储');
        expect((await rows())[0].deliveryStatus).toBe('pending');
        expect(deliveries).toHaveLength(1);
        await expect(
          service().verifyCode(
            'email',
            'User@example.com',
            'register',
            deliveries[0].code,
          ),
        ).rejects.toThrow('无效');
        expect(deliveries).toHaveLength(1);
      } finally {
        await db.query(
          'DROP TRIGGER fixture_reject_sent ON ak_verification_codes',
        );
        await db.query('DROP FUNCTION fixture_reject_sent()');
      }
    });
    it('updated policy is read by the other existing instance without a cache window', async () => {
      const a = policies(),
        b = policies();
      expect((await a.get()).codeDailyLimitPerIdentifier).toBe(10);
      await b.update({ codeDailyLimitPerIdentifier: 1 });
      expect((await a.get()).codeDailyLimitPerIdentifier).toBe(1);
      await send();
      await expect(
        send(service(), 'User@example.com', 'login'),
      ).rejects.toThrow('UTC');
    });
    it('local-part case and plus aliases remain distinct while domain is normalized', async () => {
      await send(service(), 'User@EXAMPLE.COM');
      await send(service(), 'user@example.com');
      await send(service(), 'User+tag@example.com');
      expect((await rows()).map((r) => r.identifier)).toEqual([
        'User@example.com',
        'user@example.com',
        'User+tag@example.com',
      ]);
    });
    it('legacy domain casing lookup preserves account/local-part and ambiguous rows fail closed', async () => {
      const repo = db.getRepository(User),
        resolver = new ChatGptUserResolver(repo);
      const first = await repo.save(
        repo.create({
          userName: 'synthetic_domain_1',
          email: 'Legacy@EXAMPLE.COM',
          password: null,
        }),
      );
      expect((await resolver.findByEmail('Legacy@example.com'))?.id).toBe(
        first.id,
      );
      expect((await repo.findOneByOrFail({ id: first.id })).email).toBe(
        'Legacy@EXAMPLE.COM',
      );
      expect(await resolver.findByEmail('legacy@example.com')).toBeNull();
      const second = await repo.save(
        repo.create({
          userName: 'synthetic_domain_2',
          email: 'Legacy@example.com',
          password: null,
        }),
      );
      await expect(resolver.findByEmail('Legacy@example.com')).rejects.toThrow(
        '冲突',
      );
      await repo.delete([first.id, second.id]);
    });
    it('UTC day and rolling IP hour use recorded reservations and never reset on failure', async () => {
      now = Date.UTC(2026, 9, 12, 23, 59, 30);
      await setPolicy({
        codeDailyLimitPerIdentifier: 1,
        codeHourlyLimitPerIp: 1,
      });
      await send();
      now += 60000;
      await expect(
        send(service(), 'User@example.com', 'login'),
      ).rejects.toThrow('IP');
      now += 3600000;
      await send(service(), 'User@example.com', 'login');
      expect(await rows()).toHaveLength(2);
    });
  },
);
