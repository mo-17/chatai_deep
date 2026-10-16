import { existsSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import type { AddressInfo } from 'node:net';
import type { Server } from 'node:http';
import { Logger, ValidationPipe, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { DataSource, type QueryRunner } from 'typeorm';
import request from 'supertest';
import * as jwt from 'jsonwebtoken';
import { ChatService } from './chat.service';
import { ChatController } from './chat.controller';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { Usage } from './usage.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { User } from '../user/user.entity';
import { AllExceptionsFilter } from '../common/all-exceptions.filter';

const owned = process.env.R4A_PG_TEST === '1' ? describe : describe.skip;
const key =
  'synthetic-routing-fixture-key-only-00000000000000000000000000000000';
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
async function reached(promise: Promise<void>, message: string) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      promise,
      new Promise<void>((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), 1500);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
type Gate = {
  entered: ReturnType<typeof deferred>;
  release: ReturnType<typeof deferred>;
  pid?: number;
  mode: 'write' | 'read';
  armed: boolean;
};
owned('R4a owner CRUD: actual AdminGuard HTTP and private PostgreSQL', () => {
  jest.setTimeout(15000);
  let admin: DataSource, left: DataSource, right: DataSource;
  let app: INestApplication, server: Server, currentSchema: string;
  let target: Conversation;
  let gate: Gate | undefined;
  let fetchSpy: jest.SpyInstance, errorSpy: jest.SpyInstance;
  let sql: string[] = [];
  let originalCreateRunner: DataSource['createQueryRunner'];
  const evidence: {
    identities: unknown[];
    cases: unknown[];
    waits: unknown[];
    cleanup: unknown[];
  } = { identities: [], cases: [], waits: [], cleanup: [] };
  let index = 0;
  function env(name: string) {
    const value = process.env['R4A_PG_' + name];
    if (!value) throw new Error('owned PG fixture configuration absent');
    return value;
  }
  function source(schema = 'public') {
    return new DataSource({
      type: 'postgres',
      host: env('SOCKET'),
      port: Number(env('PORT')),
      username: env('USER'),
      database: env('DATABASE'),
      schema,
      entities: [
        Conversation,
        Message,
        Usage,
        AiProvider,
        AiModel,
        AiGlobalConfig,
      ],
      synchronize: false,
      migrationsRun: false,
      logging: false,
      extra: {
        max: 3,
        connectionTimeoutMillis: 2000,
        options: `-c search_path=${schema} -c statement_timeout=4000 -c lock_timeout=4000`,
      },
    });
  }
  async function identity(ds: DataSource) {
    const rows = await ds.query<
      { database: string; user: string; data: string; listen: string }[]
    >(
      `SELECT current_database() AS database, current_user AS "user", current_setting('data_directory') AS data, current_setting('listen_addresses') AS listen`,
    );
    expect(rows[0]).toEqual({
      database: env('DATABASE'),
      user: env('USER'),
      data: env('DATA'),
      listen: '',
    });
    evidence.identities.push(rows[0]);
  }
  const token = (id = 17) =>
    jwt.sign({ userId: id, tokenVersion: 0 }, key, { expiresIn: '15m' });
  const path = () => `/uapi/chat/conversations/${target.id}/messages`;
  const get = (id = 17, url = path()) =>
    request(server)
      .get(url)
      .set('Authorization', `Bearer ${token(id)}`);
  const post = (messages: unknown, id = 17) =>
    request(server)
      .post(path())
      .set('Authorization', `Bearer ${token(id)}`)
      .send({ messages });
  const del = (id = 17) =>
    request(server)
      .delete(`/uapi/chat/conversations/${target.id}`)
      .set('Authorization', `Bearer ${token(id)}`);
  const childSql = () =>
    sql.filter((s) =>
      /(?:FROM|INTO|UPDATE)\s+(?:"[^"]+"\.)?"messages"/i.test(s),
    );
  beforeAll(async () => {
    const nonce = env('NONCE');
    expect(env('SOCKET')).toBe(`/tmp/chatai-r4a-pg-${nonce}/socket`);
    expect(env('DATA')).toBe(`/tmp/chatai-r4a-pg-${nonce}/data`);
    expect(env('DATABASE')).toBe(`r4a_${nonce}`);
    expect(env('USER')).toBe(`r4a_${nonce}`);
    expect(
      JSON.parse(
        readFileSync(resolve(env('SOCKET'), 'fixture-sentinel.json'), 'utf8'),
      ) as unknown,
    ).toEqual({ nonce });
    expect(statSync(env('DATA')).mode & 0o777).toBe(0o700);
    expect(existsSync(env('SOCKET'))).toBe(true);
    admin = await source().initialize();
    await identity(admin);
  });
  beforeEach(async () => {
    currentSchema = `r4a_case_${index++}`;
    await admin.query(`CREATE SCHEMA "${currentSchema}"`);
    left = await source(currentSchema).initialize();
    right = await source(currentSchema).initialize();
    await identity(left);
    await identity(right);
    // Only this verified owned synthetic schema; no migration runner/default DS.
    await left.synchronize();
    target = await left.getRepository(Conversation).save({
      userId: 17,
      title: 'kept',
      model: 'removed-model',
      providerCode: 'removed-provider',
    });
    await left
      .getRepository(Message)
      .save({ conversationId: target.id, role: 'user', content: 'OLD' });
    sql = [];
    gate = undefined;
    originalCreateRunner = left.createQueryRunner.bind(
      left,
    ) as DataSource['createQueryRunner'];
    left.createQueryRunner = (...args) => {
      const runner: QueryRunner = originalCreateRunner(...args);
      const query = runner.query.bind(runner) as QueryRunner['query'];
      runner.query = (async (...qargs: Parameters<QueryRunner['query']>) => {
        const result: unknown = await query(...qargs);
        sql.push(qargs[0]);
        if (
          gate?.armed &&
          /FROM\s+(?:"[^"]+"\.)?"conversations"/i.test(qargs[0]) &&
          qargs[0].includes(gate.mode === 'write' ? 'FOR UPDATE' : 'FOR SHARE')
        ) {
          gate.armed = false;
          const pids = (await query('SELECT pg_backend_pid() AS pid')) as {
            pid: number;
          }[];
          gate.pid = pids[0].pid;
          gate.entered.resolve();
          await gate.release.promise;
        }
        return result;
      }) as QueryRunner['query'];
      return runner;
    };
    const providers = [
      ChatService,
      ProviderCacheService,
      TokenAuthenticationService,
      ...[
        Conversation,
        Message,
        Usage,
        AiProvider,
        AiModel,
        AiGlobalConfig,
      ].map((entity) => ({
        provide: getRepositoryToken(entity),
        useValue: left.getRepository(entity),
      })),
      {
        provide: getRepositoryToken(User),
        useValue: {
          findOne: ({ where }: { where: { id: number } }) =>
            Promise.resolve({
              id: where.id,
              role: where.id === 19 ? 'user' : 'admin',
              banned: where.id === 20,
              tokenVersion: 0,
              userName: 'synthetic',
            }),
        },
      },
    ];
    const module = await Test.createTestingModule({
      controllers: [ChatController],
      providers,
    }).compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    errorSpy = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
    fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
      throw new Error('model POST forbidden');
    });
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer() as Server;
    evidence.cases.push({
      port: (server.address() as AddressInfo).port,
      schema: currentSchema,
    });
  });
  afterEach(async () => {
    gate?.release.resolve();
    expect(fetchSpy).not.toHaveBeenCalled();
    await app?.close();
    await left?.destroy();
    await right?.destroy();
    await admin.query(`DROP SCHEMA IF EXISTS "${currentSchema}" CASCADE`);
    evidence.cleanup.push({
      schema: currentSchema,
      httpClosed: !server.listening,
      leftClosed: !left.isInitialized,
      rightClosed: !right.isInitialized,
      modelPOST: 0,
    });
    jest.restoreAllMocks();
  });
  afterAll(async () => {
    if (admin?.isInitialized) await admin.destroy();
    writeFileSync(env('EVIDENCE'), JSON.stringify(evidence, null, 2) + '\n');
  });
  it('owner may read invalid stored pair history without resolver or model access', async () => {
    const r = await get();
    expect(r.status).toBe(200);
    expect(r.body as unknown).toMatchObject({
      code: 0,
      data: [{ role: 'user', content: 'OLD' }],
    });
    expect(r.body as unknown).toMatchObject({
      ownerId: 17,
      conversationId: target.id,
    });
    const list = await request(server)
      .get('/uapi/chat/conversations')
      .set('Authorization', `Bearer ${token()}`);
    expect(list.body as unknown).toMatchObject({
      ownerId: 17,
      data: [
        {
          id: target.id,
          model: 'removed-model',
          providerCode: 'removed-provider',
        },
      ],
    });
    expect(childSql()).toHaveLength(1);
  });
  for (const verb of ['GET', 'POST', 'DELETE']) {
    it(`foreign admin ${verb} reads parent only and changes no child or parent`, async () => {
      const r =
        verb === 'GET'
          ? await get(18)
          : verb === 'POST'
            ? await post([{ role: 'user', content: 'foreign' }], 18)
            : await del(18);
      evidence.cases.push({
        verb,
        foreignAdmin: true,
        status: r.status,
        childAccessStatements: childSql().length,
        childRows: await right
          .getRepository(Message)
          .countBy({ conversationId: target.id }),
        parentRows: await right
          .getRepository(Conversation)
          .countBy({ id: target.id }),
      });
      expect(r.status).toBe(404);
      expect(r.body as unknown).toMatchObject({
        safeCode: 'conversation_unavailable',
      });
      expect(childSql()).toHaveLength(0);
      expect(
        await right
          .getRepository(Message)
          .countBy({ conversationId: target.id }),
      ).toBe(1);
      expect(
        await right.getRepository(Conversation).countBy({ id: target.id }),
      ).toBe(1);
    });
  }
  for (const verb of ['get', 'post', 'delete'] as const) {
    it(`${verb} requires real guard authentication/admin before any repositories`, async () => {
      const url =
        verb === 'delete' ? `/uapi/chat/conversations/${target.id}` : path();
      let r = await request(server)
        [verb](url)
        .send(verb === 'post' ? { messages: [] } : undefined);
      expect(r.status).toBe(401);
      expect(sql).toHaveLength(0);
      r = await request(server)
        [verb](url)
        .set('Authorization', `Bearer ${token(19)}`)
        .send(verb === 'post' ? { messages: [] } : undefined);
      expect(r.status).toBe(403);
      expect(sql).toHaveLength(0);
      r = await request(server)
        [verb](url)
        .set('Authorization', `Bearer ${token(20)}`)
        .send(verb === 'post' ? { messages: [] } : undefined);
      expect(r.status).toBe(401);
      expect(sql).toHaveLength(0);
    });
  }
  it('per-turn append stores four messages; equal content remains separate; projection excludes caller IDs', async () => {
    await left.getRepository(Message).delete({ conversationId: target.id });
    sql = [];
    for (const n of [1, 2]) {
      const r = await post([
        { role: 'user', content: 'same', id: 900, conversationId: 888 },
        { role: 'assistant', content: `reply${n}` },
      ]);
      expect(r.status).toBe(200);
    }
    const rows = await right
      .getRepository(Message)
      .find({ where: { conversationId: target.id }, order: { id: 'ASC' } });
    expect(rows.map((m) => m.content)).toEqual([
      'same',
      'reply1',
      'same',
      'reply2',
    ]);
    expect(
      rows.every((m) => m.id !== 900 && m.conversationId === target.id),
    ).toBe(true);
  });
  for (const invalid of [
    null,
    'bad',
    [{ role: 'tool', content: 'bad' }],
    [{ role: 'user', content: null }],
  ]) {
    it(`DTO rejects invalid messages ${JSON.stringify(invalid)} before owner/child query`, async () => {
      const r = await post(invalid);
      expect(r.status).toBe(400);
      expect(sql).toHaveLength(0);
      expect(r.body as unknown).toMatchObject({ safeCode: 'invalid_request' });
    });
  }
  it('non-integer/partial/negative IDs are rejected without child queries', async () => {
    for (const id of ['1abc', '0', '-1', '9007199254740993']) {
      const r = await get(17, `/uapi/chat/conversations/${id}/messages`);
      expect(r.status).toBe(400);
      expect(childSql()).toHaveLength(0);
    }
  });
  it('owner delete atomically cascades only its conversation', async () => {
    const other = await right
      .getRepository(Conversation)
      .save({ userId: 18, title: 'other', model: 'same', providerCode: null });
    await right
      .getRepository(Message)
      .save({ conversationId: other.id, role: 'user', content: 'OTHER' });
    expect((await del()).status).toBe(200);
    expect(
      await right.getRepository(Conversation).countBy({ id: target.id }),
    ).toBe(0);
    expect(
      await right.getRepository(Message).countBy({ conversationId: target.id }),
    ).toBe(0);
    expect(
      await right.getRepository(Message).countBy({ conversationId: other.id }),
    ).toBe(1);
  });
  it('delete failure rolls back parent and child; errors/logs cannot expose SQL/query values via Express aliases', async () => {
    await admin.query(
      `CREATE FUNCTION "${currentSchema}".deny_delete() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'synthetic-secret-SQL-token'; END $$ LANGUAGE plpgsql`,
    );
    await admin.query(
      `CREATE TRIGGER deny_delete BEFORE DELETE ON "${currentSchema}".conversations FOR EACH ROW EXECUTE FUNCTION "${currentSchema}".deny_delete()`,
    );
    const r = await request(server)
      .delete(
        `/UAPI/CHAT/CONVERSATIONS/${target.id}/?query=synthetic-secret-query`,
      )
      .set('Authorization', `Bearer ${token()}`);
    const parentRows = await right
      .getRepository(Conversation)
      .countBy({ id: target.id });
    const childRows = await right
      .getRepository(Message)
      .countBy({ conversationId: target.id });
    const responseLeaksMarker = JSON.stringify(r.body).includes(
      'synthetic-secret',
    );
    const logLeaksMarker = JSON.stringify(errorSpy.mock.calls).includes(
      'synthetic-secret',
    );
    evidence.cases.push({
      operation: 'delete-trigger-failure',
      status: r.status,
      parentRows,
      childRows,
      responseLeaksMarker,
      logLeaksMarker,
    });
    expect(r.status).toBe(500);
    expect(r.body as unknown).toMatchObject({
      safeCode: 'conversation_request_failed',
    });
    expect(JSON.stringify(r.body)).not.toContain('synthetic-secret');
    expect(JSON.stringify(errorSpy.mock.calls)).not.toContain(
      'synthetic-secret',
    );
    expect(
      await right.getRepository(Conversation).countBy({ id: target.id }),
    ).toBe(1);
    expect(
      await right.getRepository(Message).countBy({ conversationId: target.id }),
    ).toBe(1);
  });
  it('failed append rolls back entire increment and preserves history', async () => {
    await admin.query(
      `CREATE FUNCTION "${currentSchema}".deny_insert() RETURNS trigger AS $$ BEGIN IF NEW.content = 'fail-second' THEN RAISE EXCEPTION 'synthetic-secret-bind'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql`,
    );
    await admin.query(
      `CREATE TRIGGER deny_insert BEFORE INSERT ON "${currentSchema}".messages FOR EACH ROW EXECUTE FUNCTION "${currentSchema}".deny_insert()`,
    );
    const r = await post([
      { role: 'user', content: 'first' },
      { role: 'assistant', content: 'fail-second' },
    ]);
    expect(r.status).toBe(500);
    expect(JSON.stringify(r.body)).not.toContain('synthetic-secret');
    expect(
      (
        await right.getRepository(Message).findBy({ conversationId: target.id })
      ).map((m) => m.content),
    ).toEqual(['OLD']);
  });
  async function waitForLock(pid: number) {
    for (let i = 0; i < 80; i++) {
      const rows = await admin.query<{ wait: string | null }[]>(
        'SELECT wait_event_type AS wait FROM pg_stat_activity WHERE pid=$1',
        [pid],
      );
      if (rows[0]?.wait === 'Lock') {
        evidence.waits.push({ pid, actualLockWait: true });
        return;
      }
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error('expected actual owned row lock wait absent');
  }
  it('append parent write lock serializes owner transfer; after commit old owner cannot read', async () => {
    gate = {
      entered: deferred(),
      release: deferred(),
      mode: 'write',
      armed: true,
    };
    const pending = post([{ role: 'user', content: 'new' }]).then((r) => r);
    await reached(gate.entered.promise, 'parent lock barrier absent');
    let pid = 0;
    const moved = right.transaction(async (manager) => {
      const rows = await manager.query<{ pid: number }[]>(
        'SELECT pg_backend_pid() AS pid',
      );
      pid = rows[0].pid;
      await manager.update(Conversation, { id: target.id }, { userId: 18 });
    });
    for (let i = 0; i < 40 && !pid; i++)
      await new Promise((r) => setTimeout(r, 5));
    await waitForLock(pid);
    gate.release.resolve();
    expect((await pending).status).toBe(200);
    await moved;
    expect((await get(17)).status).toBe(404);
    expect((await get(18)).status).toBe(200);
  });
  it('history parent read lock serializes deletion until snapshot completes', async () => {
    gate = {
      entered: deferred(),
      release: deferred(),
      mode: 'read',
      armed: true,
    };
    const pending = get().then((r) => r);
    await reached(gate.entered.promise, 'parent share barrier absent');
    let pid = 0;
    const removed = right.transaction(async (manager) => {
      const rows = await manager.query<{ pid: number }[]>(
        'SELECT pg_backend_pid() AS pid',
      );
      pid = rows[0].pid;
      await manager.delete(Conversation, { id: target.id, userId: 17 });
    });
    for (let i = 0; i < 40 && !pid; i++)
      await new Promise((r) => setTimeout(r, 5));
    await waitForLock(pid);
    gate.release.resolve();
    expect((await pending).status).toBe(200);
    await removed;
    expect((await get()).status).toBe(404);
  });
});
