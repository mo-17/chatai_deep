import { existsSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import { DataSource, type MigrationInterface } from 'typeorm';
import { Conversation } from '../chat/conversation.entity';
import { Message } from '../chat/message.entity';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudDispatchPermit1784050000000 } from '../migrations/1784050000000-AddCloudDispatchPermit';
import { AddCloudSchedulerGate1784060000000 } from '../migrations/1784060000000-AddCloudSchedulerGate';
import { AddVerificationDeliveryState1784070000000 } from '../migrations/1784070000000-AddVerificationDeliveryState';
import { AddMicrosoftSmtpOAuth1784080000000 } from '../migrations/1784080000000-AddMicrosoftSmtpOAuth';
import {
  runMigrationsWithAdvisoryLock,
  revertLastMigrationWithAdvisoryLock,
} from './migration-runner';

const oldNine = [
  CreateCoreBaseline1783990000000,
  CreateSyncV21784000000000,
  AddAppVersionSha2561784020000000,
  AddUserTokenVersion1784030000000,
  CreateCloudWorkflows1784040000000,
  AddCloudDispatchPermit1784050000000,
  AddCloudSchedulerGate1784060000000,
  AddVerificationDeliveryState1784070000000,
  AddMicrosoftSmtpOAuth1784080000000,
];
type MigrationClass = new () => MigrationInterface;
type Identity = {
  database: string;
  user: string;
  data: string;
  listen: string;
};
const describeOwned =
  process.env.R2A_PG_TEST === '1' ? describe : describe.skip;
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
async function outcome(promise: Promise<unknown>) {
  try {
    return { value: await promise };
  } catch (error) {
    const failure: unknown = error;
    return { error: failure };
  }
}

