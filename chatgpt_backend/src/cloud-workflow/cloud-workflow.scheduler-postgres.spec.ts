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
import {
  runMigrationsWithAdvisoryLock,
  revertLastMigrationWithAdvisoryLock,
} from '../database/migration-runner';
import { CloudWorkflowStore } from './cloud-workflow.store';
import { CloudWorkflowSchedulerStore } from './cloud-workflow.scheduler-store';
import { CloudWorkflowService } from './cloud-workflow.service';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import { fixturePayload } from './cloud-workflow.fixture';
import {
  parseCloudPayload,
  type CloudAuthorization,
} from './cloud-workflow.contract';
import { schedulerEpoch } from './cloud-workflow.scheduler-gate';
import {
  CloudScheduler,
  type SchedulerState,
} from '../../../cloudflare/backend/src/cloud-scheduler';

const pg = process.env.CLOUD_C3A_PG_TEST === '1' ? describe : describe.skip;
pg(
  'C3a authoritative gate private PostgreSQL lock barriers (model POST0)',
  () => {
    jest.setTimeout(15000);
    let db: DataSource,
      store: CloudWorkflowStore,
      gate: CloudWorkflowSchedulerStore,
      verified = false;
    const evidence: unknown[] = [],
      runners: QueryRunner[] = [];
    const auth = (userId = 1): CloudAuthorization => ({
      userId,
      securityVersion: 3,
      expiresAt: Date.now() + 600000,
    });
    const create = (userId = 1, epoch = '1', payload = fixturePayload()) =>
      store.create(auth(userId), parseCloudPayload(payload), Date.now, {
        epoch,
      });
    const counts = (): Promise<
      Array<{
        parents: number;
        operations: number;
        attempts: number;
        events: number;
      }>
    > =>
      db.query(`SELECT (SELECT count(*)::int FROM cloud_workflow_parents) parents,
    (SELECT count(*)::int FROM cloud_workflow_operations) operations,(SELECT count(*)::int FROM cloud_workflow_attempts) attempts,
    (SELECT count(*)::int FROM cloud_workflow_events) events`);
    async function lock(key = 1) {
      const q = db.createQueryRunner();
      runners.push(q);
      await q.connect();
      await q.startTransaction();
      await q.query('SELECT pg_advisory_xact_lock($1,$2)', [
        key === 1 ? 178404 : 178406,
        key,
      ]);
      return q;
    }
    async function waiting(n: number) {
      const end = Date.now() + 1200;
      for (;;) {
        const [{ count }] = await db.query<
          Array<{ count: number }>
        >(`SELECT count(*)::int count FROM pg_stat_activity WHERE datname=current_database()
        AND usename=current_user AND wait_event_type='Lock'`);
        if (count >= n) {
          evidence.push({ code: 'REAL_PG_LOCK_WAIT', count });
          return;
        }
        if (Date.now() >= end) throw Error('real_lock_barrier_not_observed');
        await new Promise((r) => setTimeout(r, 5));
      }
    }
    beforeAll(async () => {
      const e = process.env,
        nonce = e.CLOUD_PG_NONCE,
        socket = e.CLOUD_PG_SOCKET;
      if (
        !nonce ||
        !socket?.startsWith('/tmp/chatai-cloud-C3a-') ||
        !e.CLOUD_PG_DATA_DIRECTORY?.startsWith('/tmp/chatai-cloud-C3a-') ||
        e.CLOUD_PG_DATABASE !== `chatai_cloud_test_${nonce}` ||
        e.CLOUD_PG_USER !== `cloud_${nonce}` ||
        !e.CLOUD_PG_PORT
      )
        throw Error('private_nonce_configuration_required');
      expect(
        (
          JSON.parse(
            readFileSync(`${socket}/fixture-sentinel.json`, 'utf8'),
          ) as { nonce: string }
        ).nonce,
      ).toBe(nonce);
      db = new DataSource({
        type: 'postgres',
        host: socket,
        port: Number(e.CLOUD_PG_PORT),
        database: e.CLOUD_PG_DATABASE,
        username: e.CLOUD_PG_USER,
        password: '',
        synchronize: false,
        logging: false,
        extra: { max: 8, connectionTimeoutMillis: 3000 },
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
        `SELECT current_database() database,current_setting('data_directory') directory,current_user username,inet_server_addr()::text address`,
      );
      expect(identity).toEqual({
        database: e.CLOUD_PG_DATABASE,
        directory: e.CLOUD_PG_DATA_DIRECTORY,
        username: e.CLOUD_PG_USER,
        address: null,
      });
      verified = true;
      evidence.push({ code: 'PRIVATE_IDENTITY', ...identity, nonce });
      await db.query('CREATE TABLE fixture_sentinel(nonce text PRIMARY KEY)');
      await db.query('INSERT INTO fixture_sentinel VALUES($1)', [nonce]);
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(7);
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(0);
      evidence.push({
        code: 'SHARED_RUNNER',
        apply: 7,
        noop: 0,
        productionCli: false,
      });
      store = new CloudWorkflowStore(db);
      gate = new CloudWorkflowSchedulerStore(db);
    });
    beforeEach(async () => {
      if (!verified) throw Error('identity_not_verified');
      await db.query('DELETE FROM cloud_workflow_parents');
      await db.query(
        'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL',
      );
      await db.query(
        'UPDATE cloud_workflow_scheduler_gate SET epoch=0,accepting=false WHERE id=1',
      );
      await db.query(
        `INSERT INTO users(id,"userName","tokenVersion",banned) VALUES(1,'synthetic1',3,false),(2,'synthetic2',3,false) ON CONFLICT(id) DO UPDATE SET "tokenVersion"=3,banned=false`,
      );
      await db.query(
        `INSERT INTO ai_providers(id,code,"displayName","apiKey","baseUrl") VALUES(1,'synthetic','synthetic','synthetic-only','http://127.0.0.1:1') ON CONFLICT(id) DO UPDATE SET enabled=true,"apiKey"='synthetic-only'`,
      );
      await db.query(
        `INSERT INTO ai_models(id,"providerId","modelId","displayName") VALUES(1,1,'synthetic','synthetic') ON CONFLICT(id) DO UPDATE SET enabled=true`,
      );
      await gate.open('1');
    });
    afterEach(async () => {
      for (const q of runners.splice(0)) {
        if (q.isTransactionActive) await q.rollbackTransaction();
        if (!q.isReleased) await q.release();
      }
      if (!verified) return;
      await db.query(
        'DROP TRIGGER IF EXISTS c3a_hold ON cloud_workflow_parents',
      );
      await db.query('DROP FUNCTION IF EXISTS c3a_hold_fn()');
      evidence.push({
        test: expect.getState().currentTestName,
        gate: await gate.status(),
        counts: await counts(),
        modelPosts: 0,
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

    it('fresh gate closed seed, protected down rejects open/pending then down/up affects only gate', async () => {
      const originalUsers = await db.query<unknown[]>(
        'SELECT id,"tokenVersion" FROM users ORDER BY id',
      );
      await expect(revertLastMigrationWithAdvisoryLock(db)).rejects.toThrow(
        'closed_idle',
      );
      const p = await create();
      await db.query(
        'UPDATE cloud_workflow_scheduler_gate SET accepting=false',
      );
      await expect(revertLastMigrationWithAdvisoryLock(db)).rejects.toThrow(
        'closed_idle',
      );
      expect((await counts())[0].parents).toBe(1);
      await store.control(auth(), p.id, 'stop', {
        operationId: randomUUID(),
        expectedRevision: p.revision,
      });
      const rows = await db.query<unknown[]>(
        'SELECT * FROM cloud_workflow_parents',
      );
      await revertLastMigrationWithAdvisoryLock(db);
      expect(await db.query('SELECT * FROM cloud_workflow_parents')).toEqual(
        rows,
      );
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(1);
      expect(await gate.status()).toEqual({
        epoch: '0',
        accepting: false,
        work: 'idle',
      });
      expect(
        await db.query('SELECT id,"tokenVersion" FROM users ORDER BY id'),
      ).toEqual(originalUsers);
    });
    it('missing context/closed/wrong epoch/invalid decimal cannot create; no budget or receipts', async () => {
      await expect(store.create(auth(), fixturePayload())).rejects.toThrow(
        'context_required',
      );
      await expect(create(1, '2')).rejects.toThrow('closed_or_stale');
      for (const value of ['01', '-1', '1.0', '9223372036854775808'])
        expect(() => schedulerEpoch(value)).toThrow();
      await gate.closeIfIdle('1');
      await expect(create()).rejects.toThrow('closed_or_stale');
      expect((await counts())[0]).toEqual({
        parents: 0,
        operations: 0,
        attempts: 0,
        events: 0,
      });
    });
    it('missing row/table fail closed without recreation or user mutation', async () => {
      await db.query('DELETE FROM cloud_workflow_scheduler_gate');
      await expect(create()).rejects.toThrow('missing');
      expect((await counts())[0].parents).toBe(0);
      await db.query(
        'INSERT INTO cloud_workflow_scheduler_gate VALUES(1,1,true)',
      );
      await db.query(
        'ALTER TABLE cloud_workflow_scheduler_gate RENAME TO c3a_missing',
      );
      try {
        await expect(create()).rejects.toThrow('does not exist');
      } finally {
        await db.query(
          'ALTER TABLE c3a_missing RENAME TO cloud_workflow_scheduler_gate',
        );
      }
    });
    it('public service even synthetic-ready cannot acquire absent internal context', async () => {
      class Ready extends CloudWorkflowReadiness {
        capabilities() {
          return { ...super.capabilities(), available: true };
        }
      }
      await expect(
        new CloudWorkflowService(store, new Ready()).create(
          auth(),
          fixturePayload(),
        ),
      ).rejects.toThrow('context_required');
      expect((await counts())[0].parents).toBe(0);
    });
    it('pre-arm storage scheduling failure yields zero PG open/admissions and no budgets', async () => {
      await gate.closeIfIdle('1');
      let state: SchedulerState | null = null,
        opens = 0;
      const scheduler = new CloudScheduler(
        {
          read: () => Promise.resolve(structuredClone(state)),
          mutate: (f) => {
            const change = f(structuredClone(state));
            state = structuredClone(change.state);
            return Promise.resolve(change.result);
          },
        },
        {
          ensure: () =>
            Promise.reject(Error('synthetic_schedule_write_failed')),
          exists: () => Promise.resolve(false),
          cancel: () => Promise.resolve(),
        },
        {
          open: async (g) => {
            opens++;
            return gate.open(g);
          },
          status: () => gate.status(),
          closeIfIdle: (g) => gate.closeIfIdle(g),
          kick: () => gate.status(),
        },
        Date.now,
        randomUUID,
      );
      await expect(scheduler.armForAdmission()).rejects.toThrow(
        'schedule_write_failed',
      );
      expect(opens).toBe(0);
      expect((await gate.status()).accepting).toBe(false);
      expect((await counts())[0]).toEqual({
        parents: 0,
        operations: 0,
        attempts: 0,
        events: 0,
      });
    });
    it('close g before delayed open g persists tombstone; newer epochs never rewound', async () => {
      await db.query(
        'UPDATE cloud_workflow_scheduler_gate SET epoch=0,accepting=false',
      );
      expect(await gate.closeIfIdle('1')).toEqual({
        epoch: '1',
        accepting: false,
        work: 'idle',
      });
      await expect(gate.open('1')).rejects.toThrow('closed_or_stale');
      await gate.open('2');
      expect(await gate.closeIfIdle('1')).toEqual({
        epoch: '2',
        accepting: true,
        work: 'idle',
      });
      await expect(gate.open('1')).rejects.toThrow('stale');
      await gate.open('9007199254740993');
      expect((await gate.status()).epoch).toBe('9007199254740993');
    });
    it('open/close acknowledged-unknown commits only reconcile by exact epoch, same closed g cannot reopen', async () => {
      await expect(
        gate.open('2').then(() => {
          throw Error('injected_ack_lost');
        }),
      ).rejects.toThrow('ack_lost');
      expect((await gate.status()).epoch).toBe('2');
      expect(await gate.open('2')).toEqual({ epoch: '2', accepting: true });
      await expect(
        gate.closeIfIdle('2').then(() => {
          throw Error('injected_ack_lost');
        }),
      ).rejects.toThrow('ack_lost');
      expect(await gate.closeIfIdle('2')).toEqual({
        epoch: '2',
        accepting: false,
        work: 'idle',
      });
      await expect(gate.open('2')).rejects.toThrow('closed');
    });
    for (const kind of ['create', 'continue'] as const)
      it(`${kind} obtains lock only after close: no new row/receipt`, async () => {
        const p = kind === 'continue' ? await create() : null;
        if (p)
          await db.query(
            "UPDATE cloud_workflow_parents SET state='paused' WHERE id=$1",
            [p.id],
          );
        const before = await counts(),
          held = await lock();
        const closing = gate.closeIfIdle('1');
        await waiting(1);
        const writing = p
          ? store.control(
              auth(),
              p.id,
              'continue',
              { operationId: randomUUID(), expectedRevision: p.revision },
              600000,
              Date.now,
              { epoch: '1' },
            )
          : create();
        const outcome = Promise.allSettled([writing]);
        await waiting(2);
        await held.commitTransaction();
        await closing;
        expect((await outcome)[0].status).toBe('rejected');
        expect(await counts()).toEqual(before);
        expect((await gate.status()).accepting).toBe(false);
      });
    for (const kind of ['create', 'continue'] as const)
      it(`${kind} holds lock before close, lost commit response still leaves work visible`, async () => {
        const p = kind === 'continue' ? await create() : null;
        if (p)
          await db.query(
            "UPDATE cloud_workflow_parents SET state='paused' WHERE id=$1",
            [p.id],
          );
        await db.query(
          `CREATE FUNCTION c3a_hold_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.state='queued' THEN PERFORM pg_advisory_xact_lock(178406,5); END IF; RETURN NEW; END $$`,
        );
        await db.query(
          'CREATE TRIGGER c3a_hold BEFORE INSERT OR UPDATE ON cloud_workflow_parents FOR EACH ROW EXECUTE FUNCTION c3a_hold_fn()',
        );
        const held = await lock(5);
        const mutation = (
          p
            ? store.control(
                auth(),
                p.id,
                'continue',
                { operationId: randomUUID(), expectedRevision: p.revision },
                600000,
                Date.now,
                { epoch: '1' },
              )
            : create()
        ).then(() => {
          throw Error('injected_ack_lost');
        });
        const outcome = Promise.allSettled([mutation]);
        await waiting(1);
        const closing = gate.closeIfIdle('1');
        await waiting(2);
        await held.commitTransaction();
        expect((await outcome)[0].status).toBe('rejected');
        expect(await closing).toEqual({
          epoch: '1',
          accepting: true,
          work: 'pending',
        });
        expect((await counts())[0].parents).toBe(1);
      });
    it('old create and continue receipts exact when gate closed, new operations rejected', async () => {
      const payload = fixturePayload(),
        p = await create(1, '1', payload);
      await db.query(
        "UPDATE cloud_workflow_parents SET state='paused' WHERE id=$1",
        [p.id],
      );
      const op = { operationId: randomUUID(), expectedRevision: p.revision },
        receipt = await store.control(
          auth(),
          p.id,
          'continue',
          op,
          600000,
          Date.now,
          { epoch: '1' },
        );
      await db.query(
        "UPDATE cloud_workflow_parents SET state='paused' WHERE id=$1",
        [p.id],
      );
      await gate.closeIfIdle('1');
      const before = await counts();
      expect(await store.control(auth(), p.id, 'continue', op, 600000)).toEqual(
        receipt,
      );
      expect(await store.create(auth(), payload)).toEqual(
        (await store.detail(1, p.id)).parent,
      );
      expect(await counts()).toEqual(before);
      await expect(
        store.control(
          auth(),
          p.id,
          'continue',
          { operationId: randomUUID(), expectedRevision: receipt.revision },
          600000,
          Date.now,
          { epoch: '1' },
        ),
      ).rejects.toThrow('closed');
    });
    it('expired queued head claim null is not idle: valid later task still pending', async () => {
      const p = await create(),
        q = await create(2);
      await db.query(
        "UPDATE cloud_workflow_parents SET created_at=now()-interval '1 hour',grant_expires_at=now()-interval '1 second' WHERE id=$1",
        [p.id],
      );
      expect(await store.claim(randomUUID())).toBeNull();
      expect((await gate.closeIfIdle('1')).work).toBe('pending');
      expect((await store.claim(randomUUID()))?.parentId).toBe(q.id);
    });
    it('running/expired slot/unfinished dispatch all block idle; unknown paused does not requeue', async () => {
      const p = await create(),
        claimed = (await store.claim(randomUUID()))!;
      expect(claimed.parentId).toBe(p.id);
      expect((await gate.closeIfIdle('1')).work).toBe('busy');
      await db.query(
        "UPDATE cloud_workflow_parents SET state='paused'; UPDATE cloud_workflow_slot SET expires_at=now()-interval '1 second'",
      );
      expect((await gate.status()).work).toBe('busy');
      await db.query('UPDATE cloud_workflow_slot SET parent_id=NULL');
      const [{ id }] = await db.query<Array<{ id: string }>>(
        "SELECT id FROM cloud_workflow_steps WHERE parent_id=$1 AND role='analysis'",
        [p.id],
      );
      await db.query(
        "INSERT INTO cloud_workflow_attempts(id,parent_id,owner_id,step_id,number,state,fence,estimated_tokens) VALUES($1,$2,1,$3,1,'dispatched',1,20)",
        [randomUUID(), p.id, id],
      );
      expect((await gate.status()).work).toBe('busy');
      await db.query(
        "UPDATE cloud_workflow_attempts SET state='unknown'; UPDATE cloud_workflow_parents SET reason='unknown'",
      );
      expect(await gate.closeIfIdle('1')).toEqual({
        epoch: '1',
        accepting: false,
        work: 'idle',
      });
      expect(await store.claim(randomUUID())).toBeNull();
    });
    it('real lock timeout is a rejection, never an idle acknowledgment', async () => {
      const held = await lock(),
        request = gate.status(),
        rejected = expect(request).rejects.toThrow();
      await waiting(1);
      await rejected;
      await held.rollbackTransaction();
      expect((await gate.status()).accepting).toBe(true);
    });
    it('missing singleton slot is unknown, never idle or safe migration-down', async () => {
      await db.query('DELETE FROM cloud_workflow_slot');
      try {
        await expect(gate.status()).rejects.toThrow('activity_unknown');
        await expect(gate.closeIfIdle('1')).rejects.toThrow('activity_unknown');
        await db.query(
          'UPDATE cloud_workflow_scheduler_gate SET accepting=false',
        );
        await expect(revertLastMigrationWithAdvisoryLock(db)).rejects.toThrow(
          'activity_unknown',
        );
      } finally {
        await db.query('INSERT INTO cloud_workflow_slot(id) VALUES(1)');
      }
    });
    it('gate preserves owner concurrent limit, auth/profile and unknown no-replay checks', async () => {
      const both = await Promise.allSettled([create(), create()]);
      expect(both.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
      await db.query('UPDATE users SET banned=true WHERE id=2');
      await expect(create(2)).rejects.toThrow('登录授权');
      await db.query('UPDATE users SET banned=false WHERE id=2');
      await db.query('UPDATE ai_models SET enabled=false WHERE id=1');
      await expect(create(2)).rejects.toThrow('模型不可用');
    });
  },
);
