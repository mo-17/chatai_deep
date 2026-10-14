import { DataSource } from 'typeorm';
import { Test } from '@nestjs/testing';
import type { Server } from 'node:http';
import request from 'supertest';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { AddAppVersionSha2561784020000000 } from '../migrations/1784020000000-AddAppVersionSha256';
import { runMigrationsWithAdvisoryLock } from '../database/migration-runner';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { CreateCloudWorkflows1784040000000 } from '../migrations/1784040000000-CreateCloudWorkflows';
import { AddCloudDispatchPermit1784050000000 } from '../migrations/1784050000000-AddCloudDispatchPermit';
import { AddCloudSchedulerGate1784060000000 } from '../migrations/1784060000000-AddCloudSchedulerGate';
import { User } from '../user/user.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { JWT_SECRET } from '../auth/jwt.const';
import * as jwt from 'jsonwebtoken';
import {
  CloudWorkflowStore,
  CloudFence,
  CloudParent,
} from './cloud-workflow.store';
import { CloudWorkflowService } from './cloud-workflow.service';
import { CloudWorkflowGuard } from './cloud-workflow.guard';
import { CloudWorkflowController } from './cloud-workflow.controller';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import {
  CloudAuthorization,
  hashText,
  parseCloudPayload,
} from './cloud-workflow.contract';
import {
  fixturePayload,
  SyntheticAdmittedStore,
} from './cloud-workflow.fixture';

