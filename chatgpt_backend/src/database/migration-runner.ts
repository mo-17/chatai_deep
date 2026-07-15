import {
  MigrationExecutor,
  type DataSource,
  type Migration,
  type QueryRunner,
} from 'typeorm';

// 由两个 int32 组成，避免 bigint 在不同 PostgreSQL 客户端中的序列化差异。
// 所有 backend 实例必须使用同一组 key，才能串行化 migration 启动。
export const MIGRATION_ADVISORY_LOCK_KEYS = [1_128_812_884, 2] as const;
export const DEFAULT_MIGRATION_LOCK_TIMEOUT_MS = 60_000;
const MAX_MIGRATION_LOCK_TIMEOUT_MS = 15 * 60_000;

export function resolveMigrationLockTimeout(value: string | undefined): number {
  if (value === undefined) return DEFAULT_MIGRATION_LOCK_TIMEOUT_MS;
  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error('MIGRATION_LOCK_TIMEOUT_MS 必须是正整数毫秒');
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed > MAX_MIGRATION_LOCK_TIMEOUT_MS) {
    throw new Error('MIGRATION_LOCK_TIMEOUT_MS 不能超过 900000 毫秒');
  }
  return parsed;
}

export interface PendingMigrationExecutor {
  transaction: 'all' | 'none' | 'each';
  executePendingMigrations(): Promise<Migration[]>;
}

export interface RevertMigrationExecutor {
  transaction: 'all' | 'none' | 'each';
  undoLastMigration(): Promise<void>;
}

export type PendingMigrationExecutorFactory = (
  dataSource: DataSource,
  queryRunner: QueryRunner,
) => PendingMigrationExecutor;

export type RevertMigrationExecutorFactory = (
  dataSource: DataSource,
  queryRunner: QueryRunner,
) => RevertMigrationExecutor;

export interface MigrationRunnerOptions {
  lockTimeoutMs?: number;
}

const defaultExecutorFactory: PendingMigrationExecutorFactory = (
  dataSource,
  queryRunner,
) => new MigrationExecutor(dataSource, queryRunner);

const defaultRevertExecutorFactory: RevertMigrationExecutorFactory = (
  dataSource,
  queryRunner,
) => new MigrationExecutor(dataSource, queryRunner);

/**
 * 在专用 PostgreSQL transaction 上持有 advisory lock，并用同一连接执行 migration。
 * 这样即使连接池上限为 1，也不会因“锁占一个连接、migration 等另一个连接”而死锁。
 * transaction-level lock 会在 commit、rollback 或连接断开时自动释放。
 */
export async function runMigrationsWithAdvisoryLock(
  dataSource: DataSource,
  createExecutor: PendingMigrationExecutorFactory = defaultExecutorFactory,
  options: MigrationRunnerOptions = {},
): Promise<Migration[]> {
  return runWithMigrationAdvisoryLock(
    dataSource,
    createExecutor,
    (executor) => executor.executePendingMigrations(),
    options,
  );
}

/** 使用与 apply 相同的 transaction advisory lock 回退最后一条 migration。 */
export async function revertLastMigrationWithAdvisoryLock(
  dataSource: DataSource,
  createExecutor: RevertMigrationExecutorFactory = defaultRevertExecutorFactory,
  options: MigrationRunnerOptions = {},
): Promise<void> {
  await runWithMigrationAdvisoryLock(
    dataSource,
    createExecutor,
    (executor) => executor.undoLastMigration(),
    options,
  );
}

async function runWithMigrationAdvisoryLock<
  Executor extends { transaction: 'all' | 'none' | 'each' },
  Result,
>(
  dataSource: DataSource,
  createExecutor: (
    dataSource: DataSource,
    queryRunner: QueryRunner,
  ) => Executor,
  execute: (executor: Executor) => Promise<Result>,
  options: MigrationRunnerOptions,
): Promise<Result> {
  const lockTimeoutMs =
    options.lockTimeoutMs ?? DEFAULT_MIGRATION_LOCK_TIMEOUT_MS;
  if (!Number.isSafeInteger(lockTimeoutMs) || lockTimeoutMs <= 0) {
    throw new Error('migration lock timeout 必须是正整数毫秒');
  }

  const wasInitialized = dataSource.isInitialized;
  let queryRunner: QueryRunner | undefined;
  let connected = false;
  let result: Result | undefined;
  let failure: unknown;
  let hasFailure = false;
  let discardDataSource = false;

  try {
    if (!wasInitialized) await dataSource.initialize();

    queryRunner = dataSource.createQueryRunner();
    await queryRunner.connect();
    connected = true;
    await queryRunner.beforeMigration();
    await queryRunner.startTransaction();

    // 仅限制等待 advisory lock 的语句；拿到锁后清零，避免限制真实 migration 时长。
    await queryRunner.query(
      "SELECT set_config('statement_timeout', $1, true)",
      [`${lockTimeoutMs}ms`],
    );
    await queryRunner.query('SELECT pg_advisory_xact_lock($1, $2)', [
      ...MIGRATION_ADVISORY_LOCK_KEYS,
    ]);
    await queryRunner.query(
      "SELECT set_config('statement_timeout', $1, true)",
      ['0'],
    );

    const executor = createExecutor(dataSource, queryRunner);
    // 外层 transaction 同时覆盖 migration 表创建、业务 DDL 和 ledger 写入。
    executor.transaction = 'none';
    result = await execute(executor);
    await queryRunner.commitTransaction();
    await queryRunner.afterMigration();
  } catch (error) {
    failure = error;
    hasFailure = true;
  }

  if (queryRunner?.isTransactionActive) {
    try {
      await queryRunner.rollbackTransaction();
    } catch (error) {
      // rollback 失败时 transaction 状态不可再信任，不能把连接放回调用方 pool。
      discardDataSource = true;
      if (!hasFailure) {
        failure = error;
        hasFailure = true;
      }
    }
  }

  if (connected && queryRunner && !discardDataSource) {
    try {
      await queryRunner.release();
    } catch (error) {
      discardDataSource = true;
      if (!hasFailure) {
        failure = error;
        hasFailure = true;
      }
    }
  }

  if ((!wasInitialized || discardDataSource) && dataSource.isInitialized) {
    try {
      await dataSource.destroy();
    } catch (error) {
      if (!hasFailure) {
        failure = error;
        hasFailure = true;
      }
    }
  }

  if (hasFailure) throw failure;
  return result as Result;
}
