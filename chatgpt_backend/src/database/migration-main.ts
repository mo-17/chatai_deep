import dataSource from '../data-source';
import {
  resolveMigrationLockTimeout,
  runMigrationsWithAdvisoryLock,
} from './migration-runner';

async function main() {
  const migrations = await runMigrationsWithAdvisoryLock(
    dataSource,
    undefined,
    {
      lockTimeoutMs: resolveMigrationLockTimeout(
        process.env.MIGRATION_LOCK_TIMEOUT_MS,
      ),
    },
  );
  process.stdout.write(
    migrations.length === 0
      ? 'No migrations are pending\n'
      : `Applied ${migrations.length} migration(s)\n`,
  );
}

void main().catch((error: unknown) => {
  const detail =
    error instanceof Error ? (error.stack ?? error.message) : error;
  process.stderr.write(`Migration failed: ${String(detail)}\n`);
  process.exitCode = 1;
});
