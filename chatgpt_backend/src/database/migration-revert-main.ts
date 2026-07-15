import dataSource from '../data-source';
import {
  resolveMigrationLockTimeout,
  revertLastMigrationWithAdvisoryLock,
} from './migration-runner';

async function main() {
  await revertLastMigrationWithAdvisoryLock(dataSource, undefined, {
    lockTimeoutMs: resolveMigrationLockTimeout(
      process.env.MIGRATION_LOCK_TIMEOUT_MS,
    ),
  });
  process.stdout.write('Migration revert completed\n');
}

void main().catch((error: unknown) => {
  const detail =
    error instanceof Error ? (error.stack ?? error.message) : error;
  process.stderr.write(`Migration revert failed: ${String(detail)}\n`);
  process.exitCode = 1;
});
