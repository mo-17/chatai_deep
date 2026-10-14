import { DataSource, type QueryRunner } from 'typeorm';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudDispatchPermit1784050000000 } from '../migrations/1784050000000-AddCloudDispatchPermit';
import { AddCloudSchedulerGate1784060000000 } from '../migrations/1784060000000-AddCloudSchedulerGate';
import { runMigrationsWithAdvisoryLock } from '../database/migration-runner';
import { CloudWorkflowStore } from './cloud-workflow.store';
import { CloudWorkflowService } from './cloud-workflow.service';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import { fixturePayload } from './cloud-workflow.fixture';
import { type CloudAuthorization } from './cloud-workflow.contract';
import { Test } from '@nestjs/testing';
import { createServer, type Server, type ServerResponse } from 'node:http';
import { fork } from 'node:child_process';
import { resolve } from 'node:path';
import * as jwt from 'jsonwebtoken';
import { JWT_SECRET } from '../auth/jwt.const';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import type { User } from '../user/user.entity';
import type { Repository } from 'typeorm';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import { CloudWorkflowWorker } from './cloud-workflow.worker';
import { CloudWorkflowTransport } from './cloud-workflow.transport';
import { CloudWorkflowPrivateRuntime } from './cloud-workflow.private-runtime';
import { CloudWorkflowController } from './cloud-workflow.controller';
import { CloudWorkflowGuard } from './cloud-workflow.guard';
async function until(test: () => boolean | Promise<boolean>, timeout = 6000) {
  const end = Date.now() + timeout;
  while (!(await test())) {
    if (Date.now() >= end) throw Error('fixture_bounded_wait');
    await new Promise((r) => setTimeout(r, 5));
  }
}
class SyntheticReady extends CloudWorkflowReadiness {
  capabilities() {
    return { ...super.capabilities(), available: true };
  }
}
const pg = process.env.CLOUD_C3B_PG_TEST === '1' ? describe : describe.skip;
pg(
  'C3b private runtime explicit kick, true private PG and Node synthetic upstream',
  () => {
    jest.setTimeout(20000);
    let db: DataSource,
      store: CloudWorkflowExecutionStore,
      worker: CloudWorkflowWorker,
      runtime: CloudWorkflowPrivateRuntime,
      server: Server,
      base: string;
    let posts: Array<{ role: string; body: unknown; disconnected: boolean }> =
        [],
      respond: (role: string, res: ServerResponse) => void,
      port: number;
    const evidence: unknown[] = [],
      runners: QueryRunner[] = [],
      children: ReturnType<typeof fork>[] = [];
    const token = () =>
      jwt.sign({ userId: 1, tokenVersion: 3 }, JWT_SECRET, {
        algorithm: 'HS256',
        expiresIn: 600,
      });
    const auth = (): CloudAuthorization => ({
      userId: 1,
      securityVersion: 3,
      expiresAt: Date.now() + 600000,
    });
    const json = async (
      path: string,
      body: unknown,
      headers: Record<string, string> = {},
    ) => {
      const r = await fetch(base + path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...headers },
        body: JSON.stringify(body),
      });
      return {
        status: r.status,
        body: (await r.json()) as Record<string, unknown>,
      };
    };
    const control = (op: string, epoch = '1') =>
      json('/_cloud/control', op === 'status' ? { op } : { op, epoch });
    const parent = async (id: string) => (await store.detail(1, id)).parent;
    const counts = async () =>
      db.query<unknown[]>(
        'SELECT (SELECT count(*) FROM cloud_workflow_parents) parents,(SELECT count(*) FROM cloud_workflow_attempts) attempts,(SELECT count(*) FROM cloud_workflow_results) results,(SELECT count(*) FROM cloud_workflow_events) events',
      );
    const success = (role: string, res: ServerResponse) =>
      res.end(
        JSON.stringify({
          choices: [
            {
              message: {
                role: 'assistant',
                content:
                  role === 'review'
                    ? '{"passed":true,"feedback":""}'
                    : role === 'writing'
                      ? '# 合成成果'
                      : '合成分析',
              },
              finish_reason: 'stop',
            },
          ],
          usage: { prompt_tokens: 11, completion_tokens: 7 },
        }),
      );
    const create = async () => {
      const p = fixturePayload();
      const r = await json('/_cloud/admit', p, {
        Authorization: `Bearer ${token()}`,
        'x-chatai-cloud-epoch': '1',
      });
      expect(r.status).toBe(200);
      return r.body as unknown as Awaited<
        ReturnType<CloudWorkflowStore['create']>
      >;
    };
    beforeAll(async () => {
      const e = process.env,
        nonce = e.CLOUD_PG_NONCE,
        socket = e.CLOUD_PG_SOCKET;
      if (
        !nonce ||
        !socket?.startsWith('/tmp/chatai-cloud-C3b-') ||
        e.CLOUD_PG_DATABASE !== `chatai_cloud_test_${nonce}` ||
        e.CLOUD_PG_USER !== `cloud_${nonce}`
      )
        throw Error('private_nonce_required');
      expect(
        (
          JSON.parse(
            readFileSync(socket + '/fixture-sentinel.json', 'utf8'),
          ) as { nonce: string }
        ).nonce,
      ).toBe(nonce);
      db = new DataSource({
        type: 'postgres',
        host: socket,
        port: Number(e.CLOUD_PG_PORT),
        username: e.CLOUD_PG_USER,
        password: '',
        database: e.CLOUD_PG_DATABASE,
        synchronize: false,
        logging: false,
        extra: {
          max: 8,
          connectionTimeoutMillis: 3000,
          application_name: 'c3b-fixture',
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
      evidence.push({ code: 'PRIVATE_PG_IDENTITY', identity, nonce });
      await db.query('CREATE TABLE fixture_sentinel(nonce text PRIMARY KEY)');
      await db.query('INSERT INTO fixture_sentinel VALUES($1)', [nonce]);
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(7);
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(0);
      evidence.push({ apply: 7, noop: 0, productionCli: false });
    });
    beforeEach(async () => {
      expect(
        (
          await db.query<Array<{ nonce: string }>>(
            'SELECT nonce FROM fixture_sentinel',
          )
        )[0].nonce,
      ).toBe(process.env.CLOUD_PG_NONCE);
      await db.query('DELETE FROM cloud_workflow_parents');
      await db.query(
        'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL',
      );
      await db.query(
        'UPDATE cloud_workflow_scheduler_gate SET epoch=0,accepting=false',
      );
      await db.query(
        `INSERT INTO users(id,"userName","tokenVersion",banned) VALUES(1,'synthetic',3,false),(2,'other',3,false) ON CONFLICT(id) DO UPDATE SET "tokenVersion"=3,banned=false`,
      );
      posts = [];
      respond = success;
      server = createServer((req, res) => {
        let text = '';
        req.setEncoding('utf8');
        req.on('data', (c) => (text += c));
        req.on('end', () => {
          const body = JSON.parse(text) as {
            messages: Array<{ content: string }>;
          };
          const role = body.messages[0].content.includes('review')
            ? 'review'
            : body.messages[0].content.includes('writing')
              ? 'writing'
              : 'analysis';
          const post = { role, body, disconnected: false };
          posts.push(post);
          res.on('close', () => (post.disconnected = true));
          respond(role, res);
        });
      });
      await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
      const addr = server.address();
      if (!addr || typeof addr === 'string') throw Error('missing_upstream');
      await db.query(
        `INSERT INTO ai_providers(id,code,"displayName","apiKey","baseUrl") VALUES(1,'synthetic','synthetic','synthetic-only',$1) ON CONFLICT(id) DO UPDATE SET "baseUrl"=$1,enabled=true,"apiKey"='synthetic-only'`,
        [`http://127.0.0.1:${addr.port}/v1`],
      );
      await db.query(
        `INSERT INTO ai_models(id,"providerId","modelId","displayName") VALUES(1,1,'synthetic','synthetic') ON CONFLICT(id) DO UPDATE SET enabled=true`,
      );
      store = new CloudWorkflowExecutionStore(db);
      worker = new CloudWorkflowWorker(store, new CloudWorkflowTransport(), {
        heartbeatMs: 75,
      });
      // Private authentication MUST use bounded store reader, not shared repository.
      const authentication = new TokenAuthenticationService({
        findOne: () => {
          throw Error('unbounded_shared_auth_reader');
        },
      } as unknown as Repository<User>);
      runtime = CloudWorkflowPrivateRuntime.synthetic(
        store,
        worker,
        authentication,
        new SyntheticReady(),
      );
      port = await runtime.listen(0, '127.0.0.1');
      base = `http://127.0.0.1:${port}`;
    });
    afterEach(async () => {
      for (const c of children.splice(0)) {
        if (c.exitCode === null && c.signalCode === null) c.kill('SIGKILL');
      }
      for (const r of runners.splice(0)) {
        if (r.isTransactionActive) await r.rollbackTransaction();
        if (!r.isReleased) await r.release();
      }
      await runtime.beforeApplicationShutdown();
      await store.close();
      server.closeAllConnections();
      await new Promise<void>((r) => server.close(() => r()));
      evidence.push({
        test: expect.getState().currentTestName,
        posts,
        counts: await counts(),
        poolClosed: true,
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
    it('production runtime cannot listen, constructor and public capability do not claim', async () => {
      const disabled = new CloudWorkflowPrivateRuntime(
        store,
        worker,
        new TokenAuthenticationService({} as Repository<User>),
        new CloudWorkflowReadiness(),
      );
      await expect(disabled.listen(0, '127.0.0.1')).rejects.toThrow('disabled');
      expect(posts).toHaveLength(0);
      expect(new CloudWorkflowReadiness().capabilities().available).toBe(false);
      await disabled.beforeApplicationShutdown();
    });
    it('bounded private auth+gate+create then quick duplicate kick single-flight completes three real POSTs', async () => {
      expect((await control('open')).status).toBe(200);
      const p = await create();
      const replies = await Promise.all([control('kick'), control('kick')]);
      expect(replies.every((r) => r.status === 200)).toBe(true);
      await until(async () => (await parent(p.id)).state === 'complete');
      await until(() => !worker.isActive);
      expect(posts.map((p) => p.role)).toEqual([
        'analysis',
        'writing',
        'review',
      ]);
      const old = posts.length;
      await store.list(1, null, 4);
      await store.results(1, p.id);
      await control('status');
      expect(posts).toHaveLength(old);
      expect((await control('close')).body).toMatchObject({
        work: 'idle',
        accepting: false,
      });
    });
    it('stale kick epoch cannot claim and invalid guest JWT cannot admit', async () => {
      await control('open');
      expect((await control('kick', '0')).status).toBe(409);
      expect(
        (
          await json('/_cloud/admit', fixturePayload(), {
            Authorization: 'Bearer guest-mode',
            'x-chatai-cloud-epoch': '1',
          })
        ).status,
      ).toBe(401);
      expect(posts).toHaveLength(0);
    });
    it('expired queued head followed by valid owner progresses even claim returns null', async () => {
      await control('open');
      const old = await create();
      await db.query(
        `UPDATE cloud_workflow_parents SET grant_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1`,
        [old.id],
      );
      const other = fixturePayload();
      const p = await store.create({ ...auth(), userId: 2 }, other, Date.now, {
        epoch: '1',
      });
      await control('kick');
      await until(
        async () => (await store.detail(2, p.id)).parent.state === 'complete',
      );
      expect(posts).toHaveLength(3);
      expect((await parent(old.id)).state).not.toBe('queued');
    });
    it('busy expired slot gets reaped on kick; dispatched unknown is never sent again', async () => {
      await control('open');
      const p = await create();
      const f = await store.claim(randomUUID());
      expect(f).not.toBeNull();
      await db.query(
        `UPDATE cloud_workflow_parents SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1`,
        [p.id],
      );
      await db.query(
        `UPDATE cloud_workflow_slot SET expires_at=clock_timestamp()-interval '1 second'`,
      );
      expect((await control('status')).body.work).toBe('busy');
      await control('kick');
      await until(async () => (await parent(p.id)).state === 'complete');
      expect(posts).toHaveLength(3);
    });
    it('private control routes absent from real minimal public Nest even with valid user JWT/forged metadata', async () => {
      const normalAuth = new TokenAuthenticationService({
        findOne: async () => store.cloudAuthUser(1),
      } as unknown as Repository<User>);
      const module = await Test.createTestingModule({
        controllers: [CloudWorkflowController],
        providers: [
          CloudWorkflowGuard,
          { provide: TokenAuthenticationService, useValue: normalAuth },
          {
            provide: CloudWorkflowService,
            useValue: new CloudWorkflowService(
              store,
              new CloudWorkflowReadiness(),
            ),
          },
        ],
      }).compile();
      const app = module.createNestApplication();
      await app.listen(0, '127.0.0.1');
      const url = await app.getUrl();
      const before = await store.schedulerStatus();
      try {
        for (const path of [
          '/_cloud/control',
          '/%5fcloud/control',
          '//_cloud/control',
          '/uapi/../_cloud/control',
          '/_cloud/admit',
        ]) {
          const r = await fetch(url + path, {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${token()}`,
              'Content-Type': 'application/json',
              'cf-container-target-port': '3101',
              'x-chatai-cloud-epoch': '9',
              'x-original-url': '/_cloud/control',
              'x-rewrite-url': '/_cloud/control',
            },
            body: JSON.stringify({ op: 'open', epoch: '9' }),
          });
          expect(r.status).toBe(404);
        }
        expect(await store.schedulerStatus()).toEqual(before);
        expect(posts).toHaveLength(0);
        const r = await fetch(url + '/uapi/cloud-workflows', {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token()}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(fixturePayload()),
        });
        expect(r.status).toBe(503);
      } finally {
        await app.close();
      }
    });
    it('stop after real POST aborts before slot settlement; no late output and unknown step', async () => {
      await control('open');
      respond = () => {};
      const p = await create();
      await control('kick');
      await until(() => posts.length === 1);
      const active = await parent(p.id);
      await store.control(auth(), p.id, 'stop', {
        operationId: randomUUID(),
        expectedRevision: active.revision,
      });
      await until(() => !worker.isActive);
      expect(posts[0].disconnected).toBe(true);
      expect(posts).toHaveLength(1);
      const d = await store.detail(1, p.id);
      expect(d.parent.state).toBe('cancelled');
      expect(d.steps[0].state).toBe('unknown');
      expect(await store.results(1, p.id)).toHaveLength(0);
      expect((await control('status')).body.work).toBe('idle');
    });
    it('grant deadline cannot dispatch after kick and DB lock timeout never claims permission', async () => {
      await control('open');
      const p = await create();
      await db.query(
        `UPDATE cloud_workflow_parents SET grant_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1`,
        [p.id],
      );
      await control('kick');
      await until(() => !worker.isActive);
      expect(posts).toHaveLength(0);
      const q = db.createQueryRunner();
      runners.push(q);
      await q.connect();
      await q.startTransaction();
      await q.query('SELECT pg_advisory_xact_lock(178404,1)');
      const before = await counts();
      const r = await control('open', '2');
      expect(r.status).toBe(503);
      expect(await counts()).toEqual(before);
      expect(posts).toHaveLength(0);
      await q.rollbackTransaction();
    });
    it('actual Nest close aborts fetch, drains listener handlers then permanently closes dedicated pool', async () => {
      await control('open');
      respond = () => {};
      await create();
      await control('kick');
      await until(() => posts.length === 1);
      const module = await Test.createTestingModule({
        providers: [
          { provide: CloudWorkflowPrivateRuntime, useValue: runtime },
          { provide: CloudWorkflowWorker, useValue: worker },
          { provide: CloudWorkflowExecutionStore, useValue: store },
        ],
      }).compile();
      const app = module.createNestApplication();
      await app.init();
      await app.close();
      expect(worker.isActive).toBe(false);
      expect(posts[0].disconnected).toBe(true);
      await expect(store.schedulerStatus()).rejects.toThrow('closed');
      await expect(
        fetch(base + '/_cloud/control', { method: 'POST', body: '{}' }),
      ).rejects.toThrow();
    });
    it('actual SDK/DO forwarding to real public Nest cannot reach controls; trusted synthetic admission keeps original JWT', async () => {
      const normalAuth = new TokenAuthenticationService({
        findOne: async () => store.cloudAuthUser(1),
      } as unknown as Repository<User>);
      const module = await Test.createTestingModule({
        controllers: [CloudWorkflowController],
        providers: [
          CloudWorkflowGuard,
          { provide: TokenAuthenticationService, useValue: normalAuth },
          {
            provide: CloudWorkflowService,
            useValue: new CloudWorkflowService(
              store,
              new CloudWorkflowReadiness(),
            ),
          },
        ],
      }).compile();
      const app = module.createNestApplication();
      await app.listen(0, '127.0.0.1');
      const publicUrl = await app.getUrl();
      const child = fork(
        resolve(
          '../cloudflare/backend/test/cloud-scheduler-bridge.fixture.mjs',
        ),
        [],
        {
          env: {
            ...process.env,
            C3B_PUBLIC_URL: publicUrl,
            C3B_PRIVATE_URL: base,
          },
          silent: true,
          execArgv: [],
        },
      );
      children.push(child);
      const messages: Array<Record<string, unknown>> = [];
      child.on('message', (m) => messages.push(m as Record<string, unknown>));
      try {
        await until(() => messages.some((m) => m.code === 'SDK_BRIDGE_READY'));
        const request = async (
          path: string,
          body: unknown,
          headers: Record<string, string> = {},
        ) => {
          const id = randomUUID();
          child.send({
            id,
            path,
            body,
            headers: { 'Content-Type': 'application/json', ...headers },
          });
          await until(() => messages.some((m) => m.id === id));
          return messages.find((m) => m.id === id)!;
        };
        const before = await store.schedulerStatus();
        for (const path of [
          '/_cloud/control',
          '/%5fcloud/control',
          '//_cloud/control',
          '/uapi/../_cloud/control',
          '/uapi/cloud-workflows/unknown?rewrite=/_cloud/control',
        ]) {
          const r = await request(
            path,
            { op: 'open', epoch: '900' },
            {
              Authorization: `Bearer ${token()}`,
              'cf-container-target-port': '3101',
              'x-chatai-cloud-epoch': '900',
              'x-cloud-workflow-control': 'open',
              'x-rewrite-url': '/_cloud/control',
            },
          );
          expect(r.status).toBe(404);
        }
        expect(await store.schedulerStatus()).toEqual(before);
        expect(posts).toHaveLength(0);
        const r = await request('/uapi/cloud-workflows', fixturePayload(), {
          Authorization: `Bearer ${token()}`,
          'cf-container-target-port': '9999',
          'x-chatai-cloud-epoch': '999',
        });
        evidence.push({ code: 'SDK_ADMISSION_RESULT', result: r });
        expect(r.status).toBe(200);
        expect((await store.schedulerStatus()).epoch).toBe('1');
        await control('kick');
        await until(() => posts.length === 3);
        await until(() => !worker.isActive);
        child.send({ op: 'close' });
        await until(() => messages.some((m) => m.code === 'SDK_BRIDGE_CLOSED'));
        evidence.push({
          code: 'SDK_TRUE_PG_BRIDGE',
          ...messages.find((m) => m.code === 'SDK_BRIDGE_CLOSED'),
        });
      } finally {
        if (child.connected) {
          child.send({ op: 'close' });
          await until(() =>
            messages.some((m) => m.code === 'SDK_BRIDGE_CLOSED'),
          ).catch(() => child.kill('SIGKILL'));
        }
        evidence.push({ code: 'SDK_BRIDGE_FINAL_MESSAGES', messages });
        await app.close();
      }
    });
    for (const beforePermit of [true, false])
      it(`real SIGKILL ${beforePermit ? 'after reservation before permit (0POST)' : 'after server received unique POST (1POST)'} never replays unknown`, async () => {
        await control('open');
        const p = await create();
        respond = () => {};
        const child = fork(
          resolve(
            'src/cloud-workflow/cloud-workflow.private-process.fixture.ts',
          ),
          [],
          {
            execArgv: [
              '-r',
              require.resolve('ts-node/register/transpile-only'),
            ],
            env: {
              ...process.env,
              C3B_CHILD_BEFORE_PERMIT: beforePermit ? '1' : '0',
            },
            silent: true,
          },
        );
        children.push(child);
        const messages: Array<Record<string, unknown>> = [];
        child.on('message', (m) => messages.push(m as Record<string, unknown>));
        await until(() =>
          messages.some((m) => m.code === 'CHILD_PRIVATE_READY'),
        );
        const childPort = messages.find(
          (m) => m.code === 'CHILD_PRIVATE_READY',
        )!.port;
        const r = await fetch(
          `http://127.0.0.1:${String(childPort)}/_cloud/control`,
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ op: 'kick', epoch: '1' }),
          },
        );
        expect(r.status).toBe(200);
        if (beforePermit)
          await until(() =>
            messages.some(
              (m) => m.code === 'RESERVATION_COMMITTED_BEFORE_PERMIT',
            ),
          );
        else await until(() => posts.length === 1);
        const exit = new Promise<string | null>((res) =>
          child.once('exit', (_, signal) => res(signal)),
        );
        child.kill('SIGKILL');
        expect(await exit).toBe('SIGKILL');
        if (!beforePermit) await until(() => posts[0].disconnected);
        expect(posts).toHaveLength(beforePermit ? 0 : 1);
        const reserved = await db.query<
          Array<{ state: string; send_authorized_at: Date | null }>
        >(
          'SELECT state,send_authorized_at FROM cloud_workflow_attempts WHERE parent_id=$1',
          [p.id],
        );
        expect(reserved).toHaveLength(1);
        expect(reserved[0].state).toBe('dispatched');
        expect(reserved[0].send_authorized_at === null).toBe(beforePermit);
        await db.query(
          `UPDATE cloud_workflow_parents SET lease_expires_at=clock_timestamp()-interval '1 second' WHERE id=$1`,
          [p.id],
        );
        await db.query(
          `UPDATE cloud_workflow_slot SET expires_at=clock_timestamp()-interval '1 second'`,
        );
        await control('kick');
        await until(async () => (await parent(p.id)).state === 'paused');
        await until(() => !worker.isActive);
        expect(posts).toHaveLength(beforePermit ? 0 : 1);
        expect(await store.results(1, p.id)).toHaveLength(0);
        const [a] = await db.query<Array<{ state: string }>>(
          'SELECT state FROM cloud_workflow_attempts WHERE parent_id=$1',
          [p.id],
        );
        expect(a.state).toBe('unknown');
        expect((await parent(p.id)).attempts_used).toBe(1);
        evidence.push({
          code: 'TRUE_CHILD_SIGKILL',
          beforePermit,
          pid: child.pid,
          signal: 'SIGKILL',
          messages,
          modelPosts: posts.length,
        });
      });
    it('true PG backend termination during held heartbeat aborts real HTTP; recovered kick never replays', async () => {
      await control('open');
      const p = await create();
      respond = () => {};
      await control('kick');
      await until(() => posts.length === 1);
      const q = db.createQueryRunner();
      runners.push(q);
      await q.connect();
      await q.startTransaction();
      await q.query('SELECT pg_advisory_xact_lock(178404,1)');
      let pid = 0;
      await until(async () => {
        const [r] = await db.query<Array<{ pid: number }>>(
          `SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%pg_advisory_xact_lock%' AND pid<>pg_backend_pid()`,
        );
        pid = r?.pid ?? 0;
        return pid > 0;
      });
      expect(
        (
          await db.query<Array<{ stopped: boolean }>>(
            'SELECT pg_terminate_backend($1) stopped',
            [pid],
          )
        )[0].stopped,
      ).toBe(true);
      await q.rollbackTransaction();
      await until(() => !worker.isActive);
      await until(() => posts[0].disconnected);
      expect(posts).toHaveLength(1);
      expect(await store.results(1, p.id)).toHaveLength(0);
      await control('kick');
      await until(() => !worker.isActive);
      expect(posts).toHaveLength(1);
      evidence.push({ code: 'REAL_PG_CONNECTION_TERMINATED', pid, posts: 1 });
    });
    it('actual Nest shutdown waits a lock-blocked control SQL to settle before pool close', async () => {
      const q = db.createQueryRunner();
      runners.push(q);
      await q.connect();
      await q.startTransaction();
      await q.query('SELECT pg_advisory_xact_lock(178404,1)');
      const request = control('open');
      await until(
        async () =>
          Number(
            (
              await db.query<Array<{ count: string }>>(
                `SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock'`,
              )
            )[0].count,
          ) > 0,
      );
      const module = await Test.createTestingModule({
        providers: [
          { provide: CloudWorkflowPrivateRuntime, useValue: runtime },
          { provide: CloudWorkflowWorker, useValue: worker },
          { provide: CloudWorkflowExecutionStore, useValue: store },
        ],
      }).compile();
      const app = module.createNestApplication();
      await app.init();
      let settled = false;
      const response = request.then(
        () => (settled = true),
        () => (settled = true),
      );
      await app.close();
      await response;
      expect(settled).toBe(true);
      await expect(store.schedulerStatus()).rejects.toThrow('closed');
      await q.rollbackTransaction();
      evidence.push({ code: 'NEST_LOCKED_SQL_SETTLED_BEFORE_POOL_CLOSE' });
    });
    it('close during listen waits initialization and permanently rejects restart', async () => {
      const secondary = CloudWorkflowPrivateRuntime.synthetic(
        store,
        worker,
        new TokenAuthenticationService({} as Repository<User>),
        new SyntheticReady(),
      );
      const pending = secondary.listen(0, '127.0.0.1');
      const rejected = expect(pending).rejects.toThrow('closed');
      const close = secondary.beforeApplicationShutdown();
      await rejected;
      await close;
      await secondary.beforeApplicationShutdown();
      await expect(secondary.listen(0, '127.0.0.1')).rejects.toThrow(
        'disabled',
      );
      expect(posts).toHaveLength(0);
    });
  },
);