const pg = process.env.CLOUD_PG_TEST === '1' ? describe : describe.skip;
/** 测试唯一显式ready桩；不注册到生产模块、不启动worker/HTTP上游。 */
class SyntheticReady extends CloudWorkflowReadiness {
  capabilities() {
    return {
      ...super.capabilities(),
      available: true,
      reason: 'synthetic_control_plane_only',
    };
  }
}
pg(
  'cloud workflow isolated PostgreSQL transactions (no model dispatch)',
  () => {
    jest.setTimeout(20000);
    let db: DataSource,
      store: CloudWorkflowStore,
      service: CloudWorkflowService;
    let identityVerified = false;
    const now = Date.now();
    const a: CloudAuthorization = {
      userId: 1,
      securityVersion: 3,
      expiresAt: now + 600000,
    };
    const b: CloudAuthorization = {
      userId: 2,
      securityVersion: 3,
      expiresAt: now + 600000,
    };
    const evidence: Record<string, unknown>[] = [];
    beforeAll(async () => {
      const {
        CLOUD_PG_SOCKET: socket,
        CLOUD_PG_PORT: port,
        CLOUD_PG_DATABASE: database,
        CLOUD_PG_DATA_DIRECTORY: dataDir,
        CLOUD_PG_NONCE: nonce,
        CLOUD_PG_USER: username,
      } = process.env;
      if (
        !socket ||
        !socket.startsWith('/tmp/chatai-cloud-C0-') ||
        !dataDir ||
        !dataDir.startsWith('/tmp/chatai-cloud-C0-') ||
        !nonce ||
        database !== `chatai_cloud_test_${nonce}` ||
        username !== `cloud_${nonce}` ||
        !port
      )
        throw Error('拒绝非本次隔离PG配置');
      const sentinel = JSON.parse(
        readFileSync(`${socket}/fixture-sentinel.json`, 'utf8'),
      ) as { nonce: string };
      expect(sentinel.nonce).toBe(nonce);
      db = new DataSource({
        type: 'postgres',
        host: socket,
        port: Number(port),
        database,
        username,
        password: '',
        synchronize: false,
        logging: false,
        entities: [User, AiProvider, AiModel],
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
      expect(identity).toEqual({
        database,
        directory: dataDir,
        username,
        address: null,
      });
      identityVerified = true;
      evidence.push({ code: 'ISOLATED_IDENTITY', ...identity, nonce });
      await db.query('CREATE TABLE fixture_sentinel(nonce text PRIMARY KEY)');
      await db.query('INSERT INTO fixture_sentinel VALUES($1)', [nonce]);
      const applied = await runMigrationsWithAdvisoryLock(db);
      expect(applied).toHaveLength(7);
      expect(await runMigrationsWithAdvisoryLock(db)).toHaveLength(0);
      evidence.push({
        code: 'SEVEN_MIGRATION_RUNNER',
        applied: 7,
        noOp: 0,
        message: 'Applied 7 migration(s)',
        dataSource:
          'explicit private socket; no dotenv/default data-source import',
      });
      store = new SyntheticAdmittedStore(db, { epoch: '1' });
      service = new CloudWorkflowService(store, new SyntheticReady());
    });
    beforeEach(async () => {
      if (!identityVerified) throw Error('PG身份未核验，拒绝任何测试写入');
      await db.query('DELETE FROM cloud_workflow_parents');
      await db.query(
        'UPDATE cloud_workflow_scheduler_gate SET epoch=1,accepting=true WHERE id=1',
      );
      await db.query('DELETE FROM users WHERE id IN (1,2,3)');
      await db.query(
        'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL',
      );
      await db.query(
        `INSERT INTO users(id,"userName","tokenVersion") VALUES(1,'cloud-fixture-a',3),(2,'cloud-fixture-b',3),(3,'cloud-fixture-c',3)`,
      );
      await db.query(
        `INSERT INTO ai_providers(id,code,"displayName","apiKey","baseUrl") VALUES(1,'fixture','synthetic','synthetic-provider-key','http://127.0.0.1:1') ON CONFLICT(id) DO UPDATE SET enabled=true,"apiKey"='synthetic-provider-key'`,
      );
      await db.query(
        `INSERT INTO ai_models(id,"providerId","modelId","displayName") VALUES(1,1,'synthetic','synthetic') ON CONFLICT(id) DO UPDATE SET enabled=true`,
      );
    });
    afterEach(async () => {
      if (!identityVerified) return;
      await db.query(
        'DROP TRIGGER IF EXISTS fixture_fail_result ON cloud_workflow_results',
      );
      await db.query('DROP FUNCTION IF EXISTS fixture_fail_result()');
    });
    afterAll(async () => {
      if (db?.isInitialized) await db.destroy();
      if (process.env.CLOUD_PG_EVIDENCE)
        writeFileSync(
          process.env.CLOUD_PG_EVIDENCE,
          JSON.stringify(
            {
              stage: 'C0+C1a',
              runtime:
                'synthetic readiness / direct PG method calls; no HTTP model',
              modelPosts: 0,
              evidence,
            },
            null,
            2,
          ) + '\n',
        );
    });
    const create = (auth = a, p = fixturePayload()) =>
      store.create(auth, parseCloudPayload(p), () => now);
    const current = async (owner: number, id: string) =>
      (await store.detail(owner, id)).parent;
    const step = async (f: CloudFence, role = 'analysis') => {
      const [{ id }] = await db.query<Array<{ id: string }>>(
        'SELECT id FROM cloud_workflow_steps WHERE owner_id=$1 AND parent_id=$2 AND role=$3',
        [f.ownerId, f.parentId, role],
      );
      return id;
    };
    it('显式迁移down/up闭环，普通用户/服务商和sentinel不变', async () => {
      const before = await db.query<unknown[]>(
        'SELECT * FROM users ORDER BY id',
      );
      await db.query(
        'UPDATE cloud_workflow_scheduler_gate SET accepting=false WHERE id=1',
      );
      await db.undoLastMigration();
      await db.undoLastMigration();
      await db.undoLastMigration();
      expect(
        await db.query(
          "SELECT tablename FROM pg_tables WHERE tablename LIKE 'cloud_workflow_%'",
        ),
      ).toHaveLength(0);
      expect(await db.runMigrations()).toHaveLength(3);
      expect(await db.query('SELECT * FROM users ORDER BY id')).toEqual(before);
      expect(await db.query('SELECT nonce FROM fixture_sentinel')).toHaveLength(
        1,
      );
    });
    it('同key并发同body一父三节点/异body409，所有DTO定位仍归JWT owner', async () => {
      const p = fixturePayload();
      const [left, right] = await Promise.all([create(a, p), create(a, p)]);
      expect(left.id).toBe(right.id);
      expect(
        await db.query('SELECT id FROM cloud_workflow_parents'),
      ).toHaveLength(1);
      expect(
        await db.query('SELECT id FROM cloud_workflow_steps'),
      ).toHaveLength(3);
      await expect(create(a, { ...p, task: 'different' })).rejects.toThrow(
        '幂等键',
      );
      evidence.push({
        code: 'IDEMPOTENCY',
        parent: left.id,
        parents: 1,
        steps: 3,
        payloadHash: left.payload_hash,
      });
    });
    it('同owner两不同key并发只准一父，其他owner可排队且claim全局只有一槽', async () => {
      const settled = await Promise.allSettled([create(), create()]);
      expect(settled.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
      await create(b);
      const claims = await Promise.all([
        store.claim(randomUUID(), () => now),
        store.claim(randomUUID(), () => now),
      ]);
      expect(claims.filter(Boolean)).toHaveLength(1);
      expect(
        await db.query(
          "SELECT id FROM cloud_workflow_parents WHERE state='running'",
        ),
      ).toHaveLength(1);
    });
    it('全局队列硬上限，失败不留额外任务', async () => {
      await create();
      await db.query(
        `INSERT INTO users(id,"userName","tokenVersion") SELECT x,'cloud-limit-'||x,3 FROM generate_series(101,132) x`,
      );
      for (let id = 101; id <= 131; id++) await create({ ...a, userId: id });
      await expect(create({ ...a, userId: 132 })).rejects.toThrow('队列已满');
      expect(
        await db.query(
          "SELECT id FROM cloud_workflow_parents WHERE state='queued'",
        ),
      ).toHaveLength(32);
      await db.query('DELETE FROM users WHERE id BETWEEN 101 AND 132');
    });
    it('跨owner detail/result/list cursor/所有控制统一404，伪cid不授权', async () => {
      const p = await create(a, {
        ...fixturePayload(),
        source: {
          cid: 2,
          messageId: randomUUID(),
          contentHash: hashText('forged-cid'),
        },
      });
      await expect(store.detail(b.userId, p.id)).rejects.toThrow('任务不存在');
      await expect(store.results(b.userId, p.id)).rejects.toThrow('任务不存在');
      await expect(store.list(b.userId, p.id, 20)).rejects.toThrow(
        '任务不存在',
      );
      expect(await store.list(b.userId, null, 20)).toEqual([]);
      for (const kind of ['stop', 'continue', 'delete'] as const)
        await expect(
          store.control(
            b,
            p.id,
            kind,
            { operationId: randomUUID(), expectedRevision: 1 },
            1000,
            () => now,
          ),
        ).rejects.toThrow('任务不存在');
      expect((await current(a.userId, p.id)).revision).toBe(1);
    });
    it('真实guard授权后TX前安全版本轮换/ban/exp拒绝且0父行', async () => {
      const verify = new TokenAuthenticationService(db.getRepository(User));
      const t = jwt.sign({ userId: 1, tokenVersion: 3 }, JWT_SECRET, {
        algorithm: 'HS256',
        expiresIn: '5m',
      });
      const auth = (await verify.verifyCloud(t))!;
      expect(auth.securityVersion).toBe(3);
      await db.query('UPDATE users SET "tokenVersion"=4 WHERE id=1');
      await expect(create(auth)).rejects.toThrow('登录授权');
      await db.query(
        'UPDATE users SET "tokenVersion"=3,banned=true WHERE id=1',
      );
      await expect(create(a)).rejects.toThrow('登录授权');
      await db.query('UPDATE users SET banned=false WHERE id=1');
      await expect(create({ ...a, expiresAt: now })).rejects.toThrow(
        '登录授权',
      );
      expect(
        await db.query('SELECT id FROM cloud_workflow_parents'),
      ).toHaveLength(0);
    });
    it('grant取JWT/明确期限/deadline最小值；记录不含密钥或JWT', async () => {
      const p = await create(
        { ...a, expiresAt: now + 2500 },
        {
          ...fixturePayload(),
          grantDurationMs: 3000,
          budget: { ...fixturePayload().budget, durationMs: 4000 },
        },
      );
      expect(p.grant_expires_at.getTime()).toBe(now + 2500);
      const stored = JSON.stringify(
        await db.query('SELECT * FROM cloud_workflow_parents'),
      );
      expect(stored).not.toContain('synthetic-provider-key');
      expect(stored).not.toContain('127.0.0.1');
    });
    it('stop/delete操作幂等、CAS/操作键重用拒绝、删除tombstone同key不复活', async () => {
      const payload = fixturePayload(),
        p = await create(a, payload),
        op = { operationId: randomUUID(), expectedRevision: p.revision };
      const stopped = await store.control(
        a,
        p.id,
        'stop',
        op,
        undefined,
        () => now,
      );
      await store.control(a, p.id, 'stop', op, undefined, () => now + 10);
      expect((await current(a.userId, p.id)).revision).toBe(stopped.revision);
      expect(
        await db.query(
          "SELECT sequence FROM cloud_workflow_events WHERE code='stop' AND parent_id=$1",
          [p.id],
        ),
      ).toHaveLength(1);
      await expect(
        store.control(a, p.id, 'delete', op, undefined, () => now),
      ).rejects.toThrow('幂等键');
      const deleted = await store.control(
        a,
        p.id,
        'delete',
        { operationId: randomUUID(), expectedRevision: stopped.revision },
        undefined,
        () => now,
      );
      expect(deleted.state).toBe('deleted');
      expect((await current(a.userId, p.id)).payload).toBeNull();
      expect((await create(a, payload)).id).toBe(p.id);
      expect((await create(a, payload)).state).toBe('deleted');
    });
    it('续权明确新操作只改变一次，completed节点不重置，预算不退款', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!;
      const attempt = await store.reserveDispatch(
        f,
        await step(f),
        100,
        () => now,
      );
      await store.finish(
        f,
        attempt,
        'analysis done',
        { input: 50, output: 20 },
        () => now,
      );
      // 合成暂停：真实worker暂停入口在C1b；本批仅测试控制状态事务。
      await db.query(
        "UPDATE cloud_workflow_parents SET state='paused',lease_owner=NULL,lease_expires_at=NULL WHERE id=$1",
        [p.id],
      );
      await db.query('UPDATE cloud_workflow_slot SET parent_id=NULL');
      const old = await current(a.userId, p.id),
        op = { operationId: randomUUID(), expectedRevision: old.revision };
      const next = await store.control(
        a,
        p.id,
        'continue',
        op,
        5000,
        () => now + 1000,
      );
      await store.control(a, p.id, 'continue', op, 5000, () => now + 2000);
      expect((await current(a.userId, p.id)).grant_version).toBe(
        next.grant_version,
      );
      expect(next.attempts_used).toBe(1);
      expect(
        (
          await db.query<Array<{ state: string }>>(
            "SELECT state FROM cloud_workflow_steps WHERE parent_id=$1 AND role='analysis'",
            [p.id],
          )
        )[0].state,
      ).toBe('complete');
      await expect(
        store.control(
          a,
          p.id,
          'continue',
          { operationId: randomUUID(), expectedRevision: old.revision },
          5000,
          () => now,
        ),
      ).rejects.toThrow();
    });
    it('queued未dispatch失租可重领，旧fence零扣减/落盘；续租限于原grant', async () => {
      const p = await create(),
        first = (await store.claim(randomUUID(), () => now))!;
      const renewed = await store.renew(first, () => now + 1000);
      expect(renewed.getTime()).toBe(now + 31000);
      const second = (await store.claim(randomUUID(), () => now + 31001))!;
      expect(second.parentId).toBe(p.id);
      expect(second.fence).not.toBe(first.fence);
      await expect(
        store.reserveDispatch(first, await step(first), 100, () => now + 31002),
      ).rejects.toThrow();
      expect((await current(a.userId, p.id)).attempts_used).toBe(0);
      expect(
        await store.reserveDispatch(
          second,
          await step(second),
          100,
          () => now + 31002,
        ),
      ).toBeTruthy();
    });
    it('dispatch后失租只unknown/费用未知，不能自动第二次请求或continue', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!;
      const attempt = await store.reserveDispatch(
        f,
        await step(f),
        100,
        () => now,
      );
      expect(await store.claim(randomUUID(), () => now + 30001)).toBeNull();
      const live = await current(a.userId, p.id);
      expect(live).toMatchObject({
        state: 'paused',
        attempts_used: 1,
        usage_unknown: true,
      });
      expect(
        (
          await db.query<Array<{ state: string }>>(
            'SELECT state FROM cloud_workflow_attempts WHERE id=$1',
            [attempt],
          )
        )[0].state,
      ).toBe('unknown');
      await expect(
        store.finish(
          f,
          attempt,
          'late',
          { input: 1, output: 1 },
          () => now + 30002,
        ),
      ).rejects.toThrow();
      await expect(
        store.control(
          a,
          p.id,
          'continue',
          { operationId: randomUUID(), expectedRevision: live.revision },
          5000,
          () => now + 30003,
        ),
      ).rejects.toThrow('结果未知');
      evidence.push({
        code: 'LOST_DISPATCH',
        parent: p.id,
        attempt,
        state: 'unknown',
        attemptsUsed: 1,
        modelPosts: 0,
      });
    });
    it('最末reservation重校用户/profile、节点顺序及硬预算', async () => {
      const p = await create(a, {
          ...fixturePayload(),
          budget: { ...fixturePayload().budget, attempts: 1 },
        }),
        f = (await store.claim(randomUUID(), () => now))!;
      await expect(
        store.reserveDispatch(f, await step(f, 'writing'), 100, () => now),
      ).rejects.toThrow();
      await db.query('UPDATE ai_providers SET "apiKey"=$1 WHERE id=1', [
        'changed',
      ]);
      await expect(
        store.reserveDispatch(f, await step(f), 100, () => now),
      ).rejects.toThrow('配置已变化');
      await db.query('UPDATE ai_providers SET "apiKey"=$1 WHERE id=1', [
        'synthetic-provider-key',
      ]);
      await db.query('UPDATE users SET "tokenVersion"=4 WHERE id=1');
      await expect(
        store.reserveDispatch(f, await step(f), 100, () => now),
      ).rejects.toThrow();
      await db.query('UPDATE users SET "tokenVersion"=3 WHERE id=1');
      const attempt = await store.reserveDispatch(
        f,
        await step(f),
        100,
        () => now,
      );
      await store.finish(f, attempt, 'done', null, () => now);
      await expect(
        store.reserveDispatch(f, await step(f, 'writing'), 100, () => now),
      ).rejects.toThrow('预算');
      expect((await current(a.userId, p.id)).attempts_used).toBe(1);
    });
    it('结果TX失败整体回滚，完整已知输出仅重试保存/预算一次', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!,
        attempt = await store.reserveDispatch(f, await step(f), 100, () => now);
      await db.query(
        `CREATE FUNCTION fixture_fail_result() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic write failure'; END $$`,
      );
      await db.query(
        'CREATE TRIGGER fixture_fail_result BEFORE INSERT ON cloud_workflow_results FOR EACH ROW EXECUTE FUNCTION fixture_fail_result()',
      );
      await expect(
        store.finish(
          f,
          attempt,
          'known output',
          { input: 3, output: 5 },
          () => now,
        ),
      ).rejects.toThrow('synthetic write failure');
      expect(
        await db.query('SELECT id FROM cloud_workflow_results'),
      ).toHaveLength(0);
      expect(
        (
          await db.query<Array<{ state: string }>>(
            'SELECT state FROM cloud_workflow_attempts WHERE id=$1',
            [attempt],
          )
        )[0].state,
      ).toBe('dispatched');
      await db.query(
        'DROP TRIGGER fixture_fail_result ON cloud_workflow_results',
      );
      await store.finish(
        f,
        attempt,
        'known output',
        { input: 3, output: 5 },
        () => now,
      );
      await store.finish(
        f,
        attempt,
        'known output',
        { input: 3, output: 5 },
        () => now,
      );
      expect(
        await db.query('SELECT id FROM cloud_workflow_results'),
      ).toHaveLength(1);
      expect((await current(a.userId, p.id)).attempts_used).toBe(1);
      evidence.push({
        code: 'RESULT_SAVE_RETRY',
        attempt,
        budgetReservations: 1,
        resultRows: 1,
        contentHash: hashText('known output'),
        modelPosts: 0,
      });
    });
    it('已知无效review失败而非unknown，明确continue仅重试review且保留原结果证据', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!;
      for (const role of ['analysis', 'writing']) {
        const attempt = await store.reserveDispatch(
          f,
          await step(f, role),
          100,
          () => now,
        );
        await store.finish(
          f,
          attempt,
          role + ' done',
          { input: 2, output: 3 },
          () => now,
        );
      }
      const bad = await store.reserveDispatch(
        f,
        await step(f, 'review'),
        100,
        () => now,
      );
      const paused = await store.finish(
        f,
        bad,
        'not json',
        { input: 2, output: 3 },
        () => now,
      );
      expect(paused.state).toBe('paused');
      expect(
        (
          await db.query<Array<{ state: string }>>(
            'SELECT state FROM cloud_workflow_attempts WHERE id=$1',
            [bad],
          )
        )[0].state,
      ).toBe('failed');
      expect(
        await db.query(
          'SELECT id FROM cloud_workflow_results WHERE attempt_id=$1',
          [bad],
        ),
      ).toHaveLength(1);
      await store.control(
        a,
        p.id,
        'continue',
        { operationId: randomUUID(), expectedRevision: paused.revision },
        5000,
        () => now,
      );
      const second = (await store.claim(randomUUID(), () => now))!,
        valid = await store.reserveDispatch(
          second,
          await step(second, 'review'),
          100,
          () => now,
        );
      const done = await store.finish(
        second,
        valid,
        '{"passed":true,"feedback":"ok"}',
        { input: 2, output: 3 },
        () => now,
      );
      expect(done).toMatchObject({ state: 'complete', attempts_used: 4 });
      expect(
        await db.query(
          "SELECT id FROM cloud_workflow_steps WHERE parent_id=$1 AND state='complete'",
          [p.id],
        ),
      ).toHaveLength(3);
      expect((await current(a.userId, p.id)).publication_id).toBe(
        p.publication_id,
      );
    });
    it('stop先撤权，在途保cancelling/执行槽；删除清正文与结果且迟到不能写', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!,
        attempt = await store.reserveDispatch(f, await step(f), 100, () => now);
      const live = await current(a.userId, p.id);
      const stopping = await store.control(
        a,
        p.id,
        'stop',
        { operationId: randomUUID(), expectedRevision: live.revision },
        undefined,
        () => now,
      );
      expect(stopping.state).toBe('cancelling');
      await create(b);
      expect(await store.claim(randomUUID(), () => now)).toBeNull();
      await expect(
        store.finish(f, attempt, 'late', { input: 1, output: 1 }, () => now),
      ).rejects.toThrow();
      await store.control(
        a,
        p.id,
        'delete',
        { operationId: randomUUID(), expectedRevision: stopping.revision },
        undefined,
        () => now,
      );
      expect((await current(a.userId, p.id)).payload).toBeNull();
      expect(await store.results(a.userId, p.id)).toEqual([]);
      await store.settleRevoked(f, () => now);
      expect(await store.claim(randomUUID(), () => now)).toBeTruthy();
      await expect(
        store.finish(f, attempt, 'later', { input: 1, output: 1 }, () => now),
      ).rejects.toThrow();
    });
    it('role唯一约束真实执行，owner/client撤销不影响别的账号', async () => {
      const p = await create(),
        q = await create(b);
      await expect(
        db.query(
          "INSERT INTO cloud_workflow_steps(id,parent_id,owner_id,role,ordinal,provider_id,model_row_id,profile_hash) VALUES($1,$2,2,'analysis',0,1,1,$3)",
          [randomUUID(), p.id, '0'.repeat(64)],
        ),
      ).rejects.toThrow();
      await store.revokeClient(
        a,
        p.payload!.clientInstanceId,
        randomUUID(),
        () => now,
      );
      expect((await current(a.userId, p.id)).state).toBe('cancelled');
      expect((await current(b.userId, q.id)).state).toBe('queued');
      const disabled = new CloudWorkflowService(
        store,
        new CloudWorkflowReadiness(),
      );
      await expect(disabled.detail(a, p.id)).resolves.toBeTruthy();
      expect(() => disabled.create(a, fixturePayload())).toThrow('尚未就绪');
      expect(await service.list(a, undefined, '1')).toMatchObject({
        nextCursor: null,
      });
    });
    it('真实JWT→localhost HTTP→隔离PG，管理员也不跨owner，未知字段零插入', async () => {
      const module = await Test.createTestingModule({
        controllers: [CloudWorkflowController],
        providers: [
          CloudWorkflowService,
          CloudWorkflowGuard,
          { provide: CloudWorkflowStore, useValue: store },
          { provide: CloudWorkflowReadiness, useValue: new SyntheticReady() },
          {
            provide: TokenAuthenticationService,
            useValue: new TokenAuthenticationService(db.getRepository(User)),
          },
        ],
      }).compile();
      const app = module.createNestApplication();
      try {
        await app.listen(0, '127.0.0.1');
        const http = app.getHttpServer() as Server;
        const token = (userId: number) =>
          jwt.sign({ userId, tokenVersion: 3 }, JWT_SECRET, {
            algorithm: 'HS256',
            expiresIn: '5m',
          });
        const p = fixturePayload();
        await request(http)
          .post('/uapi/cloud-workflows')
          .set('Authorization', `Bearer ${token(1)}`)
          .send({ ...p, ownerId: 2 })
          .expect(400);
        expect(
          await db.query<unknown[]>('SELECT id FROM cloud_workflow_parents'),
        ).toHaveLength(0);
        const res = await request(http)
          .post('/uapi/cloud-workflows')
          .set('Authorization', `Bearer ${token(1)}`)
          .send(p)
          .expect(201);
        const parent = res.body as CloudParent;
        expect(parent.owner_id).toBe(1);
        await db.query("UPDATE users SET role='admin' WHERE id=2");
        for (const path of [
          `/${parent.id}`,
          `/${parent.id}/result`,
          `?cursor=${parent.id}`,
        ])
          await request(http)
            .get('/uapi/cloud-workflows' + path)
            .set('Authorization', `Bearer ${token(2)}`)
            .expect(404);
        await request(http)
          .post(`/uapi/cloud-workflows/${parent.id}/stop`)
          .set('Authorization', `Bearer ${token(2)}`)
          .send({ operationId: randomUUID(), expectedRevision: 1 })
          .expect(404);
        await request(http)
          .get('/uapi/cloud-workflows')
          .set('Authorization', `Bearer ${token(2)}`)
          .expect(200)
          .expect((r) =>
            expect((r.body as { items: unknown[] }).items).toEqual([]),
          );
        const op = { operationId: randomUUID(), expectedRevision: 1 };
        const first = await request(http)
          .post(`/uapi/cloud-workflows/${parent.id}/stop`)
          .set('Authorization', `Bearer ${token(1)}`)
          .send(op)
          .expect(201);
        const repeat = await request(http)
          .post(`/uapi/cloud-workflows/${parent.id}/stop`)
          .set('Authorization', `Bearer ${token(1)}`)
          .send(op)
          .expect(201);
        expect(repeat.body as unknown).toEqual(first.body as unknown);
        evidence.push({
          code: 'JWT_HTTP_PG',
          owner: 1,
          parent: parent.id,
          otherAdminStatus: 404,
          invalidBodyStatus: 400,
          modelPosts: 0,
          runtime: 'synthetic ready explicitly injected',
        });
      } finally {
        await app.close();
      }
    });
    it('批量撤销根操作幂等，不撤销同客户端后来明确创建的新任务', async () => {
      const payload = fixturePayload(),
        p = await create(a, payload),
        operationId = randomUUID();
      const first = await store.revokeClient(
        a,
        payload.clientInstanceId,
        operationId,
        () => now,
      );
      const next = await create(a, {
        ...fixturePayload(),
        clientInstanceId: payload.clientInstanceId,
      });
      expect(
        await store.revokeClient(
          a,
          payload.clientInstanceId,
          operationId,
          () => now,
        ),
      ).toEqual(first);
      expect((await current(a.userId, next.id)).state).toBe('queued');
      expect((await current(a.userId, p.id)).state).toBe('cancelled');
      await expect(
        store.revokeClient(a, randomUUID(), operationId, () => now),
      ).rejects.toThrow('幂等键');
    });
    it('有限分页cursor按实际owner行，删除tombstone/新任务无遗漏重复', async () => {
      const ids: string[] = [];
      for (let n = 0; n < 3; n++) {
        const p = await create();
        ids.push(p.id);
        await store.control(
          a,
          p.id,
          'stop',
          { operationId: randomUUID(), expectedRevision: 1 },
          undefined,
          () => now,
        );
      }
      const first = await service.list(a, undefined, '2'),
        second = await service.list(a, first.nextCursor!, '2');
      const all = [...first.items, ...second.items].map((p) => p.id);
      expect(new Set(all)).toEqual(new Set(ids));
      expect(all).toHaveLength(3);
      expect(second.nextCursor).toBeNull();
      await expect(service.list(a, undefined, '51')).rejects.toThrow();
    });
    it('领取后尚未dispatch停止可结算，重复结算不扣费或阻塞另一owner', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!;
      const live = await current(a.userId, p.id);
      await store.control(
        a,
        p.id,
        'stop',
        { operationId: randomUUID(), expectedRevision: live.revision },
        undefined,
        () => now,
      );
      const settled = await store.settleRevoked(f, () => now);
      expect(settled).toMatchObject({
        state: 'cancelled',
        attempts_used: 0,
        usage_unknown: false,
      });
      expect((await store.settleRevoked(f, () => now)).revision).toBe(
        settled.revision,
      );
      await create(b);
      expect((await store.claim(randomUUID(), () => now))?.ownerId).toBe(
        b.userId,
      );
    });
    it('尚未dispatch停止后进程失联，过期回收不重新排入已取消父任务', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!;
      const live = await current(a.userId, p.id);
      await store.control(
        a,
        p.id,
        'stop',
        { operationId: randomUUID(), expectedRevision: live.revision },
        undefined,
        () => now,
      );
      const q = await create(b),
        next = await store.claim(randomUUID(), () => now + 30001);
      expect(next?.parentId).toBe(q.id);
      expect((await current(a.userId, p.id)).state).toBe('cancelled');
      await expect(
        store.reserveDispatch(f, await step(f), 100, () => now + 30002),
      ).rejects.toThrow();
    });
    it('派发后profile/用户授权变化，续租和最终提交都拒绝', async () => {
      const p = await create(),
        f = (await store.claim(randomUUID(), () => now))!,
        attempt = await store.reserveDispatch(f, await step(f), 100, () => now);
      await db.query('UPDATE ai_providers SET enabled=false WHERE id=1');
      await expect(store.renew(f, () => now)).rejects.toThrow();
      await expect(
        store.finish(f, attempt, 'revoked', { input: 1, output: 1 }, () => now),
      ).rejects.toThrow();
      await db.query('UPDATE ai_providers SET enabled=true WHERE id=1');
      await db.query('UPDATE users SET banned=true WHERE id=1');
      await expect(
        store.finish(f, attempt, 'revoked', { input: 1, output: 1 }, () => now),
      ).rejects.toThrow();
      expect(await store.results(a.userId, p.id)).toEqual([]);
      expect((await current(a.userId, p.id)).attempts_used).toBe(1);
    });
    // 真 PG 锁屏障；时钟在被阻塞之后推进，不用固定延时猜测锁已取得。
    const acrossLock = async <T>(
      sql: string,
      start: () => Promise<T>,
      advance: () => void,
    ) => {
      const blocker = db.createQueryRunner();
      await blocker.connect();
      await blocker.startTransaction();
      let pending: Promise<{ value?: T; error?: unknown }> | undefined;
      try {
        await blocker.query(sql);
        pending = start().then(
          (value) => ({ value }),
          (error: unknown) => ({ error }),
        );
        const end = performance.now() + 5000;
        let waiting = false;
        while (performance.now() < end) {
          const rows = await db.query<Array<{ waiting: boolean }>>(
            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND pid<>pg_backend_pid()) AS waiting",
          );
          if (rows[0].waiting) {
            waiting = true;
            break;
          }
          await new Promise((resolve) => setTimeout(resolve, 2));
        }
        expect(waiting).toBe(true);
        advance();
        await blocker.rollbackTransaction();
        return await pending;
      } finally {
        if (blocker.isTransactionActive) await blocker.rollbackTransaction();
        if (pending) await pending;
        await blocker.release();
      }
    };
    it.each([
      [
        'reserve grant/advisory',
        'reserve',
        'grant_expires_at',
        'SELECT pg_advisory_xact_lock(178404,1)',
      ],
      [
        'reserve deadline/user',
        'reserve',
        'deadline_at',
        'SELECT id FROM users WHERE id=1 FOR UPDATE',
      ],
      [
        'reserve lease/provider',
        'reserve',
        'lease_expires_at',
        'SELECT id FROM ai_providers WHERE id=1 FOR UPDATE',
      ],
      [
        'renew slot',
        'renew',
        'lease_expires_at',
        'SELECT id FROM cloud_workflow_slot WHERE id=1 FOR UPDATE',
      ],
      [
        'renew provider',
        'renew',
        'grant_expires_at',
        'SELECT id FROM ai_providers WHERE id=1 FOR UPDATE',
      ],
      [
        'finish provider',
        'finish',
        'deadline_at',
        'SELECT id FROM ai_providers WHERE id=1 FOR UPDATE',
      ],
      [
        'create provider',
        'create',
        'jwt',
        'SELECT id FROM ai_providers WHERE id=1 FOR UPDATE',
      ],
      [
        'continue provider',
        'continue',
        'deadline_at',
        'SELECT id FROM ai_providers WHERE id=1 FOR UPDATE',
      ],
      [
        'claim user',
        'claim',
        'grant_expires_at',
        'SELECT id FROM users WHERE id=1 FOR UPDATE',
      ],
    ])(
      'deadline lock barrier %s rejects late intent/commit',
      async (_name, action, column, lockSql) => {
        let tick = now;
        const clock = jest.spyOn(Date, 'now').mockImplementation(() => tick);
        try {
          const payload = fixturePayload();
          let parent: CloudParent | undefined,
            f: CloudFence | undefined,
            attempt: string | undefined;
          if (action !== 'create') parent = await create(a, payload);
          if (['reserve', 'renew', 'finish'].includes(action))
            f = (await store.claim(randomUUID()))!;
          if (action === 'renew' || action === 'finish')
            attempt = await store.reserveDispatch(f!, await step(f!), 100);
          if (action === 'continue')
            await db.query(
              "UPDATE cloud_workflow_parents SET state='paused' WHERE id=$1",
              [parent!.id],
            );
          if (parent)
            await db.query(
              `UPDATE cloud_workflow_parents SET ${column}=$1 WHERE id=$2`,
              [new Date(now + 1000), parent.id],
            );
          const before = parent ? await current(a.userId, parent.id) : null;
          const expectedAttempts =
            action === 'renew' || action === 'finish' ? 1 : 0;
          const result = await acrossLock(
            lockSql,
            async () => {
              switch (action) {
                case 'create':
                  return store.create(
                    { ...a, expiresAt: now + 1000 },
                    parseCloudPayload(payload),
                  );
                case 'continue':
                  return store.control(
                    a,
                    parent!.id,
                    'continue',
                    {
                      operationId: randomUUID(),
                      expectedRevision: before!.revision,
                    },
                    1000,
                  );
                case 'claim':
                  return store.claim(randomUUID());
                case 'renew':
                  return store.renew(f!);
                case 'finish':
                  return store.finish(f!, attempt!, 'late output', {
                    input: 2,
                    output: 3,
                  });
                default:
                  return store.reserveDispatch(f!, await step(f!), 100);
              }
            },
            () => {
              tick = now + 1001;
            },
          );
          if (action === 'claim') expect(result.value).toBeNull();
          else expect(result.error).toBeDefined();
          expect(
            await db.query('SELECT id FROM cloud_workflow_attempts'),
          ).toHaveLength(expectedAttempts);
          expect(
            await db.query('SELECT id FROM cloud_workflow_results'),
          ).toHaveLength(0);
          if (parent && action !== 'claim')
            expect(await current(a.userId, parent.id)).toEqual(before);
          if (action === 'create')
            expect(
              await db.query('SELECT id FROM cloud_workflow_parents'),
            ).toHaveLength(0);
          evidence.push({
            code: 'DEADLINE_LOCK_BARRIER',
            action,
            lockSql,
            calledAt: now,
            obtainedAfter: tick,
            newAttempts: 0,
            modelPosts: 0,
          });
        } finally {
          clock.mockRestore();
        }
      },
    );
    it('terminal stop keeps complete output/usage/publication, stale concurrent stop cannot overwrite', async () => {
      const parent = await create(),
        f = (await store.claim(randomUUID(), () => now))!;
      let completed: CloudParent = parent;
      let racingRevision = parent.revision;
      for (const role of ['analysis', 'writing', 'review']) {
        const attempt = await store.reserveDispatch(
          f,
          await step(f, role),
          100,
          () => now,
        );
        racingRevision = (await current(a.userId, parent.id)).revision;
        const content =
          role === 'review' ? '{"passed":true,"feedback":"ok"}' : role;
        if (role !== 'review') {
          completed = await store.finish(
            f,
            attempt,
            content,
            { input: 2, output: 3 },
            () => now,
          );
        } else {
          let stopResult: Promise<unknown> | undefined;
          const outcome = await acrossLock(
            'SELECT id FROM ai_providers WHERE id=1 FOR UPDATE',
            () =>
              store.finish(
                f,
                attempt,
                content,
                { input: 2, output: 3 },
                () => now,
              ),
            () => {
              stopResult = store
                .control(
                  a,
                  parent.id,
                  'stop',
                  {
                    operationId: randomUUID(),
                    expectedRevision: racingRevision,
                  },
                  undefined,
                  () => now,
                )
                .then(
                  () => null,
                  (error: unknown) => error,
                );
            },
          );
          expect(outcome.error).toBeUndefined();
          completed = outcome.value!;
          expect(await stopResult).toBeInstanceOf(Error);
        }
      }
      expect(completed.state).toBe('complete');
      const before = await db.query<unknown[]>(
        'SELECT * FROM cloud_workflow_results ORDER BY id',
      );
      const usages = await db.query<unknown[]>(
        'SELECT * FROM cloud_workflow_attempts ORDER BY id',
      );
      await expect(
        store.control(
          a,
          parent.id,
          'stop',
          { operationId: randomUUID(), expectedRevision: racingRevision },
          undefined,
          () => now,
        ),
      ).rejects.toThrow();
      const op = {
        operationId: randomUUID(),
        expectedRevision: completed.revision,
      };
      await store.control(a, parent.id, 'stop', op, undefined, () => now);
      await store.control(a, parent.id, 'stop', op, undefined, () => now);
      expect(await current(a.userId, parent.id)).toEqual(completed);
      expect(
        await db.query('SELECT * FROM cloud_workflow_results ORDER BY id'),
      ).toEqual(before);
      expect(
        await db.query('SELECT * FROM cloud_workflow_attempts ORDER BY id'),
      ).toEqual(usages);
      expect(
        await db.query("SELECT * FROM cloud_workflow_events WHERE code='stop'"),
      ).toHaveLength(0);
    });
    it.each(['stop', 'delete'] as const)(
      'settlement %s synchronizes step/attempt/slot without duplicate events or refunds',
      async (kind) => {
        const parent = await create(),
          f = (await store.claim(randomUUID(), () => now))!;
        const stepId = await step(f),
          attempt = await store.reserveDispatch(f, stepId, 100, () => now);
        const [before] = await db.query<Array<{ revision: number }>>(
          'SELECT revision FROM cloud_workflow_steps WHERE id=$1',
          [stepId],
        );
        const live = await current(a.userId, parent.id);
        await store.control(
          a,
          parent.id,
          kind,
          { operationId: randomUUID(), expectedRevision: live.revision },
          undefined,
          () => now,
        );
        const settled = await store.settleRevoked(f, () => now);
        expect(settled).toMatchObject({
          state: kind === 'delete' ? 'deleted' : 'cancelled',
          attempts_used: 1,
          usage_unknown: true,
        });
        const rows = await db.query<unknown[]>(
          'SELECT * FROM cloud_workflow_steps WHERE id=$1',
          [stepId],
        );
        expect(rows).toEqual([
          expect.objectContaining({
            state: 'unknown',
            revision: before.revision + 1,
          }),
        ]);
        expect(
          await db.query(
            'SELECT state FROM cloud_workflow_attempts WHERE id=$1',
            [attempt],
          ),
        ).toEqual([{ state: 'unknown' }]);
        expect(
          await db.query('SELECT parent_id FROM cloud_workflow_slot'),
        ).toEqual([{ parent_id: null }]);
        await store.settleRevoked(f, () => now);
        expect(
          await db.query('SELECT * FROM cloud_workflow_steps WHERE id=$1', [
            stepId,
          ]),
        ).toEqual(rows);
        expect(
          await db.query(
            "SELECT sequence FROM cloud_workflow_events WHERE parent_id=$1 AND code='revocation_settled'",
            [parent.id],
          ),
        ).toHaveLength(1);
      },
    );
    it('owner FK rejects cross-owner reassignment with 23503, not a role uniqueness collision', async () => {
      const parent = await create();
      const [before] = await db.query<Array<{ id: string }>>(
        "SELECT * FROM cloud_workflow_steps WHERE parent_id=$1 AND role='analysis'",
        [parent.id],
      );
      await expect(
        db.query('UPDATE cloud_workflow_steps SET owner_id=2 WHERE id=$1', [
          before.id,
        ]),
      ).rejects.toMatchObject({
        driverError: {
          code: '23503',
          constraint: 'cloud_workflow_steps_parent_id_owner_id_fkey',
        },
      });
      expect(
        await db.query('SELECT * FROM cloud_workflow_steps WHERE id=$1', [
          before.id,
        ]),
      ).toEqual([before]);
      evidence.push({
        code: 'OWNER_COMPOSITE_FK',
        pgCode: '23503',
        constraint: 'cloud_workflow_steps_parent_id_owner_id_fkey',
        rowUnchanged: true,
      });
    });
  },
);
