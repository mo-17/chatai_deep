import { DataSource, type EntityManager } from 'typeorm';
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
import * as jwt from 'jsonwebtoken';
const suite = process.env.MAIL_V2_PG_TEST === '1' ? describe : describe.skip;
const secret = 'synthetic-V2-bind-ticket-key-0123456789abcdef';
const kinds = ['bind', 'huawei', 'apple'] as const;
type Kind = (typeof kinds)[number];
type Phase = 'business' | 'consume';
const cases = kinds.flatMap((kind) =>
  (['business', 'consume'] as const).map((phase) => [kind, phase] as const),
);
type TxAction = (manager: EntityManager) => Promise<unknown>;
suite(
  'V2 final authorization grant PG boundary (shared dynamic clock; injected async barriers)',
  () => {
    jest.setTimeout(10000);
    let db: DataSource,
      verified = false,
      now: number;
    const evidence: unknown[] = [];
    const policies = () =>
      new AuthSettingsService(db.getRepository(AuthSettings));
    const users = () => db.getRepository(User).find({ order: { id: 'ASC' } });
    const rows = () =>
      db.getRepository(VerificationCode).find({ order: { id: 'ASC' } });
    function barrier() {
      let enter!: () => void, release!: () => void;
      const entered = new Promise<void>((r) => {
        enter = r;
      });
      const waiting = new Promise<void>((r) => {
        release = r;
      });
      return {
        entered,
        release,
        hold: async () => {
          enter();
          await waiting;
        },
      };
    }
    async function reached(entered: Promise<void>) {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        await Promise.race([
          entered,
          new Promise<never>((_, reject) => {
            timer = setTimeout(
              () => reject(Error('injected_barrier_not_reached')),
              1500,
            );
          }),
        ]);
      } finally {
        if (timer) clearTimeout(timer);
      }
    }
    async function exercise(
      kind: Kind,
      phase: Phase,
      expire: boolean,
      legacy = false,
    ) {
      const repo = db.getRepository(User);
      const actor = await repo.save(
        repo.create({
          userName: 'actor',
          password: null,
          ...(kind === 'huawei'
            ? { huaweiUnionId: 'synthetic-union' }
            : kind === 'apple'
              ? { appleSubject: 'synthetic-sub' }
              : {}),
        }),
      );
      const code = await db.getRepository(VerificationCode).save({
        channel: 'email',
        identifier: 'Proof@example.com',
        purpose: 'bind',
        codeHash: await bcrypt.hash('123456', 4),
        deliveryStatus: 'sent',
        createdAt: new Date(now),
        expiresAt: new Date(now + 300000),
        sentAt: new Date(now),
      });
      const beforeUsers = await users(),
        beforeCodes = await rows();
      const exp = Math.floor(now / 1000) + 1,
        deadline = exp * 1000;
      const gate = barrier(),
        observations: Array<Record<string, unknown>> = [];
      const managers: EntityManager[] = [];
      const resolver = new ChatGptUserResolver(repo);
      const realBinding = resolver.withManager.bind(resolver) as (
        manager: EntityManager,
      ) => IUserResolver;
      jest.spyOn(resolver, 'withManager').mockImplementation((manager) => {
        managers.push(manager);
        const bound = realBinding(manager);
        if (phase === 'business') {
          // 原业务真实 PG 写入照常执行，返回前人工暂停 Promise；不是生产 trigger。
          if (kind === 'bind') {
            const original = bound.bindIdentifier.bind(
              bound,
            ) as IUserResolver['bindIdentifier'];
            jest
              .spyOn(bound, 'bindIdentifier')
              .mockImplementation(async (...args) => {
                observations.push({
                  initialAuthorizationPassed: true,
                  kind,
                  phase,
                  at: Date.now(),
                  deadline,
                });
                expect(Date.now()).toBeLessThan(deadline);
                const result = await original(...args);
                await gate.hold();
                return result;
              });
          } else {
            const original = bound.bindPendingThirdPartyIdentifier.bind(
              bound,
            ) as IUserResolver['bindPendingThirdPartyIdentifier'];
            jest
              .spyOn(bound, 'bindPendingThirdPartyIdentifier')
              .mockImplementation(async (...args) => {
                observations.push({
                  initialAuthorizationPassed: true,
                  kind,
                  phase,
                  at: Date.now(),
                  deadline,
                });
                expect(Date.now()).toBeLessThan(deadline);
                const result = await original(...args);
                await gate.hold();
                return result;
              });
          }
        }
        return bound;
      });
      if (phase === 'consume') {
        // 包装实际短 PG transaction 与原 repository.save；在真实 UPDATE 之后、save 返回之前暂停。
        const originalTransaction = db.manager.transaction.bind(db.manager) as (
          action: TxAction,
        ) => Promise<unknown>;
        const transactionSpy = jest.spyOn(
          db.manager,
          'transaction',
        ) as unknown as jest.MockInstance<Promise<unknown>, [TxAction]>;
        transactionSpy.mockImplementation((action) =>
          originalTransaction(async (manager) => {
            const codes = manager.getRepository(VerificationCode);
            const originalSave = codes.save.bind(codes) as (
              record: VerificationCode,
            ) => Promise<VerificationCode>;
            const saveSpy = jest.spyOn(
              codes,
              'save',
            ) as unknown as jest.MockInstance<
              Promise<VerificationCode>,
              [VerificationCode]
            >;
            saveSpy.mockImplementation(async (record) => {
              const result = await originalSave(record);
              if (record.invalidationReason === 'consumed') {
                const live = await manager
                  .getRepository(User)
                  .findOneByOrFail({ id: actor.id });
                expect(live.email).toBe('Proof@example.com');
                expect(live.emailVerifiedAt).not.toBeNull();
                expect(manager.queryRunner?.isTransactionActive).toBe(true);
                observations.push({
                  initialAuthorizationPassed: true,
                  businessWritten: true,
                  actualConsumeUpdateWritten: true,
                  kind,
                  phase,
                  at: Date.now(),
                  deadline,
                });
                expect(Date.now()).toBeLessThan(deadline);
                await gate.hold();
              }
              return result;
            });
            return action(manager);
          }),
        );
      }
      const sign = jest.fn().mockImplementation(() => {
        expect(managers.at(-1)?.queryRunner?.isTransactionActive).toBe(false);
        expect(managers.at(-1)?.queryRunner?.isReleased).toBe(true);
        return 'synthetic-committed-jwt';
      });
      const verification = new VerificationService(
        db.getRepository(VerificationCode),
        policies(),
        {
          send: () => {
            throw Error('real_send_forbidden');
          },
        } as never,
        { now: () => Date.now() },
      );
      const options = {
        userResolver: resolver,
        jwtSigner: { sign },
        appSecretKey: secret,
        accessTokenVerifier: new TokenAuthenticationService(repo),
      } as AuthKitModuleOptions;
      const normal = new AuthController(verification, policies(), options),
        third = new ThirdPartyController(
          verification,
          {} as never,
          {} as never,
          options,
        );
      const common = {
        channel: 'email' as const,
        identifier: 'Proof@example.com',
        code: '123456',
      };
      let operation: Promise<unknown>;
      if (kind === 'bind') {
        const token = jwt.sign(
          { userId: actor.id, tokenVersion: 0, ...(legacy ? {} : { exp }) },
          JWT_SECRET,
          { algorithm: 'HS256' },
        );
        const principal = await new TokenAuthenticationService(repo).verify(
          token,
        );
        expect(principal).not.toBeNull();
        expect(principal?.expiresAt).toBe(legacy ? undefined : deadline);
        operation = normal.bind(common, { user: principal } as never);
      } else {
        const bindTicket = jwt.sign(
          { purpose: 'third_party_bind', provider: kind, exp },
          secret,
          {
            algorithm: 'HS256',
            audience: 'auth-kit:third-party-bind',
            issuer: 'auth-kit',
            subject: String(actor.id),
            jwtid: 'synthetic-short-ticket',
          },
        );
        operation =
          kind === 'huawei'
            ? third.huaweiBindAndLogin({ ...common, bindTicket })
            : third.appleBindAndLogin({ ...common, bindTicket });
      }
      const outcome = operation.then(
        (value) => ({ ok: true as const, value }),
        (error) => ({ ok: false as const, error: error as unknown }),
      );
      let result: Awaited<typeof outcome>;
      try {
        await reached(gate.entered);
        expect(observations).toHaveLength(1);
        expect(now).toBeLessThan(deadline);
        if (expire || legacy) now = deadline + 1;
        expect(now).toBeLessThan(code.expiresAt.getTime());
      } finally {
        gate.release();
        result = await outcome;
      }
      const finalUsers = await users(),
        finalCodes = await rows();
      evidence.push({
        kind,
        phase,
        expire,
        legacy,
        observations,
        finalAt: now,
        deadline,
        codeExpiry: code.expiresAt,
        outcome: result.ok ? 'success' : 'rejected',
        userUnchanged:
          JSON.stringify(finalUsers) === JSON.stringify(beforeUsers),
        codesUnchanged:
          JSON.stringify(finalCodes) === JSON.stringify(beforeCodes),
        jwtCalls: sign.mock.calls.length,
        actualSmtpOAuthModelCalls: 0,
        barrierClassification:
          phase === 'consume'
            ? 'real PG UPDATE then repository.save return barrier'
            : 'real PG business write then resolver return barrier',
      });
      if (expire && !legacy) {
        expect(result.ok).toBe(false);
        if (!result.ok) expect(result.error).toBeInstanceOf(Error);
        expect(finalUsers).toEqual(beforeUsers);
        expect(finalCodes).toEqual(beforeCodes);
        expect(sign).not.toHaveBeenCalled();
      } else {
        expect(result.ok).toBe(true);
        expect(finalUsers[0].email).toBe('Proof@example.com');
        expect(finalUsers[0].emailVerifiedAt).not.toBeNull();
        expect(finalCodes[0].invalidationReason).toBe('consumed');
        expect(sign).toHaveBeenCalledTimes(kind === 'bind' ? 0 : 1);
      }
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
      now = Math.floor(Date.now() / 1000) * 1000 + 999;
      jest.spyOn(Date, 'now').mockImplementation(() => now);
    });
    afterEach(() => {
      jest.restoreAllMocks();
    });
    afterAll(async () => {
      if (process.env.MAIL_PG_EVIDENCE)
        writeFileSync(
          process.env.MAIL_PG_EVIDENCE,
          JSON.stringify(
            {
              classification:
                'real private nonce PG; shared virtual Date.now; injected asynchronous resolver/save return barriers; no production triggers or external SMTP/OAuth/model',
              evidence,
            },
            null,
            2,
          ),
        );
      if (db?.isInitialized) await db.destroy();
    });
    it.each(cases)(
      '%s auth final %s await crosses original exp: all writes rollback/no JWT',
      async (kind, phase) => {
        await exercise(kind, phase, true);
      },
    );
    it.each(cases)(
      '%s auth final %s await still before original exp: commit succeeds',
      async (kind, phase) => {
        await exercise(kind, phase, false);
      },
    );
    it.each(['business', 'consume'] as const)(
      'ordinary legacy no-exp JWT keeps compatibility after %s await',
      async (phase) => {
        await exercise('bind', phase, false, true);
      },
    );
  },
);
