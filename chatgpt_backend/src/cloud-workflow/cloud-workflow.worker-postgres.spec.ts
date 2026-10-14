import { DataSource } from 'typeorm';
import { Test } from '@nestjs/testing';
import { createServer, type Server, type ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fork } from 'node:child_process';
import { resolve } from 'node:path';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudSchedulerGate1784060000000 } from '../migrations/1784060000000-AddCloudSchedulerGate';
import { AddCloudDispatchPermit1784050000000 } from '../migrations/1784050000000-AddCloudDispatchPermit';
import {
  runMigrationsWithAdvisoryLock,
  revertLastMigrationWithAdvisoryLock,
} from '../database/migration-runner';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import {
  CloudWorkflowWorker,
  CLOUD_WORKER_OPTIONS,
} from './cloud-workflow.worker';
import { CloudWorkflowTransport } from './cloud-workflow.transport';
import { CloudWorkflowStore, type CloudFence } from './cloud-workflow.store';
import {
  buildWire,
  type KnownOutput,
  type WireRequest,
  type SendPermit,
} from './cloud-workflow.execution';
import {
  fixturePayload,
  SyntheticAdmittedStore,
} from './cloud-workflow.fixture';
import { hashText, type CloudAuthorization } from './cloud-workflow.contract';

function gate<T = void>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
async function until(test: () => boolean | Promise<boolean>, timeout = 6000) {
  const end = Date.now() + timeout;
  while (!(await test())) {
    if (Date.now() >= end) throw Error('bounded_fixture_wait');
    await new Promise((r) => setTimeout(r, 10));
  }
}
type WireBody = {
  model: string;
  max_tokens: number;
  stream: boolean;
  messages: Array<{ role: string; content: string }>;
};
type Post = {
  body: WireBody;
  digest: string;
  role: string;
  disconnected: boolean;
};
const pg = process.env.CLOUD_C1B_PG_TEST === '1' ? describe : describe.skip;
pg('cloud explicit worker real isolated PG and synthetic HTTP', () => {
  jest.setTimeout(20000);
  let db: DataSource,
    store: CloudWorkflowExecutionStore,
    control: CloudWorkflowStore;
  let server: Server, endpoint: string;
  let posts: Post[] = [],
    workers: CloudWorkflowWorker[] = [];
  let executionStores: CloudWorkflowExecutionStore[] = [];
  let respond: (post: Post, res: ServerResponse) => void;
  const evidence: Record<string, unknown>[] = [];
  const auth = (): CloudAuthorization => ({
    userId: 1,
    securityVersion: 3,
    expiresAt: Date.now() + 600000,
  });
  const success = (post: Post, res: ServerResponse) => {
    res.setHeader('Content-Type', 'application/json');
    res.end(
      JSON.stringify({
        choices: [
          {
            message: {
              role: 'assistant',
              content:
                post.role === 'review'
                  ? '{"passed":true,"feedback":""}'
                  : post.role === 'writing'
                    ? '# 合成最终成果'
                    : '合成分析',
            },
            finish_reason: 'stop',
          },
        ],
        usage: { prompt_tokens: 11, completion_tokens: 7 },
      }),
    );
  };
  const makeWorker = (
    s: CloudWorkflowExecutionStore = store,
    heartbeatMs = 100,
  ) => {
    const worker = new CloudWorkflowWorker(s, new CloudWorkflowTransport(), {
      heartbeatMs,
      saveDelayMs: 30,
    });
    workers.push(worker);
    executionStores.push(s);
    return worker;
  };
  const create = async (
    change?: (p: ReturnType<typeof fixturePayload>) => void,
  ) => {
    const p = fixturePayload();
    p.profiles.writing.modelRowId = 2;
    p.profiles.review.modelRowId = 3;
    change?.(p);
    return control.create(auth(), p);
  };
  async function parent(id: string) {
    return (await control.detail(1, id)).parent;
  }
  async function attempts(id: string) {
    return db.query<
      Array<{
        state: string;
        send_authorized_at: Date | null;
        request_digest: string;
        input_tokens: number | null;
      }>
    >(
      'SELECT * FROM cloud_workflow_attempts WHERE parent_id=$1 ORDER BY number',
      [id],
    );
  }
  const sqlCounts = async (id: string) => {
    const [row] = await db.query<
      Array<{ results: number; attempts: number; events: number }>
    >(
      'SELECT (SELECT count(*)::int FROM cloud_workflow_results WHERE parent_id=$1) results,(SELECT count(*)::int FROM cloud_workflow_attempts WHERE parent_id=$1) attempts,(SELECT count(*)::int FROM cloud_workflow_events WHERE parent_id=$1) events',
      [id],
    );
    return row;
  };
  beforeAll(async () => {
    const e = process.env;
    if (
      !e.CLOUD_PG_NONCE ||
      !e.CLOUD_PG_SOCKET?.startsWith('/tmp/chatai-cloud-C1b-') ||
      !e.CLOUD_PG_DATA_DIRECTORY?.startsWith('/tmp/chatai-cloud-C1b-') ||
      e.CLOUD_PG_DATABASE !== `chatai_cloud_test_${e.CLOUD_PG_NONCE}` ||
      e.CLOUD_PG_USER !== `cloud_${e.CLOUD_PG_NONCE}`
    )
      throw Error('refuse_non_private_pg');
    const sentinel = JSON.parse(
      readFileSync(`${e.CLOUD_PG_SOCKET}/fixture-sentinel.json`, 'utf8'),
    ) as { nonce: string };
    expect(sentinel.nonce).toBe(e.CLOUD_PG_NONCE);
    db = new DataSource({
      type: 'postgres',
      host: e.CLOUD_PG_SOCKET,
      port: Number(e.CLOUD_PG_PORT),
      username: e.CLOUD_PG_USER,
      database: e.CLOUD_PG_DATABASE,
      password: '',
      synchronize: false,
      logging: false,
      extra: {
        max: 10,
        connectionTimeoutMillis: 3000,
        application_name: 'c1b-parent-fixture',
      },
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
      "SELECT current_database() database,current_setting('data_directory') directory,current_user username,inet_server_addr()::text address",
    );
    expect(identity).toEqual({
      database: e.CLOUD_PG_DATABASE,
      directory: e.CLOUD_PG_DATA_DIRECTORY,
      username: e.CLOUD_PG_USER,
      address: null,
    });
    evidence.push({
      code: 'PRIVATE_PG_IDENTITY',
      ...identity,
      nonce: e.CLOUD_PG_NONCE,
    });
    await db.query('CREATE TABLE fixture_sentinel(nonce text PRIMARY KEY)');
    await db.query('INSERT INTO fixture_sentinel VALUES($1)', [
      e.CLOUD_PG_NONCE,
    ]);
    expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(7);
    expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(0);
    await revertLastMigrationWithAdvisoryLock(db);
    expect(
      (
        await db.query<Array<{ exists: boolean }>>(
          "SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='cloud_workflow_scheduler_gate' AND column_name='epoch') exists",
        )
      )[0].exists,
    ).toBe(false);
    expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(1);
    evidence.push({
      code: 'SEVEN_SHARED_MIGRATIONS',
      apply: 7,
      noop: 0,
      downUp: 1,
      productionCli: false,
    });
    store = new CloudWorkflowExecutionStore(db);
    control = new SyntheticAdmittedStore(db, { epoch: '1' });
  });
  beforeEach(async () => {
    store = new CloudWorkflowExecutionStore(db);
    executionStores.push(store);
    expect(
      (
        await db.query<Array<{ nonce: string }>>(
          'SELECT nonce FROM fixture_sentinel',
        )
      )[0].nonce,
    ).toBe(process.env.CLOUD_PG_NONCE);
    await db.query('DELETE FROM cloud_workflow_parents');
    await db.query(
      'UPDATE cloud_workflow_scheduler_gate SET epoch=1,accepting=true WHERE id=1',
    );
    await db.query('DELETE FROM users WHERE id IN (1,2)');
    await db.query(
      'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL',
    );
    await db.query(
      `INSERT INTO users(id,"userName","tokenVersion") VALUES(1,'c1b-synthetic',3),(2,'c1b-other',3)`,
    );
    posts = [];
    workers = [];
    respond = success;
    server = createServer((req, res) => {
      if (req.method !== 'POST') {
        res.statusCode = 404;
        res.end();
        return;
      }
      let body = '';
      req.setEncoding('utf8');
      req.on('data', (data: string) => {
        body += data;
      });
      req.on('end', () => {
        const parsed = JSON.parse(body) as WireBody;
        const role = /承担 (analysis|writing|review)/.exec(
          parsed.messages[0].content,
        )![1];
        const post: Post = {
          body: parsed,
          digest: hashText(body),
          role,
          disconnected: false,
        };
        posts.push(post);
        res.on('close', () => {
          if (!res.writableFinished) post.disconnected = true;
        });
        respond(post, res);
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    const address = server.address();
    if (!address || typeof address === 'string')
      throw Error('loopback_fixture');
    endpoint = `http://127.0.0.1:${address.port}`;
    await db.query(
      `INSERT INTO ai_providers(id,code,"displayName","apiKey","baseUrl") VALUES(1,'c1b-fixture','synthetic','synthetic-key',$1)
      ON CONFLICT(id) DO UPDATE SET enabled=true,"apiKey"='synthetic-key',"baseUrl"=$1`,
      [endpoint],
    );
    for (let id = 1; id <= 3; id++)
      await db.query(
        `INSERT INTO ai_models(id,"providerId","modelId","displayName") VALUES($1,1,$2,'synthetic') ON CONFLICT(id) DO UPDATE SET enabled=true,"modelId"=$2`,
        [id, `fixed-${id}`],
      );
  });
  afterEach(async () => {
    for (const w of workers) await w.shutdown();
    for (const s of new Set(executionStores)) await s.close();
    executionStores = [];
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
    await db.query(
      'DROP TRIGGER IF EXISTS c1b_block_result ON cloud_workflow_results',
    );
    await db.query('DROP FUNCTION IF EXISTS c1b_block_result_fn()');
    evidence.push({
      code: 'CASE_HTTP',
      test: expect.getState().currentTestName,
      posts: posts.map((p) => ({ ...p, body: p.body })),
      count: posts.length,
    });
  });
  afterAll(async () => {
    if (process.env.CLOUD_PG_EVIDENCE)
      writeFileSync(
        process.env.CLOUD_PG_EVIDENCE,
        JSON.stringify(evidence, null, 2),
      );
    if (db?.isInitialized) await db.destroy();
  });

  class PoolProbe extends CloudWorkflowExecutionStore {
    get pool() {
      return this.db;
    }
    touch() {
      return this.locked((tx) =>
        tx.query<Array<{ ok: number }>>('SELECT 1 AS ok'),
      );
    }
  }
  it('pool: concurrent first calls await complete initialization once', async () => {
    const probe = new PoolProbe(db);
    executionStores.push(probe);
    const arrived = gate(),
      release = gate();
    const initialize = probe.pool.initialize.bind(
      probe.pool,
    ) as () => Promise<DataSource>;
    const spy = jest
      .spyOn(probe.pool, 'initialize')
      .mockImplementation(async () => {
        const ready = await initialize();
        arrived.resolve();
        await release.promise;
        return ready;
      });
    let resolved = 0;
    const first = probe.touch().then(() => {
      resolved++;
    });
    await arrived.promise;
    expect(probe.pool.isInitialized).toBe(true);
    const second = probe.touch().then(() => {
      resolved++;
    });
    await new Promise((r) => setTimeout(r, 20));
    expect(resolved).toBe(0);
    expect(spy).toHaveBeenCalledTimes(1);
    release.resolve();
    await Promise.all([first, second]);
    expect(resolved).toBe(2);
  });
  it('pool: initialization failure permits retry only before permanent close', async () => {
    const probe = new PoolProbe(db);
    executionStores.push(probe);
    const original = probe.pool.initialize.bind(
      probe.pool,
    ) as () => Promise<DataSource>;
    const spy = jest
      .spyOn(probe.pool, 'initialize')
      .mockRejectedValueOnce(Error('synthetic_init_failure'))
      .mockImplementation(original);
    await expect(probe.touch()).rejects.toThrow('synthetic_init_failure');
    expect(await probe.touch()).toEqual([{ ok: 1 }]);
    await probe.close();
    await probe.close();
    await expect(probe.touch()).rejects.toThrow('cloud_store_closed');
    expect(spy).toHaveBeenCalledTimes(2);
    expect(probe.pool.isInitialized).toBe(false);
  });
  it('pool: close-during-initialization destroys late pool; run after close never reopens', async () => {
    const probe = new PoolProbe(db);
    executionStores.push(probe);
    const arrived = gate(),
      release = gate();
    const initialize = probe.pool.initialize.bind(
      probe.pool,
    ) as () => Promise<DataSource>;
    const spy = jest
      .spyOn(probe.pool, 'initialize')
      .mockImplementation(async () => {
        const result = await initialize();
        arrived.resolve();
        await release.promise;
        return result;
      });
    const action = probe.touch();
    const settled = Promise.allSettled([action]);
    await arrived.promise;
    const closing = probe.close();
    expect(probe.close()).toBe(closing);
    release.resolve();
    await closing;
    expect((await settled)[0].status).toBe('rejected');
    expect(probe.pool.isInitialized).toBe(false);
    expect(await makeWorker(probe).runOnce()).toBe(false);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(posts).toHaveLength(0);
  });
  it('pool: source lifecycle/schema/plugins/logging settings are not inherited', async () => {
    const unsafeSource = new DataSource({
      ...db.options,
      dropSchema: true,
      synchronize: true,
      migrationsRun: true,
      cache: true,
      logging: true,
    });
    const probe = new PoolProbe(unsafeSource);
    executionStores.push(probe);
    expect(probe.pool.options).toMatchObject({
      dropSchema: false,
      synchronize: false,
      migrationsRun: false,
      cache: false,
      logging: false,
      entities: [],
      migrations: [],
      subscribers: [],
      installExtensions: false,
    });
    expect(await probe.touch()).toEqual([{ ok: 1 }]);
    expect(
      (
        await db.query<Array<{ nonce: string }>>(
          'SELECT nonce FROM fixture_sentinel',
        )
      )[0].nonce,
    ).toBe(process.env.CLOUD_PG_NONCE);
  });
  it.each(['fetch', 'heartbeat_lock'])(
    'Nest real module close: worker drains %s before permanent pool close',
    async (phase) => {
      const order: string[] = [];
      class NestStore extends CloudWorkflowExecutionStore {
        onApplicationShutdown() {
          order.push('pool_close');
          return super.onApplicationShutdown();
        }
        get pool() {
          return this.db;
        }
      }
      class NestWorker extends CloudWorkflowWorker {
        async beforeApplicationShutdown() {
          order.push('worker_stop');
          await super.beforeApplicationShutdown();
          order.push('worker_drain');
        }
      }
      const s = new NestStore(db),
        worker = new NestWorker(s, new CloudWorkflowTransport(), {
          heartbeatMs: 25,
        });
      executionStores.push(s);
      workers.push(worker);
      const module = await Test.createTestingModule({
        providers: [
          { provide: CloudWorkflowExecutionStore, useValue: s },
          { provide: CloudWorkflowWorker, useValue: worker },
          CloudWorkflowTransport,
          { provide: CLOUD_WORKER_OPTIONS, useValue: { heartbeatMs: 25 } },
        ],
      }).compile();
      const app = module.createNestApplication();
      await app.init();
      let closed = false;
      respond = () => {};
      const p = await create();
      const running = worker.runOnce();
      await until(() => posts.length === 1);
      const blocker = db.createQueryRunner();
      await blocker.connect();
      try {
        if (phase === 'heartbeat_lock') {
          await blocker.startTransaction();
          await blocker.query('SELECT pg_advisory_xact_lock(178404,1)');
          await until(
            async () =>
              (
                await db.query<Array<{ count: number }>>(
                  "SELECT count(*)::int count FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%178404%'",
                )
              )[0].count > 0,
          );
        }
        await app.close();
        closed = true;
        await running;
        expect(order).toEqual(['worker_stop', 'worker_drain', 'pool_close']);
        expect(s.pool.isInitialized).toBe(false);
        expect(await worker.runOnce()).toBe(false);
        expect(posts).toHaveLength(1);
        await expect(s.claim(randomUUID())).rejects.toThrow(
          'cloud_store_closed',
        );
        if (blocker.isTransactionActive) {
          await blocker.rollbackTransaction();
          await db.query(
            "UPDATE cloud_workflow_slot SET expires_at=now()-interval '1 second'",
          );
          await makeWorker().runOnce();
        }
        expect((await attempts(p.id))[0].state).toBe('unknown');
        evidence.push({
          code: 'REAL_NEST_CLOSE_ORDER',
          phase,
          order: [...order],
          poolClosed: !s.pool.isInitialized,
        });
      } finally {
        if (blocker.isTransactionActive) await blocker.rollbackTransaction();
        await blocker.release();
        if (!closed) await app.close();
      }
    },
  );

  it('review fix: successful continue receipt survives subsequent exhausted rework; retries never execute', async () => {
    let reviews = 0;
    respond = (post, res) => {
      if (post.role !== 'review') return success(post, res);
      if (++reviews === 1) {
        res.statusCode = 500;
        res.end('synthetic_known_failure');
      } else
        res.end(
          JSON.stringify({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: '{"passed":false,"feedback":"negative"}',
                },
                finish_reason: 'stop',
              },
            ],
          }),
        );
    };
    const p = await create((v) => {
      v.budget.reworks = 0;
    });
    await makeWorker().runOnce();
    expect(posts).toHaveLength(3);
    const paused = await parent(p.id);
    expect(paused.state).toBe('paused');
    expect((await attempts(p.id))[2].state).toBe('failed');
    const op = { operationId: randomUUID(), expectedRevision: paused.revision };
    const receipt = await control.control(auth(), p.id, 'continue', op, 600000);
    await makeWorker().runOnce();
    expect(posts).toHaveLength(4);
    const exhausted = await parent(p.id);
    expect(exhausted.reason).toBe('rework_limit_reached');
    async function snapshot() {
      const result: Record<string, unknown> = {};
      for (const table of [
        'parents',
        'steps',
        'attempts',
        'results',
        'events',
        'operations',
      ])
        result[table] = await db.query(
          `SELECT row_to_json(r) AS row FROM cloud_workflow_${table} r WHERE ${table === 'parents' ? 'id' : 'parent_id'}=$1 ORDER BY ${table === 'parents' ? 'id' : table === 'operations' ? 'operation_id' : table === 'events' ? 'sequence' : 'id'}`,
          [p.id],
        );
      return result;
    }
    const before = await snapshot();
    expect(await control.control(auth(), p.id, 'continue', op, 600000)).toEqual(
      receipt,
    );
    expect(await snapshot()).toEqual(before);
    await expect(
      control.control(
        auth(),
        p.id,
        'continue',
        { operationId: randomUUID(), expectedRevision: exhausted.revision },
        600000,
      ),
    ).rejects.toThrow();
    await expect(
      control.control(auth(), p.id, 'continue', op, 599999),
    ).rejects.toThrow();
    expect(await snapshot()).toEqual(before);
    expect(posts).toHaveLength(4);
    evidence.push({
      code: 'CONTINUE_RECEIPT_AFTER_REWORK_LIMIT',
      receipt,
      exactRowsPreserved: true,
      posts: 4,
    });
  });
  it('review fix: artificially shorter slot expires during step lock; result and usage commit rejected', async () => {
    const p = await create(),
      f = (await store.claim(randomUUID()))!;
    const plan = await store.readPlan(f),
      wire = buildWire(plan, plan.steps[0]);
    const id = await store.reserveExecution(f, wire);
    await store.authorizeSend(f, id, wire);
    const expiry = Date.now() + 350;
    await db.query('UPDATE cloud_workflow_slot SET expires_at=$1', [
      new Date(expiry),
    ]);
    const before = await sqlCounts(p.id);
    const beforeAttempt = await attempts(p.id);
    const blocker = db.createQueryRunner();
    await blocker.connect();
    await blocker.startTransaction();
    await blocker.query(
      'SELECT id FROM cloud_workflow_steps WHERE id=$1 FOR UPDATE',
      [plan.steps[0].id],
    );
    const settled = Promise.allSettled([
      store.commitOutput(f, id, {
        content: '合成已知分析输出',
        usage: { input: 11, output: 7 },
      }),
    ]);
    try {
      await until(
        async () =>
          (
            await db.query<Array<{ count: number }>>(
              "SELECT count(*)::int count FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%FOR UPDATE OF s%'",
            )
          )[0].count > 0,
      );
      await until(() => Date.now() > expiry + 20);
      await blocker.rollbackTransaction();
      expect((await settled)[0].status).toBe('rejected');
      expect(await sqlCounts(p.id)).toEqual(before);
      expect(await attempts(p.id)).toEqual(beforeAttempt);
      expect((await parent(p.id)).attempts_used).toBe(1);
      expect(posts).toHaveLength(0);
      evidence.push({
        code: 'ARTIFICIAL_SHORT_SLOT_RESULT_LOCK',
        expiry,
        observedAfter: Date.now(),
        counts: before,
        posts: 0,
        normalProductionReachabilityClaim: false,
      });
    } finally {
      if (blocker.isTransactionActive) await blocker.rollbackTransaction();
      await blocker.release();
    }
  });

  it('A: three independent POSTs, confirmed inputs/criteria, final writing version and read APIs zero extra requests', async () => {
    const p = await create();
    expect(await makeWorker().runOnce()).toBe(true);
    const live = await parent(p.id);
    expect(live.state).toBe('complete');
    expect(live.attempts_used).toBe(3);
    expect(posts.map((r) => [r.role, r.body.model])).toEqual([
      ['analysis', 'fixed-1'],
      ['writing', 'fixed-2'],
      ['review', 'fixed-3'],
    ]);
    posts.forEach((r) => {
      expect(r.body.stream).toBe(false);
      expect(r.body.max_tokens).toBe(2048);
      expect(Object.keys(r.body).sort()).toEqual([
        'max_tokens',
        'messages',
        'model',
        'stream',
      ]);
      expect(r.body.messages[1].content).toContain('confirmedAcceptance');
      expect(r.body.messages[1].content).toContain('仅此文本快照');
    });
    const refs = await attempts(p.id);
    expect(refs.map((r) => r.request_digest)).toEqual(
      posts.map((r) => r.digest),
    );
    const [final] = await db.query<
      Array<{ role: string; content: string; version: number }>
    >(
      'SELECT s.role,r.content,r.version FROM cloud_workflow_parents p JOIN cloud_workflow_results r ON p.final_result_id=r.id JOIN cloud_workflow_steps s ON s.id=r.step_id WHERE p.id=$1',
      [p.id],
    );
    expect(final).toEqual({
      role: 'writing',
      content: '# 合成最终成果',
      version: 1,
    });
    await control.list(1, null, 20);
    await control.results(1, p.id);
    await control.detail(1, p.id);
    expect(posts).toHaveLength(3);
    expect(
      refs.every(
        (r) =>
          r.state === 'succeeded' &&
          !!r.send_authorized_at &&
          r.input_tokens === 11,
      ),
    ).toBe(true);
  });
  it.each([0, 1])(
    'B: bounded rework budget %s; local failure overrides model passed',
    async (reworks) => {
      let writing = 0;
      respond = (post, res) => {
        if (post.role === 'writing' && ++writing === 1)
          res.end(
            JSON.stringify({
              choices: [
                {
                  message: { role: 'assistant', content: '# missing-term' },
                  finish_reason: 'stop',
                },
              ],
            }),
          );
        else success(post, res);
      };
      const p = await create((p) => {
        p.budget.reworks = reworks;
      });
      await makeWorker().runOnce();
      const live = await parent(p.id);
      expect(posts).toHaveLength(reworks ? 5 : 3);
      expect(live.state).toBe(reworks ? 'complete' : 'paused');
      const [row] = await db.query<
        Array<{ reworks: number; version: number | null }>
      >(
        'SELECT p.reworks,r.version FROM cloud_workflow_parents p LEFT JOIN cloud_workflow_results r ON r.id=p.final_result_id WHERE p.id=$1',
        [p.id],
      );
      expect(row).toEqual({ reworks, version: reworks ? 2 : null });
      expect(posts.filter((r) => r.role === 'analysis')).toHaveLength(1);
      if (reworks) {
        const reworkInput = JSON.parse(posts[3].body.messages[1].content) as {
          previousDraftMeetsAcceptance: boolean;
          committedResults: Array<{ role: string; content: string }>;
        };
        expect(reworkInput.previousDraftMeetsAcceptance).toBe(false);
        expect(reworkInput.committedResults.map((r) => r.role)).toEqual([
          'analysis',
          'writing',
          'review',
        ]);
        expect(reworkInput.committedResults[1].content).toBe('# missing-term');
      }
      if (!reworks)
        await expect(
          control.control(
            auth(),
            p.id,
            'continue',
            { operationId: randomUUID(), expectedRevision: live.revision },
            600000,
          ),
        ).rejects.toThrow();
    },
  );
  it('B: second negative review stops after five; malformed review pauses after three', async () => {
    respond = (post, res) => {
      if (post.role === 'review')
        res.end(
          JSON.stringify({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: '{"passed":false,"feedback":"revise"}',
                },
                finish_reason: 'stop',
              },
            ],
          }),
        );
      else success(post, res);
    };
    const p = await create();
    await makeWorker().runOnce();
    expect(posts).toHaveLength(5);
    expect((await parent(p.id)).reason).toBe('rework_limit_reached');
    await control.control(auth(), p.id, 'delete', {
      operationId: randomUUID(),
      expectedRevision: (await parent(p.id)).revision,
    });
    posts = [];
    respond = (post, res) => {
      if (post.role === 'review')
        res.end(
          JSON.stringify({
            choices: [
              {
                message: { role: 'assistant', content: '```json\n{}\n```' },
                finish_reason: 'stop',
              },
            ],
          }),
        );
      else success(post, res);
    };
    const q = await create();
    await makeWorker().runOnce();
    expect(posts).toHaveLength(3);
    expect((await parent(q.id)).reason).toBe('review_validation_failed');
    expect((await attempts(q.id))[2].state).toBe('failed');
  });
  it('C: two workers have one valid slot; completed analysis reused by different worker object', async () => {
    const p = await create();
    const held = gate();
    respond = (post, res) => {
      if (post.role === 'writing')
        void held.promise.then(() => success(post, res));
      else success(post, res);
    };
    const first = makeWorker();
    const started = first.runOnce();
    await until(() => posts.length === 2);
    expect(await makeWorker().runOnce()).toBe(false);
    expect(posts).toHaveLength(2);
    await first.shutdown();
    await started;
    held.resolve();
    await until(() => posts[1].disconnected);
    expect((await attempts(p.id))[1].state).toBe('unknown');
    expect(await makeWorker().runOnce()).toBe(false);
    expect(posts).toHaveLength(2);
  });
  it('C: planned pause before reservation resumes only writing/review on fresh worker', async () => {
    class PauseAfterAnalysis extends CloudWorkflowExecutionStore {
      async commitOutput(f: CloudFence, id: string, out: KnownOutput) {
        const p = await super.commitOutput(f, id, out);
        if (p.attempts_used === 1)
          await this.pauseExecution(f, null, 'explicit_checkpoint_pause', true);
        return { ...p, state: 'paused' };
      }
    }
    const p = await create();
    await makeWorker(new PauseAfterAnalysis(db)).runOnce();
    expect(posts).toHaveLength(1);
    const paused = await parent(p.id);
    await control.control(
      auth(),
      p.id,
      'continue',
      { operationId: randomUUID(), expectedRevision: paused.revision },
      600000,
    );
    await makeWorker().runOnce();
    expect(posts.map((r) => r.role)).toEqual(['analysis', 'writing', 'review']);
    expect((await parent(p.id)).state).toBe('complete');
  });

  it.each([
    'stop',
    'delete',
    'revoke',
    'version',
    'ban',
    'key',
    'endpoint',
    'provider',
    'model',
    'grant',
    'deadline',
    'lease',
  ])(
    'D: reservation barrier -> %s -> final permit: zero POST, reserved budget not refunded',
    async (change) => {
      const arrived = gate(),
        release = gate();
      class HeldPermit extends CloudWorkflowExecutionStore {
        async authorizeSend(f: CloudFence, id: string, wire: WireRequest) {
          arrived.resolve();
          await release.promise;
          return super.authorizeSend(f, id, wire);
        }
      }
      const p = await create();
      const running = makeWorker(new HeldPermit(db), 5000).runOnce();
      await arrived.promise;
      if (change === 'stop' || change === 'delete')
        await control.control(auth(), p.id, change, {
          operationId: randomUUID(),
          expectedRevision: (await parent(p.id)).revision,
        });
      else if (change === 'revoke')
        await control.revokeClient(
          auth(),
          p.payload!.clientInstanceId,
          randomUUID(),
        );
      else if (change === 'version')
        await db.query('UPDATE users SET "tokenVersion"=4 WHERE id=1');
      else if (change === 'ban')
        await db.query('UPDATE users SET banned=true WHERE id=1');
      else if (change === 'key')
        await db.query(
          'UPDATE ai_providers SET "apiKey"=\'changed-synthetic-key\' WHERE id=1',
        );
      else if (change === 'endpoint')
        await db.query(
          'UPDATE ai_providers SET "baseUrl"=\'http://127.0.0.1:1\' WHERE id=1',
        );
      else if (change === 'provider')
        await db.query('UPDATE ai_providers SET enabled=false WHERE id=1');
      else if (change === 'model')
        await db.query('UPDATE ai_models SET enabled=false WHERE id=1');
      else
        await db.query(
          `UPDATE cloud_workflow_parents SET ${change === 'grant' ? 'grant_expires_at' : change === 'deadline' ? 'deadline_at' : 'lease_expires_at'}=now()-interval '1 second' WHERE id=$1`,
          [p.id],
        );
      release.resolve();
      await running;
      expect(posts).toHaveLength(0);
      expect((await parent(p.id)).attempts_used).toBe(1);
      expect((await sqlCounts(p.id)).results).toBe(0);
      expect(await attempts(p.id)).toHaveLength(1);
    },
  );
  it('D: duplicate permit cannot be redeemed; unacknowledged send intent is unknown', async () => {
    const p = await create();
    const f = (await store.claim(randomUUID()))!;
    const plan = await store.readPlan(f);
    const wire = buildWire(plan, plan.steps[0]);
    const id = await store.reserveExecution(f, wire);
    await store.authorizeSend(f, id, wire);
    await expect(store.authorizeSend(f, id, wire)).rejects.toThrow();
    expect(posts).toHaveLength(0);
    await db.query(
      "UPDATE cloud_workflow_parents SET lease_expires_at=now()-interval '1 second' WHERE id=$1",
      [p.id],
    );
    await db.query(
      "UPDATE cloud_workflow_slot SET expires_at=now()-interval '1 second'",
    );
    await makeWorker().runOnce();
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect(posts).toHaveLength(0);
  });

  it('D: pre-C1b contextless dispatched attempt never obtains a permit or replays', async () => {
    const p = await create();
    const f = (await store.claim(randomUUID()))!;
    const plan = await store.readPlan(f),
      wire = buildWire(plan, plan.steps[0]);
    const id = await control.reserveDispatch(f, plan.steps[0].id, 100);
    await expect(store.authorizeSend(f, id, wire)).rejects.toThrow();
    expect((await attempts(p.id))[0].send_authorized_at).toBeNull();
    await db.query(
      "UPDATE cloud_workflow_parents SET lease_expires_at=now()-interval '1 second' WHERE id=$1",
      [p.id],
    );
    await db.query(
      "UPDATE cloud_workflow_slot SET expires_at=now()-interval '1 second'",
    );
    expect(await makeWorker().runOnce()).toBe(false);
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect((await parent(p.id)).attempts_used).toBe(1);
    expect(posts).toHaveLength(0);
  });
  it.each(['grant_expires_at', 'deadline_at', 'lease_expires_at'])(
    'D: final send TX waits user row lock beyond %s then rejects zero POST',
    async (field) => {
      const arrived = gate(),
        release = gate();
      class HeldPermit extends CloudWorkflowExecutionStore {
        async authorizeSend(f: CloudFence, id: string, wire: WireRequest) {
          arrived.resolve();
          await release.promise;
          return super.authorizeSend(f, id, wire);
        }
      }
      const p = await create();
      const running = makeWorker(new HeldPermit(db), 5000).runOnce();
      await arrived.promise;
      const expiry = Date.now() + 300;
      await db.query(
        `UPDATE cloud_workflow_parents SET ${field}=$1 WHERE id=$2`,
        [new Date(expiry), p.id],
      );
      const lock = db.createQueryRunner();
      await lock.connect();
      await lock.startTransaction();
      await lock.query('SELECT id FROM users WHERE id=1 FOR UPDATE');
      try {
        release.resolve();
        await until(
          async () =>
            (
              await db.query<Array<{ count: number }>>(
                "SELECT count(*)::int count FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%tokenVersion%FOR SHARE%'",
              )
            )[0].count > 0,
        );
        await until(() => Date.now() > expiry + 20);
        await lock.rollbackTransaction();
        await running;
        expect(posts).toHaveLength(0);
        expect((await attempts(p.id))[0].send_authorized_at).toBeNull();
        expect((await parent(p.id)).attempts_used).toBe(1);
        expect((await sqlCounts(p.id)).results).toBe(0);
        evidence.push({
          code: 'FINAL_SEND_REAL_ROW_LOCK_EXPIRY',
          field,
          expiry,
          observedAfter: Date.now(),
          posts: posts.length,
        });
      } finally {
        if (lock.isTransactionActive) await lock.rollbackTransaction();
        await lock.release();
      }
    },
  );
  it('D: expired global slot rejects final send independently of parent lease', async () => {
    const p = await create(),
      f = (await store.claim(randomUUID()))!;
    const plan = await store.readPlan(f),
      wire = buildWire(plan, plan.steps[0]);
    const id = await store.reserveExecution(f, wire);
    await db.query(
      "UPDATE cloud_workflow_slot SET expires_at=now()-interval '1 second'",
    );
    await expect(store.authorizeSend(f, id, wire)).rejects.toThrow();
    expect((await attempts(p.id))[0].send_authorized_at).toBeNull();
    expect((await parent(p.id)).attempts_used).toBe(1);
    expect(posts).toHaveLength(0);
  });
  it('F: reservation commit ack loss finds original orphan and pauses unknown, zero fetch', async () => {
    class LostReservation extends CloudWorkflowExecutionStore {
      async reserveExecution(
        f: CloudFence,
        wire: WireRequest,
      ): Promise<string> {
        await super.reserveExecution(f, wire);
        throw Error('synthetic_reservation_ack_lost');
      }
    }
    const p = await create();
    await makeWorker(new LostReservation(db)).runOnce();
    expect((await attempts(p.id))[0]).toMatchObject({
      state: 'unknown',
      send_authorized_at: null,
    });
    expect((await parent(p.id)).attempts_used).toBe(1);
    expect((await parent(p.id)).usage_unknown).toBe(true);
    expect(await makeWorker().runOnce()).toBe(false);
    expect(posts).toHaveLength(0);
  });
  it('D: changed committed result after writer reservation cannot obtain final permit', async () => {
    const arrived = gate(),
      release = gate();
    class HeldWriter extends CloudWorkflowExecutionStore {
      async authorizeSend(f: CloudFence, id: string, wire: WireRequest) {
        if (wire.refs.results.length) {
          arrived.resolve();
          await release.promise;
        }
        return super.authorizeSend(f, id, wire);
      }
    }
    const p = await create(),
      running = makeWorker(new HeldWriter(db), 5000).runOnce();
    await arrived.promise;
    await db.query(
      "UPDATE cloud_workflow_results SET content='changed',content_hash=$1 WHERE parent_id=$2",
      [hashText('changed'), p.id],
    );
    release.resolve();
    await running;
    expect(posts.map((p) => p.role)).toEqual(['analysis']);
    expect((await attempts(p.id))[1].send_authorized_at).toBeNull();
    expect((await parent(p.id)).attempts_used).toBe(2);
  });

  it.each(['stop', 'delete'] as const)(
    'D: in-flight %s aborts before settlement, late output cannot write',
    async (kind) => {
      let response!: ServerResponse;
      respond = (_post, res) => {
        response = res;
      };
      const p = await create();
      const w = makeWorker(store, 25);
      const running = w.runOnce();
      await until(() => posts.length === 1);
      const [slotBefore] = await db.query<Array<{ parent_id: string }>>(
        'SELECT parent_id FROM cloud_workflow_slot',
      );
      expect(slotBefore.parent_id).toBe(p.id);
      await control.control(auth(), p.id, kind, {
        operationId: randomUUID(),
        expectedRevision: (await parent(p.id)).revision,
      });
      await running;
      await until(() => posts[0].disconnected);
      success(posts[0], response);
      expect(posts).toHaveLength(1);
      expect((await sqlCounts(p.id)).results).toBe(0);
      expect((await attempts(p.id))[0].state).toBe('unknown');
      expect((await parent(p.id)).state).toBe(
        kind === 'delete' ? 'deleted' : 'cancelled',
      );
      expect(
        (
          await db.query<Array<{ parent_id: string | null }>>(
            'SELECT parent_id FROM cloud_workflow_slot',
          )
        )[0].parent_id,
      ).toBeNull();
    },
  );
  it('E: server receives POST then socket disconnect; recreated worker sends nothing', async () => {
    respond = (_post, res) => {
      res.destroy();
    };
    const p = await create();
    await makeWorker().runOnce();
    expect(posts).toHaveLength(1);
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect(await makeWorker().runOnce()).toBe(false);
    expect(posts).toHaveLength(1);
    expect((await parent(p.id)).usage_unknown).toBe(true);
  });
  it('E: actual child process SIGKILL after upstream received, lease recovery never replays', async () => {
    respond = () => {};
    const p = await create();
    const child = fork(
      resolve(__dirname, 'cloud-workflow.worker-process.fixture.ts'),
      [],
      {
        execArgv: ['-r', 'ts-node/register'],
        env: { ...process.env, TS_NODE_TRANSPILE_ONLY: '1' },
        silent: true,
      },
    );
    const messages: unknown[] = [];
    child.on('message', (v) => messages.push(v));
    let childErrors = '';
    child.stderr?.on('data', (v: Buffer) => {
      childErrors += v.toString();
    });
    try {
      await until(() => posts.length === 1, 10000);
      expect(messages).toContainEqual({ code: 'CHILD_IDENTITY_VERIFIED' });
      const closed = new Promise<{
        code: number | null;
        signal: string | null;
      }>((r) => child.once('exit', (code, signal) => r({ code, signal })));
      expect(child.kill('SIGKILL')).toBe(true);
      const ended = await closed;
      expect(ended.signal).toBe('SIGKILL');
      await until(() => posts[0].disconnected);
      await db.query(
        "UPDATE cloud_workflow_slot SET expires_at=now()-interval '1 second'",
      );
      await db.query(
        "UPDATE cloud_workflow_parents SET lease_expires_at=now()-interval '1 second' WHERE id=$1",
        [p.id],
      );
      expect(await makeWorker().runOnce()).toBe(false);
      expect((await attempts(p.id))[0].state).toBe('unknown');
      expect(posts).toHaveLength(1);
      evidence.push({
        code: 'ACTUAL_CHILD_SIGKILL',
        pid: child.pid,
        exit: ended,
        receivedPosts: 1,
        afterRecoveryPosts: posts.length,
        childErrors,
      });
    } finally {
      if (child.exitCode === null && child.signalCode === null)
        child.kill('SIGKILL');
    }
  });

  it('F: result trigger fails then recovery only retries same buffer; does not dispatch next node', async () => {
    await db.query(
      `CREATE FUNCTION c1b_block_result_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic result blocked'; END $$`,
    );
    await db.query(
      'CREATE TRIGGER c1b_block_result BEFORE INSERT ON cloud_workflow_results FOR EACH ROW EXECUTE FUNCTION c1b_block_result_fn()',
    );
    let writes = 0;
    class CountSave extends CloudWorkflowExecutionStore {
      async commitOutput(f: CloudFence, id: string, o: KnownOutput) {
        try {
          return await super.commitOutput(f, id, o);
        } finally {
          writes++;
          if (writes === 1)
            await db.query(
              'DROP TRIGGER c1b_block_result ON cloud_workflow_results',
            );
        }
      }
    }
    const p = await create();
    await makeWorker(new CountSave(db)).runOnce();
    expect(writes).toBe(2);
    expect(posts).toHaveLength(1);
    expect(await sqlCounts(p.id)).toMatchObject({ results: 1, attempts: 1 });
    expect((await attempts(p.id))[0].input_tokens).toBe(11);
    expect((await parent(p.id)).state).toBe('paused');
  });
  it('F: injected result commit ack loss reconciles one result/usage/event without resend', async () => {
    let calls = 0;
    class LostAck extends CloudWorkflowExecutionStore {
      async commitOutput(f: CloudFence, id: string, o: KnownOutput) {
        const p = await super.commitOutput(f, id, o);
        if (++calls === 1) throw Error('synthetic_commit_ack_lost');
        return p;
      }
    }
    const p = await create();
    await makeWorker(new LostAck(db)).runOnce();
    expect(posts).toHaveLength(1);
    expect(calls).toBe(2);
    expect(await sqlCounts(p.id)).toMatchObject({ results: 1, attempts: 1 });
    expect(
      (
        await db.query<Array<{ count: number }>>(
          "SELECT count(*)::int count FROM cloud_workflow_events WHERE parent_id=$1 AND code='result_committed'",
          [p.id],
        )
      )[0].count,
    ).toBe(1);
    expect((await attempts(p.id))[0].state).toBe('succeeded');
  });
  it('F: reservation/permit commit ack uncertainty is zero POST and never redeemed twice', async () => {
    class LostPermitAck extends CloudWorkflowExecutionStore {
      async authorizeSend(
        f: CloudFence,
        id: string,
        w: WireRequest,
      ): Promise<SendPermit> {
        await super.authorizeSend(f, id, w);
        throw Error('synthetic_permit_commit_ack_lost');
      }
    }
    const p = await create();
    await makeWorker(new LostPermitAck(db)).runOnce();
    expect(posts).toHaveLength(0);
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect(await makeWorker().runOnce()).toBe(false);
    expect((await parent(p.id)).attempts_used).toBe(1);
  });
  it('G: real PG lock timeout during renewal aborts in-flight HTTP; recovery does not replay', async () => {
    respond = () => {};
    const p = await create();
    const running = makeWorker(store, 25).runOnce();
    await until(() => posts.length === 1);
    const blocker = db.createQueryRunner();
    await blocker.connect();
    await blocker.startTransaction();
    await blocker.query('SELECT pg_advisory_xact_lock(178404,1)');
    try {
      await until(() => posts[0].disconnected, 5000);
    } finally {
      await blocker.rollbackTransaction();
      await blocker.release();
    }
    await running;
    expect(posts).toHaveLength(1);
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect(await makeWorker().runOnce()).toBe(false);
  });
  it('G: real worker PG connection terminated during renewal aborts held response', async () => {
    const options = {
      ...db.options,
      extra: {
        max: 2,
        connectionTimeoutMillis: 1000,
        application_name: 'c1b-terminated-worker',
      },
    };
    const workerDb = new DataSource(options);
    await workerDb.initialize();
    const blocker = db.createQueryRunner();
    await blocker.connect();
    try {
      respond = () => {};
      const p = await create();
      const running = makeWorker(
        new CloudWorkflowExecutionStore(workerDb),
        25,
      ).runOnce();
      await until(() => posts.length === 1);
      await blocker.startTransaction();
      await blocker.query('SELECT pg_advisory_xact_lock(178404,1)');
      await until(
        async () =>
          (
            await db.query<Array<{ count: number }>>(
              "SELECT count(*)::int count FROM pg_stat_activity WHERE application_name='c1b-terminated-worker' AND wait_event_type='Lock'",
            )
          )[0].count > 0,
      );
      const terminated = await db.query<Array<{ terminated: boolean }>>(
        "SELECT pg_terminate_backend(pid) terminated FROM pg_stat_activity WHERE application_name='c1b-terminated-worker' AND wait_event_type='Lock'",
      );
      expect(terminated.every((r) => r.terminated)).toBe(true);
      await until(() => posts[0].disconnected);
      await blocker.rollbackTransaction();
      await running;
      expect(posts).toHaveLength(1);
      expect((await attempts(p.id))[0].state).toBe('unknown');
      expect(await makeWorker().runOnce()).toBe(false);
      evidence.push({
        code: 'REAL_PG_CONNECTION_TERMINATED',
        terminated: terminated.length,
        posts: 1,
      });
    } finally {
      if (blocker.isTransactionActive) await blocker.rollbackTransaction();
      await blocker.release();
      await workerDb.destroy();
    }
  });
  it.each(['attempts', 'tokens', 'deadline'])(
    'H: %s budget is hard at reservation; full snapshots not silently clipped',
    async (budget) => {
      const p = await create((v) => {
        if (budget === 'attempts') v.budget.attempts = 1;
        else if (budget === 'tokens') v.budget.estimatedTokens = 2048;
        else v.budget.durationMs = 1;
      });
      await makeWorker().runOnce();
      expect(posts).toHaveLength(budget === 'attempts' ? 1 : 0);
      const live = await parent(p.id);
      expect(live.attempts_used).toBe(budget === 'attempts' ? 1 : 0);
      expect(live.state).not.toBe('running');
    },
  );
  it.each([
    '500',
    '429',
    'redirect',
    'invalid',
    'tools',
    'content_limit',
    'envelope_limit',
    'truncated',
  ])('H: %s: one HTTP attempt, no transparent retry', async (mode) => {
    respond = (_post, res) => {
      if (mode === '500' || mode === '429') {
        res.statusCode = Number(mode);
        res.end('synthetic_error');
      } else if (mode === 'redirect') {
        res.statusCode = 302;
        res.setHeader('Location', endpoint + '/another');
        res.end();
      } else if (mode === 'invalid') res.end('{not-json');
      else if (mode === 'tools')
        res.end(
          JSON.stringify({
            choices: [
              {
                message: { role: 'assistant', content: 'text', tool_calls: [] },
                finish_reason: 'stop',
              },
            ],
          }),
        );
      else if (mode === 'content_limit')
        res.end(
          JSON.stringify({
            choices: [
              {
                message: { role: 'assistant', content: 'x'.repeat(12001) },
                finish_reason: 'stop',
              },
            ],
          }),
        );
      else if (mode === 'envelope_limit') res.end('x'.repeat(131073));
      else {
        res.setHeader('Content-Length', '10000');
        res.write('{');
        setTimeout(() => res.destroy(), 20);
      }
    };
    const p = await create();
    await makeWorker().runOnce();
    expect(posts).toHaveLength(1);
    expect((await parent(p.id)).attempts_used).toBe(1);
    const unknown = ['redirect', 'envelope_limit', 'truncated'].includes(mode);
    expect((await attempts(p.id))[0].state).toBe(
      unknown ? 'unknown' : 'failed',
    );
    expect((await sqlCounts(p.id)).results).toBe(0);
  });
  it('H: shutdown aborts held request and future explicit call sends nothing', async () => {
    respond = () => {};
    const p = await create();
    const worker = makeWorker();
    const running = worker.runOnce();
    await until(() => posts.length === 1);
    await worker.shutdown();
    await running;
    await until(() => posts[0].disconnected);
    expect(await worker.runOnce()).toBe(false);
    expect(posts).toHaveLength(1);
    expect((await attempts(p.id))[0].state).toBe('unknown');
  });
  it('H: local hard deadline aborts held HTTP without waiting heartbeat', async () => {
    respond = () => {};
    const p = await create((v) => {
      v.budget.durationMs = 200;
      v.grantDurationMs = 200;
    });
    await makeWorker(store, 5000).runOnce();
    expect(posts).toHaveLength(1);
    expect(posts[0].disconnected).toBe(true);
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect((await parent(p.id)).attempts_used).toBe(1);
  });
  it('F: persistent result storage failure retries three times then unknown; no second POST', async () => {
    await db.query(
      `CREATE FUNCTION c1b_block_result_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic persistent failure'; END $$`,
    );
    await db.query(
      'CREATE TRIGGER c1b_block_result BEFORE INSERT ON cloud_workflow_results FOR EACH ROW EXECUTE FUNCTION c1b_block_result_fn()',
    );
    let count = 0;
    class CountFailedWrites extends CloudWorkflowExecutionStore {
      commitOutput(f: CloudFence, id: string, o: KnownOutput) {
        count++;
        return super.commitOutput(f, id, o);
      }
    }
    const p = await create();
    await makeWorker(new CountFailedWrites(db)).runOnce();
    expect(count).toBe(3);
    expect(posts).toHaveLength(1);
    expect((await sqlCounts(p.id)).results).toBe(0);
    expect((await attempts(p.id))[0].state).toBe('unknown');
    await db.query('DROP TRIGGER c1b_block_result ON cloud_workflow_results');
    expect(await makeWorker().runOnce()).toBe(false);
    expect(posts).toHaveLength(1);
  });
  it('F: duplicate negative-review save ack cannot double rework; exact writing version published', async () => {
    let reviews = 0;
    respond = (post, res) => {
      if (post.role === 'review' && ++reviews === 1)
        res.end(
          JSON.stringify({
            choices: [
              {
                message: {
                  role: 'assistant',
                  content: '{"passed":false,"feedback":"revise once"}',
                },
                finish_reason: 'stop',
              },
            ],
          }),
        );
      else success(post, res);
    };
    let lost = false;
    class LostReworkAck extends CloudWorkflowExecutionStore {
      async commitOutput(f: CloudFence, id: string, o: KnownOutput) {
        const p = await super.commitOutput(f, id, o);
        if (!lost && p.attempts_used === 3) {
          lost = true;
          throw Error('synthetic_rework_ack_lost');
        }
        return p;
      }
    }
    const p = await create();
    await makeWorker(new LostReworkAck(db)).runOnce();
    expect(posts).toHaveLength(3);
    expect(
      (
        await db.query<Array<{ count: number }>>(
          "SELECT count(*)::int count FROM cloud_workflow_events WHERE parent_id=$1 AND code='rework_committed'",
          [p.id],
        )
      )[0].count,
    ).toBe(1);
    const live = await parent(p.id);
    expect(live.state).toBe('paused');
    await control.control(
      auth(),
      p.id,
      'continue',
      { operationId: randomUUID(), expectedRevision: live.revision },
      600000,
    );
    await makeWorker().runOnce();
    expect(posts).toHaveLength(5);
    expect((await parent(p.id)).state).toBe('complete');
    expect(
      (
        await db.query<Array<{ version: number }>>(
          'SELECT r.version FROM cloud_workflow_results r JOIN cloud_workflow_parents p ON p.final_result_id=r.id WHERE p.id=$1',
          [p.id],
        )
      )[0].version,
    ).toBe(2);
  });
  it('D: profile revoked during held HTTP aborts automatically into needs_configuration', async () => {
    respond = () => {};
    const p = await create();
    const running = makeWorker(store, 25).runOnce();
    await until(() => posts.length === 1);
    await db.query(
      'UPDATE ai_providers SET "apiKey"=\'revoked-synthetic\' WHERE id=1',
    );
    await running;
    await until(() => posts[0].disconnected);
    expect(posts).toHaveLength(1);
    expect((await parent(p.id)).state).toBe('needs_configuration');
    expect((await attempts(p.id))[0].state).toBe('unknown');
    expect((await parent(p.id)).usage_unknown).toBe(true);
  });
});
