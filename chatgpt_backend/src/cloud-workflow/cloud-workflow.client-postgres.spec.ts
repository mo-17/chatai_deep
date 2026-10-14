import { DataSource } from 'typeorm';
import { readFileSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { NotFoundException, ForbiddenException } from '@nestjs/common';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudSchedulerGate1784060000000 } from '../migrations/1784060000000-AddCloudSchedulerGate';
import { AddCloudDispatchPermit1784050000000 } from '../migrations/1784050000000-AddCloudDispatchPermit';
import { runMigrationsWithAdvisoryLock } from '../database/migration-runner';
import { CloudWorkflowStore } from './cloud-workflow.store';
import {
  canonical,
  hashText,
  parseCloudPayload,
} from './cloud-workflow.contract';
import {
  fixturePayload,
  SyntheticAdmittedStore,
} from './cloud-workflow.fixture';

const pg = process.env.CLOUD_C2_PG_TEST === '1' ? describe : describe.skip;
pg('C2 dedicated PostgreSQL source/receipt/profiles (zero model HTTP)', () => {
  let db: DataSource,
    store: CloudWorkflowStore,
    verified = false;
  const evidence: unknown[] = [];
  const auth = {
    userId: 1,
    securityVersion: 3,
    expiresAt: Date.now() + 600000,
  };
  beforeAll(async () => {
    const {
      CLOUD_PG_SOCKET: socket,
      CLOUD_PG_PORT: port,
      CLOUD_PG_DATA_DIRECTORY: directory,
      CLOUD_PG_NONCE: nonce,
      CLOUD_PG_USER: username,
      CLOUD_PG_DATABASE: database,
    } = process.env;
    if (
      !socket?.startsWith('/tmp/chatai-cloud-C2-') ||
      !directory?.startsWith('/tmp/chatai-cloud-C2-') ||
      !nonce ||
      database !== `chatai_cloud_test_${nonce}` ||
      username !== `cloud_${nonce}` ||
      !port
    )
      throw Error('拒绝非本次隔离PG');
    expect(
      (
        JSON.parse(readFileSync(`${socket}/fixture-sentinel.json`, 'utf8')) as {
          nonce: string;
        }
      ).nonce,
    ).toBe(nonce);
    db = new DataSource({
      type: 'postgres',
      host: socket,
      port: Number(port),
      username,
      database,
      password: '',
      synchronize: false,
      logging: false,
      migrations: [
        CreateCoreBaseline1783990000000,
        CreateSyncV21784000000000,
        AddAppVersionSha2561784020000000,
        AddUserTokenVersion1784030000000,
        CreateCloudWorkflows1784040000000,
        AddCloudDispatchPermit1784050000000,
        AddCloudSchedulerGate1784060000000,
      ],
    });
    await db.initialize();
    const [identity] = await db.query<
      Array<{
        database: string;
        directory: string;
        username: string;
        address: string | null;
      }>
    >(
      "SELECT current_database() AS database,current_setting('data_directory') AS directory,current_user AS username,inet_server_addr()::text AS address",
    );
    expect(identity).toEqual({ database, directory, username, address: null });
    verified = true;
    await db.query('CREATE TABLE fixture_sentinel(nonce text PRIMARY KEY)');
    await db.query('INSERT INTO fixture_sentinel VALUES($1)', [nonce]);
    expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(7);
    expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(0);
    evidence.push({
      code: 'ISOLATED_IDENTITY',
      ...identity,
      nonce,
      migrations: 7,
      noOp: 0,
      modelPosts: 0,
    });
    store = new SyntheticAdmittedStore(db, { epoch: '1' });
  });
  beforeEach(async () => {
    if (!verified) throw Error('身份未核验');
    await db.query('DELETE FROM cloud_workflow_parents');
    await db.query(
      'UPDATE cloud_workflow_scheduler_gate SET epoch=1,accepting=true WHERE id=1',
    );
    await db.query('DELETE FROM ai_models');
    await db.query('DELETE FROM ai_providers');
    await db.query(
      `INSERT INTO users(id,"userName","tokenVersion") VALUES(1,'synthetic-a',3),(2,'synthetic-b',3) ON CONFLICT(id) DO NOTHING`,
    );
    await db.query(
      `INSERT INTO ai_providers(id,code,"displayName","apiKey","baseUrl",enabled) VALUES(1,'a','服务A','DO_NOT_EXPOSE_KEY','http://127.0.0.1:1',true),(2,'b','关闭服务','DO_NOT_EXPOSE_KEY','http://127.0.0.1:1',false)`,
    );
    await db.query(
      `INSERT INTO ai_models(id,"providerId","modelId","displayName",enabled) VALUES(1,1,'active','模型A',true),(2,1,'inactive','关闭模型',false),(3,2,'other','关闭服务模型',true)`,
    );
    await db.query(
      `INSERT INTO ai_global_config(id,"catalogPublic") VALUES(1,true) ON CONFLICT(id) DO UPDATE SET "catalogPublic"=true`,
    );
  });
  afterAll(async () => {
    if (db?.isInitialized) await db.destroy();
    if (process.env.CLOUD_PG_EVIDENCE)
      writeFileSync(
        process.env.CLOUD_PG_EVIDENCE,
        JSON.stringify(
          {
            stage: 'C2 backend pure reads + synthetic direct store create',
            modelPosts: 0,
            evidence,
          },
          null,
          2,
        ),
      );
  });
  const tables = [
    'cloud_workflow_parents',
    'cloud_workflow_steps',
    'cloud_workflow_attempts',
    'cloud_workflow_results',
    'cloud_workflow_events',
    'cloud_workflow_operations',
  ];
  async function snapshot() {
    const all: Record<string, unknown> = {};
    for (const table of tables)
      all[table] = await db.query(`SELECT * FROM ${table} ORDER BY 1`);
    return all;
  }
  it('profile双enabled白名单及catalog关闭，无密钥/端点', async () => {
    expect(await store.profiles()).toEqual([
      {
        providerId: 1,
        modelRowId: 1,
        modelId: 'active',
        providerName: '服务A',
        modelName: '模型A',
      },
    ]);
    const serialized = JSON.stringify(await store.profiles());
    for (const key of [
      'apiKey',
      'baseUrl',
      'DO_NOT_EXPOSE_KEY',
      '127.0.0.1',
      'profile_hash',
    ])
      expect(serialized).not.toContain(key);
    await db.query('UPDATE ai_global_config SET "catalogPublic"=false');
    await expect(store.profiles()).rejects.toBeInstanceOf(ForbiddenException);
  });
  it.each(['draft', 'local_message'] as const)(
    'v2 %s落盘、同key纯读/跨owner404、六表不变',
    async (kind) => {
      const base = fixturePayload();
      const hash = hashText(base.task);
      const source =
        kind === 'draft'
          ? { kind, id: randomUUID(), revision: 7, contentHash: hash }
          : {
              kind,
              cid: 77,
              messageId: randomUUID(),
              revision: 9,
              contentHash: hash,
            };
      const payload = parseCloudPayload({ ...base, version: 2, source });
      const parent = await store.create(auth, payload);
      const before = await snapshot();
      const receipt = await store.byIdempotency(1, payload.idempotencyKey);
      expect(receipt).toEqual({
        id: parent.id,
        ownerId: 1,
        state: 'queued',
        revision: 1,
        payloadHash: hashText(canonical(payload)),
        source,
        publicationId: parent.publication_id,
        finalResultId: null,
      });
      await expect(
        store.byIdempotency(2, payload.idempotencyKey),
      ).rejects.toBeInstanceOf(NotFoundException);
      await expect(store.byIdempotency(1, randomUUID())).rejects.toBeInstanceOf(
        NotFoundException,
      );
      expect(await snapshot()).toEqual(before);
      evidence.push({
        code: 'V2_RECEIPT_PURE_READ',
        kind,
        source,
        receipt,
        tablesUnchanged: true,
        modelPosts: 0,
      });
    },
  );
  it('v1既存hash不重写、tombstone回执也不复活', async () => {
    const p = fixturePayload();
    const parent = await store.create(auth, parseCloudPayload(p));
    expect((await store.byIdempotency(1, p.idempotencyKey)).payloadHash).toBe(
      hashText(canonical(p)),
    );
    await store.control(auth, parent.id, 'delete', {
      operationId: randomUUID(),
      expectedRevision: parent.revision,
    });
    const before = await snapshot();
    const receipt = await store.byIdempotency(1, p.idempotencyKey);
    expect(receipt.state).toBe('deleted');
    expect(receipt.source).toBeNull();
    expect(await snapshot()).toEqual(before);
  });
});
