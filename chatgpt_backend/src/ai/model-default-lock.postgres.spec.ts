import {
  BadRequestException,
  ConflictException,
  NotFoundException,
} from '@nestjs/common';
import { DataSource, MoreThan, type QueryRunner } from 'typeorm';
import { readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { ProviderCacheService } from './provider-cache.service';
import { AdminAiModelService } from './admin-ai-model.service';
import { AdminAiProviderService } from './admin-ai-provider.service';
import type { ChatService } from '../chat/chat.service';

const suite = process.env.AI_DEFAULT_PG_TEST === '1' ? describe : describe.skip;
const evidence: unknown[] = [];
jest.setTimeout(15_000);

async function privateDatabase(instance: string): Promise<DataSource> {
  const e = process.env;
  const nonce = e.AI_DEFAULT_PG_NONCE;
  const root = `/tmp/chatai-ai-default-${nonce}`;
  if (
    !nonce ||
    !/^[a-f0-9]{12}$/.test(nonce) ||
    e.AI_DEFAULT_PG_SOCKET !== `${root}/socket` ||
    e.AI_DEFAULT_PG_DATA !== `${root}/data` ||
    e.AI_DEFAULT_PG_USER !== `ai_${nonce}` ||
    e.AI_DEFAULT_PG_DATABASE !== `ai_default_${nonce}`
  )
    throw new Error('private_nonce_required');
  for (const path of [root, `${root}/socket`, `${root}/data`]) {
    if (
      (statSync(path).mode & 0o777) !== 0o700 ||
      realpathSync(path) !== `/private${path}`
    )
      throw new Error('private_directory_required');
  }
  const sentinel = JSON.parse(
    readFileSync(`${root}/socket/fixture-sentinel.json`, 'utf8'),
  ) as { nonce: string };
  if (sentinel.nonce !== nonce) throw new Error('private_sentinel_required');
  const db = new DataSource({
    type: 'postgres',
    host: `${root}/socket`,
    port: Number(e.AI_DEFAULT_PG_PORT),
    username: e.AI_DEFAULT_PG_USER,
    database: e.AI_DEFAULT_PG_DATABASE,
    password: '',
    entities: [AiProvider, AiModel],
    synchronize: false,
    migrationsRun: false,
    logging: false,
    extra: {
      max: 4,
      connectionTimeoutMillis: 3000,
      application_name: `ai-default-${instance}`,
      options: '-c statement_timeout=5000 -c lock_timeout=4000',
    },
  });
  try {
    await db.initialize();
    const [identity] = await db.query<
      Array<{ db: string; user: string; dir: string; listen: string }>
    >(
      "SELECT current_database() db,current_user user,current_setting('data_directory') dir,current_setting('listen_addresses') listen",
    );
    if (
      identity.db !== e.AI_DEFAULT_PG_DATABASE ||
      identity.user !== e.AI_DEFAULT_PG_USER ||
      realpathSync(identity.dir) !== realpathSync(`${root}/data`) ||
      identity.listen !== ''
    )
      throw new Error('private_identity_required');
    evidence.push({ instance, identityVerified: true, tcp: false });
    return db;
  } catch (error) {
    if (db.isInitialized) await db.destroy();
    throw error;
  }
}

suite('model default writes on two owned nonce PostgreSQL instances', () => {
  let a: DataSource;
  let b: DataSource;
  let sa: AdminAiModelService;
  let sb: AdminAiModelService;
  let providerService: AdminAiProviderService;
  let ca: ProviderCacheService;
  let cb: ProviderCacheService;
  let fetchSpy: jest.SpyInstance;
  const activeHolds = new Set<QueryRunner>();
  const pending = new Set<Promise<unknown>>();

  beforeAll(async () => {
    a = await privateDatabase('a');
    // 仅在 nonce/sentinel/数据库身份全核实后，为自有空库建测试实体表。
    await a.synchronize();
    b = await privateDatabase('b');
  });
  afterAll(async () => {
    if (b?.isInitialized) await b.destroy();
    if (a?.isInitialized) await a.destroy();
    if (process.env.AI_DEFAULT_PG_EVIDENCE)
      writeFileSync(
        process.env.AI_DEFAULT_PG_EVIDENCE,
        JSON.stringify(
          {
            classification:
              'owned nonce real PG; synthetic data; no model calls',
            evidence,
          },
          null,
          2,
        ),
      );
  });
  beforeEach(async () => {
    await a.getRepository(AiModel).delete({ id: MoreThan(0) });
    await a.getRepository(AiProvider).delete({ id: MoreThan(0) });
    // Generated id 的 save insert 不作为夹具固定身份保证；只在自有空库显式 seed。
    for (const id of [1, 2])
      await a.query(
        'INSERT INTO ai_providers (id,code,"displayName","apiKey","baseUrl") VALUES ($1,$2,$3,$4,$5)',
        [
          id,
          `synthetic-${id}`,
          `Synthetic ${id}`,
          'synthetic-key',
          'https://synthetic.invalid',
        ],
      );
    await a.query(
      "INSERT INTO ai_models (id,\"providerId\",\"modelId\",\"displayName\",\"isDefault\") VALUES (101,1,'a-model','A',true),(102,1,'b-model','B',false),(201,2,'c-model','C',true)",
    );
    ca = new ProviderCacheService();
    cb = new ProviderCacheService();
    sa = new AdminAiModelService(
      a.getRepository(AiModel),
      a.getRepository(AiProvider),
      a,
      ca,
    );
    sb = new AdminAiModelService(
      b.getRepository(AiModel),
      b.getRepository(AiProvider),
      b,
      cb,
    );
    providerService = new AdminAiProviderService(
      b.getRepository(AiProvider),
      b.getRepository(AiModel),
      b,
      {} as ChatService,
      cb,
    );
    fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
      throw new Error('model calls forbidden');
    });
    jest.spyOn(console, 'warn').mockImplementation(() => undefined);
  });
  afterEach(async () => {
    for (const qr of activeHolds) {
      if (qr.isTransactionActive) await qr.rollbackTransaction();
      if (!qr.isReleased) await qr.release();
    }
    activeHolds.clear();
    await Promise.all(pending);
    pending.clear();
    expect(fetchSpy).not.toHaveBeenCalled();
    jest.restoreAllMocks();
  });

  async function defaults(providerId: number) {
    return (
      await a
        .getRepository(AiModel)
        .find({ where: { providerId, isDefault: true }, order: { id: 'ASC' } })
    ).map((m) => m.id);
  }
  async function hold(ids: number[]) {
    const qr = a.createQueryRunner();
    activeHolds.add(qr);
    await qr.connect();
    await qr.startTransaction();
    const [{ pid }] = (await qr.query('SELECT pg_backend_pid() pid')) as Array<{
      pid: number;
    }>;
    for (const id of [...ids].sort((x, y) => x - y))
      await qr.manager.findOneOrFail(AiProvider, {
        where: { id },
        lock: { mode: 'pessimistic_write' },
      });
    return { qr, pid };
  }
  async function release(qr: QueryRunner, commit = true) {
    if (qr.isTransactionActive) {
      if (commit) await qr.commitTransaction();
      else await qr.rollbackTransaction();
    }
    await qr.release();
    activeHolds.delete(qr);
  }
  async function blocked(instance: string, blocker: number, label: string) {
    const deadline = Date.now() + 1200;
    while (Date.now() < deadline) {
      const rows = await a.query<
        Array<{ pid: number; app: string; blockers: number[]; query: string }>
      >(
        "SELECT pid,application_name app,pg_blocking_pids(pid) blockers,query FROM pg_stat_activity WHERE application_name IN ('ai-default-a','ai-default-b') AND wait_event_type='Lock' AND pid<>pg_backend_pid()",
      );
      // tuple/锁队列可先被前方等待者挡住；整条链必须到达自有持锁 PID。
      function chain(
        pid: number,
        visited = new Set<number>(),
      ): number[] | null {
        if (pid === blocker) return [pid];
        if (visited.has(pid)) return null;
        visited.add(pid);
        for (const parent of rows.find((r) => r.pid === pid)?.blockers ?? []) {
          const path = chain(parent, new Set(visited));
          if (path) return [pid, ...path];
        }
        return null;
      }
      const row = rows.find(
        (r) =>
          r.app === `ai-default-${instance}` &&
          chain(r.pid) !== null &&
          r.query.includes('"ai_providers"') &&
          r.query.includes('FOR UPDATE'),
      );
      if (row) {
        evidence.push({
          label,
          waitingPid: row.pid,
          blockerPid: blocker,
          blockingChain: chain(row.pid),
          actualWait: true,
          relation: 'ai_providers',
        });
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error(`no_provider_lock_wait:${label}`);
  }
  function observe<T>(operation: Promise<T>) {
    // 即刻挂接拒绝处理，屏障失败也不会产生 unhandled rejection。
    const observed = operation.then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error }),
    );
    pending.add(observed);
    return observed;
  }
  async function success<T>(operation: ReturnType<typeof observe<T>>) {
    const result = await operation;
    if (!result.ok) throw result.error;
    return result.value;
  }

  it('create default replaces only target provider default and invalidates after commit', async () => {
    const invalidate = jest.spyOn(ca, 'invalidate');
    const result = await sa.create({
      providerId: 1,
      modelId: 'new-model',
      displayName: 'New',
      isDefault: true,
    });
    expect(await defaults(1)).toEqual([result.id]);
    expect(await defaults(2)).toEqual([201]);
    expect(result.providerCode).toBe('synthetic-1');
    expect(invalidate).toHaveBeenCalledTimes(1);
  });
  it('edit true and setDefault use the same target provider exclusion', async () => {
    await sa.edit(102, { isDefault: true });
    expect(await defaults(1)).toEqual([102]);
    const result = await sa.setDefault(101);
    expect(await defaults(1)).toEqual([101]);
    expect(await defaults(2)).toEqual([201]);
    expect(result.providerCode).toBe('synthetic-1');
  });
  it('retained true ordinary edit closes existing synthetic duplicate defaults only in target provider', async () => {
    await a.getRepository(AiModel).update(102, { isDefault: true });
    await sa.edit(102, { description: 'explicit description edit' });
    expect(await defaults(1)).toEqual([102]);
    expect(await defaults(2)).toEqual([201]);
  });
  it('false and omitted create do not select another default; false edit leaves no replacement', async () => {
    expect(
      (
        await sa.create({
          providerId: 1,
          modelId: 'non-default',
          displayName: 'Other',
        })
      ).isDefault,
    ).toBe(false);
    expect(await defaults(1)).toEqual([101]);
    await sa.edit(101, { isDefault: false });
    expect(await defaults(1)).toEqual([]);
  });
  it('moving retained default changes only target exclusion with no source replacement', async () => {
    const result = await sa.edit(101, { providerId: 2 });
    expect(result.providerCode).toBe('synthetic-2');
    expect(result.isDefault).toBe(true);
    expect(await defaults(1)).toEqual([]);
    expect(await defaults(2)).toEqual([101]);
  });
  it.each([null, 0, -1, 1.5, 999])(
    'rejects invalid or missing provider %s without writes',
    async (providerId) => {
      const before = await a
        .getRepository(AiModel)
        .find({ order: { id: 'ASC' } });
      await expect(
        sa.edit(102, { providerId: providerId as number }),
      ).rejects.toBeInstanceOf(BadRequestException);
      expect(
        await a.getRepository(AiModel).find({ order: { id: 'ASC' } }),
      ).toEqual(before);
    },
  );
  it('create rejects missing provider and edit/setDefault missing model stays 404', async () => {
    await expect(
      sa.create({
        providerId: 999,
        modelId: 'orphan',
        displayName: 'Orphan',
        isDefault: true,
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(sa.edit(999, {})).rejects.toBeInstanceOf(NotFoundException);
    await expect(sa.setDefault(999)).rejects.toBeInstanceOf(NotFoundException);
  });
  it.each(['create', 'edit'] as const)(
    '%s unique-constraint failure rolls back old default and retains cache',
    async (entry) => {
      ca.set(
        'synthetic-cache',
        await a.getRepository(AiProvider).findOneByOrFail({ id: 1 }),
      );
      const invalidate = jest.spyOn(ca, 'invalidate');
      const operation =
        entry === 'create'
          ? sa.create({
              providerId: 1,
              modelId: 'a-model',
              displayName: 'Duplicate',
              isDefault: true,
            })
          : sa.edit(102, { modelId: 'a-model', isDefault: true });
      await expect(operation).rejects.toMatchObject({
        driverError: { code: '23505' },
      });
      expect(await defaults(1)).toEqual([101]);
      expect(invalidate).not.toHaveBeenCalled();
      expect(ca.get('synthetic-cache')?.code).toBe('synthetic-1');
    },
  );
  it('setDefault constraint failure rolls back clearing old default', async () => {
    await a.query(
      'ALTER TABLE ai_models ADD CONSTRAINT synthetic_default_failure CHECK (NOT (id=102 AND "isDefault"))',
    );
    try {
      const invalidate = jest.spyOn(ca, 'invalidate');
      await expect(sa.setDefault(102)).rejects.toMatchObject({
        driverError: { code: '23514' },
      });
      expect(await defaults(1)).toEqual([101]);
      expect(invalidate).not.toHaveBeenCalled();
    } finally {
      await a.query(
        'ALTER TABLE ai_models DROP CONSTRAINT synthetic_default_failure',
      );
    }
  });
  it('committed setDefault returns its transaction snapshot without post-commit detail lookup', async () => {
    const detail = jest
      .spyOn(sa, 'detail')
      .mockRejectedValue(new Error('synthetic later deletion'));
    const invalidate = jest.spyOn(ca, 'invalidate');
    expect((await sa.setDefault(102)).providerCode).toBe('synthetic-1');
    expect(detail).not.toHaveBeenCalled();
    expect(invalidate).toHaveBeenCalledTimes(1);
  });
  it('two creates really wait on provider before yielding one default', async () => {
    const { qr, pid } = await hold([1]);
    const x = observe(
      sa.create({
        providerId: 1,
        modelId: 'new-a',
        displayName: 'New A',
        isDefault: true,
      }),
    );
    const y = observe(
      sb.create({
        providerId: 1,
        modelId: 'new-b',
        displayName: 'New B',
        isDefault: true,
      }),
    );
    try {
      await blocked('a', pid, 'create-a');
      await blocked('b', pid, 'create-b');
    } finally {
      await release(qr);
    }
    const results = await Promise.all([success(x), success(y)]);
    const active = await defaults(1);
    expect(active).toHaveLength(1);
    expect(results.map((m) => m.id)).toContain(active[0]);
  });
  it('edit and setDefault really wait on the same provider exclusion', async () => {
    const { qr, pid } = await hold([1]);
    const x = observe(sa.edit(102, { isDefault: true }));
    const y = observe(sb.setDefault(101));
    try {
      await blocked('a', pid, 'edit');
      await blocked('b', pid, 'setDefault');
    } finally {
      await release(qr);
    }
    await Promise.all([success(x), success(y)]);
    expect(await defaults(1)).toHaveLength(1);
  });
  it('opposite provider moves wait in ascending order and finish without a deadlock', async () => {
    const { qr, pid } = await hold([1, 2]);
    const x = observe(sa.edit(101, { providerId: 2, isDefault: true }));
    const y = observe(sb.edit(201, { providerId: 1, isDefault: true }));
    try {
      await blocked('a', pid, 'move-1-to-2');
      await blocked('b', pid, 'move-2-to-1');
    } finally {
      await release(qr);
    }
    await Promise.all([success(x), success(y)]);
    expect(await defaults(1)).toEqual([201]);
    expect(await defaults(2)).toEqual([101]);
  });
  it('lock-time provider change returns 409 without reapplying stale edit', async () => {
    const { qr, pid } = await hold([1, 2]);
    const op = observe(sb.edit(101, { description: 'stale edit' }));
    try {
      await blocked('b', pid, 'provider-changed');
      await qr.manager.update(AiModel, 101, {
        providerId: 2,
        isDefault: false,
        displayName: 'Concurrent winner',
      });
    } finally {
      await release(qr);
    }
    const result = await op;
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toBeInstanceOf(ConflictException);
    const current = await a.getRepository(AiModel).findOneByOrFail({ id: 101 });
    expect(current.displayName).toBe('Concurrent winner');
    expect(current.description).toBeNull();
    expect(current.providerId).toBe(2);
  });
  it('candidate uses locked latest other fields rather than outside snapshot', async () => {
    const { qr, pid } = await hold([1]);
    const op = observe(sb.edit(102, { description: 'Only submitted field' }));
    try {
      await blocked('b', pid, 'latest-fields');
      await qr.manager.update(AiModel, 102, {
        displayName: 'Latest title',
        sortOrder: 7,
        isDefault: true,
      });
    } finally {
      await release(qr);
    }
    const result = await success(op);
    expect(result.displayName).toBe('Latest title');
    expect(result.sortOrder).toBe(7);
    expect(result.description).toBe('Only submitted field');
    expect(await defaults(1)).toEqual([102]);
  });
  it('provider deletion waits on parent before deleting any child', async () => {
    const { qr, pid } = await hold([1]);
    const op = observe(providerService.delete(1));
    try {
      await blocked('b', pid, 'provider-delete');
      expect(await a.getRepository(AiModel).countBy({ providerId: 1 })).toBe(2);
    } finally {
      await release(qr);
    }
    await success(op);
    expect(await a.getRepository(AiModel).countBy({ providerId: 1 })).toBe(0);
  });
  it('delete first then queued default write cannot create an orphan', async () => {
    const { qr, pid } = await hold([1]);
    const op = observe(
      sb.create({
        providerId: 1,
        modelId: 'late-orphan',
        displayName: 'Late',
        isDefault: true,
      }),
    );
    try {
      await blocked('b', pid, 'delete-before-create');
      await qr.manager.delete(AiModel, { providerId: 1 });
      await qr.manager.delete(AiProvider, { id: 1 });
    } finally {
      await release(qr);
    }
    const result = await op;
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toBeInstanceOf(BadRequestException);
    expect(await a.getRepository(AiModel).countBy({ providerId: 1 })).toBe(0);
  });
  it('deleted model after provider wait returns 404 without recreation', async () => {
    const { qr, pid } = await hold([1]);
    const op = observe(sb.edit(102, { isDefault: true }));
    try {
      await blocked('b', pid, 'model-deleted');
      await qr.manager.delete(AiModel, { id: 102 });
    } finally {
      await release(qr);
    }
    const result = await op;
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toBeInstanceOf(NotFoundException);
    expect(await defaults(1)).toEqual([101]);
  });
});
