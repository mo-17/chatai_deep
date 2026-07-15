import type { DataSource, Migration, QueryRunner } from 'typeorm';
import {
  DEFAULT_MIGRATION_LOCK_TIMEOUT_MS,
  MIGRATION_ADVISORY_LOCK_KEYS,
  resolveMigrationLockTimeout,
  revertLastMigrationWithAdvisoryLock,
  runMigrationsWithAdvisoryLock,
  type PendingMigrationExecutor,
} from './migration-runner';

type Harness = {
  dataSource: DataSource;
  queryRunner: QueryRunner;
  executor: PendingMigrationExecutor;
  events: string[];
};

function harness(
  options: {
    initialized?: boolean;
    lockError?: Error;
    migrationError?: Error;
    rollbackError?: Error;
  } = {},
): Harness {
  const events: string[] = [];
  const dataSource = {
    isInitialized: options.initialized ?? false,
    initialize: jest.fn(function (this: { isInitialized: boolean }) {
      events.push('initialize');
      this.isInitialized = true;
      return Promise.resolve(this);
    }),
    destroy: jest.fn(function (this: { isInitialized: boolean }) {
      events.push('destroy');
      this.isInitialized = false;
      return Promise.resolve();
    }),
  } as unknown as DataSource;

  const queryRunner = {
    isTransactionActive: false,
    connect: jest.fn(() => {
      events.push('connect');
      return Promise.resolve();
    }),
    query: jest.fn((sql: string, parameters?: unknown[]) => {
      if (sql.includes('set_config') && parameters?.[0] !== '0') {
        events.push(`timeout:${String(parameters?.[0])}`);
      } else if (sql.includes('pg_advisory_xact_lock')) {
        events.push(`lock:${JSON.stringify(parameters)}`);
        if (options.lockError) return Promise.reject(options.lockError);
      } else if (sql.includes('set_config')) {
        events.push('timeout:reset');
      }
      return Promise.resolve([]);
    }),
    beforeMigration: jest.fn(() => {
      events.push('before');
      return Promise.resolve();
    }),
    startTransaction: jest.fn(function (this: {
      isTransactionActive: boolean;
    }) {
      events.push('start');
      this.isTransactionActive = true;
      return Promise.resolve();
    }),
    commitTransaction: jest.fn(function (this: {
      isTransactionActive: boolean;
    }) {
      events.push('commit');
      this.isTransactionActive = false;
      return Promise.resolve();
    }),
    rollbackTransaction: jest.fn(function (this: {
      isTransactionActive: boolean;
    }) {
      events.push('rollback');
      if (options.rollbackError) {
        return Promise.reject(options.rollbackError);
      }
      this.isTransactionActive = false;
      return Promise.resolve();
    }),
    afterMigration: jest.fn(() => {
      events.push('after');
      return Promise.resolve();
    }),
    release: jest.fn(() => {
      events.push('release');
      return Promise.resolve();
    }),
  } as unknown as QueryRunner;

  Object.assign(dataSource, {
    createQueryRunner: jest.fn(() => queryRunner),
  });

  const executor: PendingMigrationExecutor = {
    transaction: 'each',
    executePendingMigrations: jest.fn(() => {
      events.push('migrate');
      if (options.migrationError) {
        return Promise.reject(options.migrationError);
      }
      return Promise.resolve([{ name: 'TestMigration' }] as Migration[]);
    }),
  };

  return { dataSource, queryRunner, executor, events };
}

