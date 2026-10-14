// 专用 SIGKILL 证据子进程；生产模块不导入，不读取默认 datasource/环境数据库。
import 'reflect-metadata';
import { DataSource } from 'typeorm';
import { readFileSync } from 'node:fs';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import { CloudWorkflowWorker } from './cloud-workflow.worker';
import { CloudWorkflowTransport } from './cloud-workflow.transport';

async function main() {
  const e = process.env;
  if (
    e.CLOUD_C1B_PG_TEST !== '1' ||
    !e.CLOUD_PG_NONCE ||
    !e.CLOUD_PG_SOCKET?.startsWith('/tmp/chatai-cloud-C1b-') ||
    e.CLOUD_PG_DATABASE !== `chatai_cloud_test_${e.CLOUD_PG_NONCE}` ||
    e.CLOUD_PG_USER !== `cloud_${e.CLOUD_PG_NONCE}`
  )
    throw Error('child_private_identity_required');
  const sentinel = JSON.parse(
    readFileSync(`${e.CLOUD_PG_SOCKET}/fixture-sentinel.json`, 'utf8'),
  ) as { nonce: string };
  if (sentinel.nonce !== e.CLOUD_PG_NONCE)
    throw Error('child_sentinel_mismatch');
  const db = new DataSource({
    type: 'postgres',
    host: e.CLOUD_PG_SOCKET,
    port: Number(e.CLOUD_PG_PORT),
    database: e.CLOUD_PG_DATABASE,
    username: e.CLOUD_PG_USER,
    password: '',
    synchronize: false,
    logging: false,
    extra: {
      connectionTimeoutMillis: 3000,
      application_name: 'c1b-sigkill-child',
    },
  });
  await db.initialize();
  const [r] = await db.query<
    Array<{
      database: string;
      directory: string;
      username: string;
      address: string | null;
    }>
  >(
    "SELECT current_database() database,current_setting('data_directory') directory,current_user username,inet_server_addr()::text address",
  );
  if (
    r.database !== e.CLOUD_PG_DATABASE ||
    r.directory !== e.CLOUD_PG_DATA_DIRECTORY ||
    r.username !== e.CLOUD_PG_USER ||
    r.address !== null
  )
    throw Error('child_pg_identity_mismatch');
  process.send?.({ code: 'CHILD_IDENTITY_VERIFIED' });
  await new CloudWorkflowWorker(
    new CloudWorkflowExecutionStore(db),
    new CloudWorkflowTransport(),
  ).runOnce();
  await db.destroy();
  process.disconnect?.();
}
if (require.main === module)
  void main().catch(() => {
    process.send?.({ code: 'CHILD_FAILED' });
    process.exitCode = 1;
    process.disconnect?.();
  });