describeOwned(
  'R2a exact private PostgreSQL migration and table-lock protection',
  () => {
    jest.setTimeout(20_000);
    let admin: DataSource;
    let left: DataSource;
    let right: DataSource;
    let target: MigrationClass | undefined;
    let schema: string;
    let caseIndex = 0;
    let fetchSpy: jest.SpyInstance;
    const evidence: {
      identities: Identity[];
      waits: unknown[];
      isolation: unknown[];
      cleanup: unknown[];
      targetPresent?: boolean;
    } = { identities: [], waits: [], isolation: [], cleanup: [] };
    const env = (name: string) => {
      const value = process.env['R2A_PG_' + name];
      if (!value) throw new Error('owned PG fixture configuration absent');
      return value;
    };
    function source(
      selectedSchema = 'public',
      migrations: MigrationClass[] = [],
    ) {
      return new DataSource({
        type: 'postgres',
        host: env('SOCKET'),
        port: Number(env('PORT')),
        username: env('USER'),
        database: env('DATABASE'),
        schema: selectedSchema,
        entities: [Conversation, Message],
        migrations,
        synchronize: false,
        migrationsRun: false,
        logging: false,
        extra: {
          max: 3,
          connectionTimeoutMillis: 2000,
          options: `-c search_path=${selectedSchema} -c statement_timeout=3000 -c lock_timeout=3000`,
        },
      });
    }
    async function identity(ds: DataSource) {
      const [actual] = await ds.query<Identity[]>(
        `SELECT current_database() AS database, current_user AS "user", current_setting('data_directory') AS data, current_setting('listen_addresses') AS listen`,
      );
      expect(actual).toEqual({
        database: env('DATABASE'),
        user: env('USER'),
        data: env('DATA'),
        listen: '',
      });
      evidence.identities.push(actual);
    }
    beforeAll(async () => {
      const nonce = env('NONCE');
      expect(env('SOCKET')).toBe(`/tmp/chatai-r2a-pg-${nonce}/socket`);
      expect(env('DATA')).toBe(`/tmp/chatai-r2a-pg-${nonce}/data`);
      expect(env('DATABASE')).toBe(`r2a_${nonce}`);
      expect(env('USER')).toBe(`r2a_${nonce}`);
      expect(
        JSON.parse(
          readFileSync(resolve(env('SOCKET'), 'fixture-sentinel.json'), 'utf8'),
        ) as { nonce: string },
      ).toEqual({ nonce });
      expect(statSync(env('DATA')).mode & 0o777).toBe(0o700);
      const targetPath = resolve(
        __dirname,
        '../migrations/1784100000000-AddConversationProviderCode.ts',
      );
      if (existsSync(targetPath)) {
        const module = jest.requireActual<{
          AddConversationProviderCode1784100000000: MigrationClass;
        }>(targetPath);
        target = module.AddConversationProviderCode1784100000000;
      }
      evidence.targetPresent = !!target;
      admin = source();
      await admin.initialize();
      await identity(admin);
    });
    beforeEach(async () => {
      fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
        throw new Error('model POST forbidden');
      });
      schema = `r2a_case_${++caseIndex}`;
      await admin.query(`CREATE SCHEMA "${schema}"`);
      const old = source(schema, oldNine);
      try {
        await old.initialize();
        expect(await runMigrationsWithAdvisoryLock(old)).toHaveLength(9);
        await old.query(
          `INSERT INTO conversations ("userId",title,model,"createdAt","updatedAt") VALUES (17,'history','old-model','2020-01-01','2020-02-01')`,
        );
      } finally {
        if (old.isInitialized) await old.destroy();
      }
      left = source(schema, target ? [...oldNine, target] : oldNine);
      right = source(schema);
      await left.initialize();
      await right.initialize();
      await identity(left);
      await identity(right);
    });
    afterEach(async () => {
      if (fetchSpy) expect(fetchSpy).not.toHaveBeenCalled();
      jest.restoreAllMocks();
      if (left?.isInitialized) await left.destroy();
      if (right?.isInitialized) await right.destroy();
      evidence.cleanup.push({
        schema,
        leftDestroyed: !left?.isInitialized,
        rightDestroyed: !right?.isInitialized,
      });
    });
    afterAll(async () => {
      if (admin?.isInitialized) await admin.destroy();
      writeFileSync(env('EVIDENCE'), JSON.stringify(evidence, null, 2) + '\n');
      console.info(
        'R2a own PG identities/lock waits/cleanup',
        JSON.stringify(evidence),
      );
    });
    async function upgrade() {
      // Red 的第九迁移基线没有新源；明确失败，不伪造旧实现或其 down 行为。
      expect(target).toBeDefined();
      expect(
        (await runMigrationsWithAdvisoryLock(left)).map((m) => m.name),
      ).toEqual(['AddConversationProviderCode1784100000000']);
    }
    const ledger = () =>
      left.query<Array<{ name: string }>>(
        'SELECT name FROM migrations ORDER BY id',
      );
    const oldRows = () =>
      left.query<unknown[]>(
        'SELECT id,"userId",title,model,"createdAt","updatedAt" FROM conversations ORDER BY id',
      );
    const column = () =>
      left.query<
        Array<{
          is_nullable: string;
          data_type: string;
          column_default: string | null;
        }>
      >(
        `SELECT is_nullable,data_type,column_default FROM information_schema.columns WHERE table_schema=$1 AND table_name='conversations' AND column_name='providerCode'`,
        [schema],
      );
    async function boundRunner() {
      const runner = left.createQueryRunner();
      await runner.connect();
      const [{ pid }] = (await runner.query(
        'SELECT pg_backend_pid() AS pid',
      )) as Array<{ pid: number }>;
      jest.spyOn(left, 'createQueryRunner').mockReturnValue(runner);
      return { runner, pid };
    }
    async function waitBlocked(pid: number, blocker: number) {
      const end = Date.now() + 2500;
      while (Date.now() < end) {
        const rows = await admin.query<
          Array<{ mode: string; granted: boolean; blockers: number[] }>
        >(
          `SELECT mode,granted,pg_blocking_pids($1) AS blockers FROM pg_locks WHERE pid=$1 AND relation=$2::regclass AND NOT granted`,
          [pid, `${schema}.conversations`],
        );
        if (rows.some((row) => row.blockers.includes(blocker))) {
          evidence.waits.push({ schema, pid, blocker, rows });
          return;
        }
        await new Promise((done) => setTimeout(done, 5));
      }
      throw new Error('actual providerCode table lock wait not observed');
    }
    it('actual old nine ledger and row do not need new entity synchronization', async () => {
      expect(await ledger()).toHaveLength(9);
      expect(await column()).toHaveLength(0);
      expect(await oldRows()).toHaveLength(1);
    });
    it('old9→10 preserves original columns, nullable NULL and timestamp; second run no-op', async () => {
      const before = await oldRows();
      await upgrade();
      expect(await oldRows()).toEqual(before);
      expect(
        await left.query('SELECT "providerCode" FROM conversations'),
      ).toEqual([{ providerCode: null }]);
      expect(await column()).toEqual([
        {
          is_nullable: 'YES',
          data_type: 'character varying',
          column_default: null,
        },
      ]);
      expect(await ledger()).toHaveLength(10);
      expect(await runMigrationsWithAdvisoryLock(left)).toHaveLength(0);
    });
    it('real entity metadata and repository preserve alpha/beta same model after pool reopen', async () => {
      await upgrade();
      const repo = left.getRepository(Conversation);
      for (const providerCode of ['alpha', 'beta'])
        await repo.save(
          repo.create(
            Object.assign(new Conversation(), {
              userId: 17,
              title: 'same-title',
              model: 'same',
              providerCode,
            }),
          ),
        );
      await left.destroy();
      left = source(schema, [...oldNine, target!]);
      await left.initialize();
      expect(
        await left.getRepository(Conversation).find({
          where: { model: 'same' },
          select: ['model', 'providerCode'] as (keyof Conversation)[],
          order: { id: 'ASC' },
        }),
      ).toEqual([
        { model: 'same', providerCode: 'alpha' },
        { model: 'same', providerCode: 'beta' },
      ]);
      const meta = left
        .getMetadata(Conversation)
        .findColumnWithPropertyName('providerCode');
      expect(meta?.isNullable).toBe(true);
      expect(meta?.type).toBe('varchar');
    });
    it('legacy NULL-only down and re-up keep old row and ledger consistent', async () => {
      const before = await oldRows();
      await upgrade();
      await revertLastMigrationWithAdvisoryLock(left);
      expect(await column()).toHaveLength(0);
      expect(await ledger()).toHaveLength(9);
      expect(await oldRows()).toEqual(before);
      await upgrade();
      expect(await oldRows()).toEqual(before);
    });
    it('non-NULL pair rejects down without column, ledger or record changes', async () => {
      await upgrade();
      await left.query(`UPDATE conversations SET "providerCode"='alpha'`);
      const before: unknown = await left.query('SELECT * FROM conversations');
      await expect(revertLastMigrationWithAdvisoryLock(left)).rejects.toThrow(
        '回退已拒绝',
      );
      expect(await column()).toHaveLength(1);
      expect(await ledger()).toHaveLength(10);
      expect(await left.query('SELECT * FROM conversations')).toEqual(before);
    });
    it('down fails closed outside active transaction', async () => {
      await upgrade();
      const runner = left.createQueryRunner();
      await runner.connect();
      try {
        await expect(new target!().down(runner)).rejects.toThrow(
          'READ COMMITTED',
        );
      } finally {
        await runner.release();
      }
      expect(await column()).toHaveLength(1);
      expect(await ledger()).toHaveLength(10);
    });
    it('down rejects RR even with active transaction, before any table DROP', async () => {
      await upgrade();
      const runner = left.createQueryRunner();
      await runner.connect();
      await runner.startTransaction('REPEATABLE READ');
      try {
        await expect(new target!().down(runner)).rejects.toThrow(
          'READ COMMITTED',
        );
      } finally {
        await runner.rollbackTransaction();
        await runner.release();
      }
      expect(await column()).toHaveLength(1);
      expect(await ledger()).toHaveLength(10);
    });
    it('pair writer holding row-exclusive lock commits before down locks; down sees pair and refuses', async () => {
      await upgrade();
      const writer = right.createQueryRunner();
      await writer.connect();
      await writer.startTransaction();
      const [{ pid: writerPid }] = (await writer.query(
        'SELECT pg_backend_pid() AS pid',
      )) as Array<{ pid: number }>;
      await writer.query(`UPDATE conversations SET "providerCode"='alpha'`);
      const { runner, pid } = await boundRunner();
      const query = runner.query.bind(runner) as (
        sql: string,
        parameters?: unknown[],
        structured?: boolean,
      ) => Promise<unknown>;
      const spy = jest
        .spyOn(runner, 'query')
        .mockImplementation(
          async (sql: string, parameters?: unknown[], structured?: boolean) => {
            const result: unknown = await query(sql, parameters, structured);
            if (sql === 'SHOW transaction_isolation')
              evidence.isolation.push({
                schema,
                active: runner.isTransactionActive,
                result,
              });
            return result;
          },
        );
      const reverting = outcome(revertLastMigrationWithAdvisoryLock(left));
      try {
        await waitBlocked(pid, writerPid);
        await writer.commitTransaction();
        const reverted = await reverting;
        expect((reverted as { error: Error }).error.message).toContain(
          '回退已拒绝',
        );
        jest.restoreAllMocks();
        expect(await column()).toHaveLength(1);
        expect(await ledger()).toHaveLength(10);
        expect(
          await left.query('SELECT "providerCode" FROM conversations'),
        ).toEqual([{ providerCode: 'alpha' }]);
      } finally {
        if (writer.isTransactionActive) await writer.rollbackTransaction();
        await writer.release();
        await reverting;
        spy.mockRestore();
      }
    });
    it('down holds ACCESS EXCLUSIVE after NULL check through ledger commit; later pair write cannot cross', async () => {
      await upgrade();
      const { runner, pid } = await boundRunner();
      const checked = deferred();
      const resume = deferred();
      const query = runner.query.bind(runner) as (
        sql: string,
        parameters?: unknown[],
        structured?: boolean,
      ) => Promise<unknown>;
      jest
        .spyOn(runner, 'query')
        .mockImplementation(
          async (sql: string, parameters?: unknown[], structured?: boolean) => {
            const result: unknown = await query(sql, parameters, structured);
            if (sql === 'SHOW transaction_isolation')
              evidence.isolation.push({
                schema,
                active: runner.isTransactionActive,
                result,
              });
            if (sql.includes('WHERE "providerCode" IS NOT NULL')) {
              checked.resolve();
              await resume.promise;
            }
            return result;
          },
        );
      const reverting = outcome(revertLastMigrationWithAdvisoryLock(left));
      const writer = right.createQueryRunner();
      await writer.connect();
      await writer.startTransaction();
      const [{ pid: writerPid }] = (await writer.query(
        'SELECT pg_backend_pid() AS pid',
      )) as Array<{ pid: number }>;
      let writing: ReturnType<typeof outcome> | undefined;
      try {
        await checked.promise;
        writing = outcome(
          writer.query(`UPDATE conversations SET "providerCode"='beta'`),
        );
        await waitBlocked(writerPid, pid);
        resume.resolve();
        expect(await reverting).toEqual({ value: undefined });
        const written = await writing;
        expect((written as { error: { code: string } }).error.code).toBe(
          '42703',
        );
        jest.restoreAllMocks();
        expect(await column()).toHaveLength(0);
        expect(await ledger()).toHaveLength(9);
      } finally {
        resume.resolve();
        await reverting;
        if (writing) await writing;
        if (writer.isTransactionActive) await writer.rollbackTransaction();
        await writer.release();
      }
    });
    it('injected failure before up COMMIT rolls back column and migration ledger', async () => {
      expect(target).toBeDefined();
      const before = await oldRows();
      const { runner } = await boundRunner();
      jest
        .spyOn(runner, 'commitTransaction')
        .mockRejectedValue(new Error('synthetic-before-COMMIT'));
      await expect(runMigrationsWithAdvisoryLock(left)).rejects.toThrow(
        'synthetic-before-COMMIT',
      );
      jest.restoreAllMocks();
      expect(await column()).toHaveLength(0);
      expect(await ledger()).toHaveLength(9);
      expect(await oldRows()).toEqual(before);
    });
    it('injected failure before down COMMIT restores column and ledger; lock is released', async () => {
      await upgrade();
      const before = await oldRows();
      const { runner } = await boundRunner();
      jest
        .spyOn(runner, 'commitTransaction')
        .mockRejectedValue(new Error('synthetic-before-COMMIT'));
      await expect(revertLastMigrationWithAdvisoryLock(left)).rejects.toThrow(
        'synthetic-before-COMMIT',
      );
      jest.restoreAllMocks();
      expect(await column()).toHaveLength(1);
      expect(await ledger()).toHaveLength(10);
      expect(await oldRows()).toEqual(before);
      await right.query(
        `UPDATE conversations SET "providerCode"='after-rollback'`,
      );
      expect(
        await left.query('SELECT "providerCode" FROM conversations'),
      ).toEqual([{ providerCode: 'after-rollback' }]);
    });
    it('already-existing conflicting column is not silently stamped into ledger', async () => {
      expect(target).toBeDefined();
      await left.query(
        'ALTER TABLE conversations ADD COLUMN "providerCode" integer',
      );
      await expect(runMigrationsWithAdvisoryLock(left)).rejects.toMatchObject({
        code: '42701',
      });
      expect(await ledger()).toHaveLength(9);
      expect((await column())[0].data_type).toBe('integer');
    });
  },
);