describe('runMigrationsWithAdvisoryLock', () => {
  it('在同一专用连接持有全局锁并以单事务运行 migration', async () => {
    const value = harness();
    const factory = jest.fn(() => value.executor);

    const migrations = await runMigrationsWithAdvisoryLock(
      value.dataSource,
      factory,
    );

    expect(migrations).toHaveLength(1);
    expect(factory).toHaveBeenCalledWith(value.dataSource, value.queryRunner);
    expect(value.executor.transaction).toBe('none');
    expect(value.events).toEqual([
      'initialize',
      'connect',
      'before',
      'start',
      `timeout:${DEFAULT_MIGRATION_LOCK_TIMEOUT_MS}ms`,
      `lock:${JSON.stringify(MIGRATION_ADVISORY_LOCK_KEYS)}`,
      'timeout:reset',
      'migrate',
      'commit',
      'after',
      'release',
      'destroy',
    ]);
  });

  it('migration 失败仍释放锁、连接和自建 DataSource', async () => {
    const original = new Error('migration failed');
    const value = harness({ migrationError: original });

    await expect(
      runMigrationsWithAdvisoryLock(value.dataSource, () => value.executor),
    ).rejects.toBe(original);

    expect(value.events).toEqual([
      'initialize',
      'connect',
      'before',
      'start',
      `timeout:${DEFAULT_MIGRATION_LOCK_TIMEOUT_MS}ms`,
      `lock:${JSON.stringify(MIGRATION_ADVISORY_LOCK_KEYS)}`,
      'timeout:reset',
      'migrate',
      'rollback',
      'release',
      'destroy',
    ]);
  });

  it('调用方已初始化的 DataSource 不由 runner 关闭', async () => {
    const value = harness({ initialized: true });

    await runMigrationsWithAdvisoryLock(value.dataSource, () => value.executor);

    expect(value.events).not.toContain('initialize');
    expect(value.events).not.toContain('destroy');
    expect(value.events[0]).toBe('connect');
    expect(value.events.at(-1)).toBe('release');
  });

  it('rollback 失败时销毁调用方连接池，避免污染连接回池', async () => {
    const original = new Error('migration failed');
    const value = harness({
      initialized: true,
      migrationError: original,
      rollbackError: new Error('rollback failed'),
    });

    await expect(
      runMigrationsWithAdvisoryLock(value.dataSource, () => value.executor),
    ).rejects.toBe(original);

    expect(value.events).toContain('rollback');
    expect(value.events).not.toContain('release');
    expect(value.events.at(-1)).toBe('destroy');
  });

  it('锁等待超时会回滚并保留原始数据库错误', async () => {
    const original = new Error('canceling statement due to statement timeout');
    const value = harness({ lockError: original });

    await expect(
      runMigrationsWithAdvisoryLock(value.dataSource, () => value.executor, {
        lockTimeoutMs: 1234,
      }),
    ).rejects.toBe(original);

    expect(value.events).toEqual([
      'initialize',
      'connect',
      'before',
      'start',
      'timeout:1234ms',
      `lock:${JSON.stringify(MIGRATION_ADVISORY_LOCK_KEYS)}`,
      'rollback',
      'release',
      'destroy',
    ]);
  });
});

describe('revertLastMigrationWithAdvisoryLock', () => {
  it('revert 与 apply 使用相同的 transaction advisory lock', async () => {
    const value = harness();
    const undoLastMigration = jest.fn(() => {
      value.events.push('revert');
      return Promise.resolve();
    });
    const executor = {
      transaction: 'each' as const,
      undoLastMigration,
    };

    await revertLastMigrationWithAdvisoryLock(value.dataSource, () => executor);

    expect(executor.transaction).toBe('none');
    expect(undoLastMigration).toHaveBeenCalledTimes(1);
    expect(value.events).toEqual([
      'initialize',
      'connect',
      'before',
      'start',
      `timeout:${DEFAULT_MIGRATION_LOCK_TIMEOUT_MS}ms`,
      `lock:${JSON.stringify(MIGRATION_ADVISORY_LOCK_KEYS)}`,
      'timeout:reset',
      'revert',
      'commit',
      'after',
      'release',
      'destroy',
    ]);
  });
});

describe('resolveMigrationLockTimeout', () => {
  it('未配置时使用一分钟，显式正整数原样采用', () => {
    expect(resolveMigrationLockTimeout(undefined)).toBe(
      DEFAULT_MIGRATION_LOCK_TIMEOUT_MS,
    );
    expect(resolveMigrationLockTimeout('1250')).toBe(1250);
  });

  it.each(['', '0', '-1', '1.5', 'abc'])('拒绝非法值 %p', (value) => {
    expect(() => resolveMigrationLockTimeout(value)).toThrow(
      'MIGRATION_LOCK_TIMEOUT_MS',
    );
  });
});
