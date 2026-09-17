import { resolve } from 'path';
import { DataSource } from 'typeorm';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { buildPostgresOptions } from './postgres-options';
import {
  MIGRATION_ADVISORY_LOCK_KEYS,
  runMigrationsWithAdvisoryLock,
} from './migration-runner';

const describePostgres =
  process.env.BASELINE_PG_INTEGRATION === '1' ? describe : describe.skip;

describePostgres('Core baseline PostgreSQL migration', () => {
  jest.setTimeout(30_000);
  const read = (key: string) => process.env[key];
  const baseOptions = buildPostgresOptions(read, resolve(__dirname, '..'));
  const databasePrefix = `chatai_baseline_${process.pid}`;
  let databaseCounter = 0;
  let admin: DataSource;

  beforeAll(async () => {
    admin = new DataSource(baseOptions);
    await admin.initialize();
  });

  afterAll(async () => {
    if (admin?.isInitialized) await admin.destroy();
  });

  async function withDatabase(
    action: (dataSource: DataSource, database: string) => Promise<void>,
  ): Promise<void> {
    const database = `${databasePrefix}_${++databaseCounter}`;
    await admin.query(`CREATE DATABASE "${database}"`);
    const target = new DataSource({
      ...baseOptions,
      database,
      migrations: [
        CreateCoreBaseline1783990000000,
        CreateSyncV21784000000000,
        AddAppVersionSha2561784020000000,
        AddUserTokenVersion1784030000000,
      ],
    });
    try {
      await target.initialize();
      await action(target, database);
    } finally {
      if (target.isInitialized) await target.destroy();
      await admin.query(
        `SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname=$1 AND pid <> pg_backend_pid()`,
        [database],
      );
      await admin.query(`DROP DATABASE IF EXISTS "${database}"`);
    }
  }

  it('空库完整迁移并重复执行为 no-op', async () => {
    await withDatabase(async (dataSource) => {
      const firstRun = await dataSource.runMigrations();
      const secondRun = await dataSource.runMigrations();
      const tables = await dataSource.query<Array<{ tablename: string }>>(
        `SELECT tablename FROM pg_tables
         WHERE schemaname='public' ORDER BY tablename`,
      );

      expect(firstRun.map((migration) => migration.name)).toEqual([
        'CreateCoreBaseline1783990000000',
        'CreateSyncV21784000000000',
        'AddAppVersionSha2561784020000000',
        'AddUserTokenVersion1784030000000',
      ]);
      expect(secondRun).toHaveLength(0);
      expect(tables.map((row) => row.tablename)).toEqual(
        expect.arrayContaining([
          'users',
          'app_versions',
          'ak_verification_codes',
          'ak_smtp_providers',
          'ak_auth_settings',
          'ak_email_templates',
          'sync_changes',
          'sync_v2_events',
          'sync_v2_heads',
          'sync_v2_receipts',
        ]),
      );
      expect(tables).toHaveLength(19);
    });
  });

  it('两个生产 runner 并发启动时只执行一次 migration 链', async () => {
    await withDatabase(async (left, database) => {
      const right = new DataSource({
        ...baseOptions,
        database,
        migrations: [
          CreateCoreBaseline1783990000000,
          CreateSyncV21784000000000,
          AddAppVersionSha2561784020000000,
          AddUserTokenVersion1784030000000,
        ],
      });
      await right.initialize();

      try {
        const results = await Promise.all([
          runMigrationsWithAdvisoryLock(left),
          runMigrationsWithAdvisoryLock(right),
        ]);

        expect(results.map((rows) => rows.length).sort()).toEqual([0, 4]);
        const ledger = await left.query<Array<{ count: number }>>(
          'SELECT count(*)::int AS count FROM "migrations"',
        );
        expect(ledger[0].count).toBe(4);
      } finally {
        if (right.isInitialized) await right.destroy();
      }
    });
  });

  it('等待 migration lock 超时后回滚，锁释放后可立即重试', async () => {
    await withDatabase(async (blockerSource, database) => {
      const runnerSource = new DataSource({
        ...baseOptions,
        database,
        migrations: [
          CreateCoreBaseline1783990000000,
          CreateSyncV21784000000000,
          AddAppVersionSha2561784020000000,
          AddUserTokenVersion1784030000000,
        ],
      });
      await runnerSource.initialize();
      const blocker = blockerSource.createQueryRunner();
      await blocker.connect();
      await blocker.startTransaction();
      await blocker.query('SELECT pg_advisory_xact_lock($1, $2)', [
        ...MIGRATION_ADVISORY_LOCK_KEYS,
      ]);

      try {
        await expect(
          runMigrationsWithAdvisoryLock(runnerSource, undefined, {
            lockTimeoutMs: 100,
          }),
        ).rejects.toMatchObject({ code: '57014' });

        await blocker.rollbackTransaction();
        const migrations = await runMigrationsWithAdvisoryLock(
          runnerSource,
          undefined,
          { lockTimeoutMs: 1000 },
        );
        expect(migrations).toHaveLength(4);
      } finally {
        if (blocker.isTransactionActive) await blocker.rollbackTransaction();
        await blocker.release();
        if (runnerSource.isInitialized) await runnerSource.destroy();
      }
    });
  });

  it('升级历史 synchronize schema 时保留旧数据并安全补列', async () => {
    await withDatabase(async (dataSource) => {
      await dataSource.query(`CREATE TABLE "users" (
        "id" SERIAL PRIMARY KEY,
        "userName" varchar NOT NULL UNIQUE,
        "password" varchar NOT NULL,
        "avatar" varchar,
        "imoocId" varchar,
        "role" varchar NOT NULL DEFAULT 'user',
        "banned" boolean NOT NULL DEFAULT false
      )`);
      await dataSource.query(`CREATE TABLE "ai_models" (
        "id" SERIAL PRIMARY KEY,
        "providerId" integer NOT NULL,
        "modelId" varchar NOT NULL,
        "displayName" varchar NOT NULL,
        "description" text,
        "enabled" boolean NOT NULL DEFAULT true,
        "isDefault" boolean NOT NULL DEFAULT false,
        "sortOrder" integer NOT NULL DEFAULT 0,
        "inputPrice" numeric(10,6),
        "outputPrice" numeric(10,6),
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now()
      )`);
      await dataSource.query(`CREATE TABLE "app_versions" (
        "id" SERIAL PRIMARY KEY,
        "versionName" varchar NOT NULL,
        "versionCode" integer NOT NULL,
        "url" varchar,
        "description" text,
        "cid" varchar NOT NULL DEFAULT 'all',
        "forceUpdate" boolean NOT NULL DEFAULT false,
        "enabled" boolean NOT NULL DEFAULT true,
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now()
      )`);
      await dataSource.query(`CREATE TABLE "conversations" (
        "id" SERIAL PRIMARY KEY,
        "userId" integer NOT NULL,
        "title" varchar NOT NULL DEFAULT '',
        "model" varchar NOT NULL,
        "createdAt" timestamp NOT NULL DEFAULT now(),
        "updatedAt" timestamp NOT NULL DEFAULT now()
      )`);
      await dataSource.query(`CREATE TABLE "messages" (
        "id" SERIAL PRIMARY KEY,
        "conversationId" integer NOT NULL REFERENCES "conversations"("id") ON DELETE CASCADE,
        "role" varchar(16) NOT NULL,
        "content" text NOT NULL,
        "createdAt" timestamp NOT NULL DEFAULT now()
      )`);
      await dataSource.query(
        `INSERT INTO "users" ("userName", "password")
         VALUES ('legacy-user', 'legacy-hash')`,
      );
      await dataSource.query(
        `INSERT INTO "ai_models" ("providerId", "modelId", "displayName")
         VALUES (1, 'legacy-model', 'Legacy Model')`,
      );
      await dataSource.query(
        `INSERT INTO "app_versions" ("versionName", "versionCode", "cid")
         VALUES ('1.0.4', 8, '321')`,
      );
      await dataSource.query(
        `INSERT INTO "conversations" ("userId", "title", "model")
         VALUES (1, 'legacy-conversation', 'legacy-model')`,
      );
      await dataSource.query(
        `INSERT INTO "messages" ("conversationId", "role", "content")
         VALUES (1, 'user', 'keep-me')`,
      );

      await dataSource.runMigrations();

      const [user] = await dataSource.query<
        Array<{
          userName: string;
          password: string;
          email: string | null;
          tokenVersion: number;
        }>
      >(
        `SELECT "userName", "password", "email", "tokenVersion"
         FROM "users" WHERE "id"=1`,
      );
      const [model] = await dataSource.query<Array<Record<string, unknown>>>(
        `SELECT "modelId", "supportsVision", "supportsTool",
                "supportsReasoning", "supportsPdf"
         FROM "ai_models" WHERE "id"=1`,
      );
      const [version] = await dataSource.query<Array<Record<string, unknown>>>(
        `SELECT "versionName", "versionCode", "cid", "sha256"
         FROM "app_versions" WHERE "id"=1`,
      );
      const [message] = await dataSource.query<Array<{ content: string }>>(
        `SELECT "content" FROM "messages" WHERE "id"=1`,
      );
      const [passwordColumn] = await dataSource.query<
        Array<{ is_nullable: string }>
      >(
        `SELECT is_nullable FROM information_schema.columns
         WHERE table_schema='public' AND table_name='users'
           AND column_name='password'`,
      );

      expect(user).toEqual({
        userName: 'legacy-user',
        password: 'legacy-hash',
        email: null,
        tokenVersion: 0,
      });
      expect(model).toMatchObject({
        modelId: 'legacy-model',
        supportsVision: false,
        supportsTool: false,
        supportsReasoning: false,
        supportsPdf: false,
      });
      expect(version).toMatchObject({
        versionName: '1.0.4',
        versionCode: 8,
        cid: '321',
        sha256: null,
      });
      expect(message.content).toBe('keep-me');
      expect(passwordColumn.is_nullable).toBe('YES');

      await expect(
        dataSource.query(
          `INSERT INTO "users" ("userName", "password")
           VALUES ('passwordless-user', NULL)`,
        ),
      ).resolves.toBeDefined();
    });
  });

  it('已记录较新 migration 的库仍会补跑较旧 baseline', async () => {
    await withDatabase(async (dataSource, database) => {
      await dataSource.query(`CREATE TABLE "users" (
        "id" SERIAL PRIMARY KEY,
        "userName" varchar NOT NULL UNIQUE,
        "password" varchar NOT NULL,
        "avatar" varchar,
        "imoocId" varchar,
        "role" varchar NOT NULL DEFAULT 'user',
        "banned" boolean NOT NULL DEFAULT false
      )`);
      await dataSource.query(`CREATE TABLE "app_versions" (
        "id" SERIAL PRIMARY KEY,
        "versionName" varchar NOT NULL,
        "versionCode" integer NOT NULL,
        "url" varchar,
        "description" text,
        "cid" varchar NOT NULL DEFAULT 'all',
        "forceUpdate" boolean NOT NULL DEFAULT false,
        "enabled" boolean NOT NULL DEFAULT true,
        "createTime" timestamp NOT NULL DEFAULT now(),
        "updateTime" timestamp NOT NULL DEFAULT now()
      )`);
      await dataSource.query(
        `INSERT INTO "users" ("userName", "password")
         VALUES ('out-of-order-user', 'keep-hash')`,
      );
      await dataSource.destroy();

      const newerOnly = new DataSource({
        ...baseOptions,
        database,
        migrations: [
          CreateSyncV21784000000000,
          AddAppVersionSha2561784020000000,
          AddUserTokenVersion1784030000000,
        ],
      });
      await newerOnly.initialize();
      await newerOnly.runMigrations();
      await newerOnly.destroy();

      const full = new DataSource({
        ...baseOptions,
        database,
        migrations: [
          CreateCoreBaseline1783990000000,
          CreateSyncV21784000000000,
          AddAppVersionSha2561784020000000,
          AddUserTokenVersion1784030000000,
        ],
      });
      await full.initialize();
      const pending = await full.runMigrations();
      const [user] = await full.query<
        Array<{ userName: string; password: string }>
      >(`SELECT "userName", "password" FROM "users" WHERE "id"=1`);
      const migrations = await full.query<Array<{ name: string }>>(
        `SELECT "name" FROM "migrations" ORDER BY "timestamp"`,
      );
      await full.destroy();

      expect(pending.map((migration) => migration.name)).toEqual([
        'CreateCoreBaseline1783990000000',
      ]);
      expect(user).toEqual({
        userName: 'out-of-order-user',
        password: 'keep-hash',
      });
      expect(migrations.map((row) => row.name)).toEqual([
        'CreateCoreBaseline1783990000000',
        'CreateSyncV21784000000000',
        'AddAppVersionSha2561784020000000',
        'AddUserTokenVersion1784030000000',
      ]);
    });
  });

  it('旧库重复身份数据会让 baseline 整体回滚而不是改写用户', async () => {
    await withDatabase(async (dataSource) => {
      await dataSource.query(`CREATE TABLE "users" (
        "id" SERIAL PRIMARY KEY,
        "userName" varchar NOT NULL UNIQUE,
        "password" varchar NOT NULL,
        "avatar" varchar,
        "imoocId" varchar,
        "role" varchar NOT NULL DEFAULT 'user',
        "banned" boolean NOT NULL DEFAULT false,
        "email" varchar
      )`);
      await dataSource.query(
        `INSERT INTO "users" ("userName", "password", "email") VALUES
          ('duplicate-a', 'hash-a', 'duplicate@example.com'),
          ('duplicate-b', 'hash-b', 'duplicate@example.com')`,
      );

      await expect(dataSource.runMigrations()).rejects.toThrow();

      const [{ count }] = await dataSource.query<Array<{ count: number }>>(
        'SELECT count(*)::int AS count FROM "users"',
      );
      const [ledger] = await dataSource.query<Array<{ count: number }>>(
        'SELECT count(*)::int AS count FROM "migrations"',
      );
      const [rolledBackTable] = await dataSource.query<
        Array<{ table_name: string | null }>
      >(`SELECT to_regclass('public.banners') AS table_name`);

      expect(count).toBe(2);
      expect(ledger.count).toBe(0);
      expect(rolledBackTable.table_name).toBeNull();
    });
  });
});
