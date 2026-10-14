// C3b actual SIGKILL subprocess; explicit private listener, own nonce PG only.
import 'reflect-metadata';
import { DataSource } from 'typeorm';
import { readFileSync } from 'node:fs';
import type { Repository } from 'typeorm';
import type { User } from '../user/user.entity';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import { CloudWorkflowWorker } from './cloud-workflow.worker';
import { CloudWorkflowTransport } from './cloud-workflow.transport';
import { CloudWorkflowPrivateRuntime } from './cloud-workflow.private-runtime';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import type { CloudFence } from './cloud-workflow.store';
import type { WireRequest } from './cloud-workflow.execution';
class BeforePermitStore extends CloudWorkflowExecutionStore {
  async authorizeSend(f: CloudFence, id: string, wire: WireRequest) {
    // Only synthetic injection BEFORE final authorization; production has no async hook.
    process.send?.({ code: 'RESERVATION_COMMITTED_BEFORE_PERMIT' });
    await new Promise<void>(() => {});
    return super.authorizeSend(f, id, wire);
  }
}
async function main() {
  const e = process.env,
    nonce = e.CLOUD_PG_NONCE;
  if (
    e.CLOUD_C3B_PG_TEST !== '1' ||
    !nonce ||
    !e.CLOUD_PG_SOCKET?.startsWith('/tmp/chatai-cloud-C3b-') ||
    e.CLOUD_PG_DATABASE !== `chatai_cloud_test_${nonce}` ||
    e.CLOUD_PG_USER !== `cloud_${nonce}`
  )
    throw Error('child_private_identity');
  if (
    (
      JSON.parse(
        readFileSync(e.CLOUD_PG_SOCKET + '/fixture-sentinel.json', 'utf8'),
      ) as { nonce: string }
    ).nonce !== nonce
  )
    throw Error('child_sentinel');
  const db = new DataSource({
    type: 'postgres',
    host: e.CLOUD_PG_SOCKET,
    port: Number(e.CLOUD_PG_PORT),
    username: e.CLOUD_PG_USER,
    password: '',
    database: e.CLOUD_PG_DATABASE,
    synchronize: false,
    logging: false,
    extra: {
      connectionTimeoutMillis: 3000,
      application_name: 'c3b-sigkill-child',
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
    throw Error('child_identity_mismatch');
  const Store =
    e.C3B_CHILD_BEFORE_PERMIT === '1'
      ? BeforePermitStore
      : CloudWorkflowExecutionStore;
  const store = new Store(db);
  const runtime = CloudWorkflowPrivateRuntime.synthetic(
    store,
    new CloudWorkflowWorker(store, new CloudWorkflowTransport(), {
      heartbeatMs: 100,
    }),
    new TokenAuthenticationService({} as Repository<User>),
    new CloudWorkflowReadiness(),
  );
  const port = await runtime.listen(0, '127.0.0.1');
  process.send?.({ code: 'CHILD_PRIVATE_READY', port, identity: r });
}
if (require.main === module)
  void main().catch(() => {
    process.send?.({ code: 'CHILD_FAILED' });
    process.exitCode = 1;
    process.disconnect?.();
  });
