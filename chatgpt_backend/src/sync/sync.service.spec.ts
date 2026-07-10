import { SyncService } from './sync.service';
import { SyncChangeEntity } from './sync-change.entity';

type Where = Partial<Pick<SyncChangeEntity, 'userId' | 'entity' | 'entityId'>>;

class FakeSyncRepo {
  rows: SyncChangeEntity[] = [];
  nextId = 1;

  create(data: Partial<SyncChangeEntity>) {
    return data as SyncChangeEntity;
  }

  save(entity: SyncChangeEntity) {
    const row = {
      ...entity,
      id: this.nextId++,
      createdAt: new Date(),
    };
    this.rows.push(row);
    return Promise.resolve(row);
  }

  findOne(options: { where: Where; order: { id: 'DESC' } }) {
    const { where } = options;
    const row =
      this.rows
        .filter((row) => this.matches(row, where))
        .sort((a, b) => b.id - a.id)[0] ?? null;
    return Promise.resolve(row);
  }

  find(options: {
    where: { userId: number; id: { _value: number } };
    order: { id: 'ASC' };
    take: number;
  }) {
    const rows = this.rows
      .filter(
        (row) =>
          row.userId === options.where.userId &&
          row.id > Number(options.where.id._value),
      )
      .sort((a, b) => a.id - b.id)
      .slice(0, options.take);
    return Promise.resolve(rows);
  }

  private matches(row: SyncChangeEntity, where: Where) {
    return Object.entries(where).every(
      ([key, value]) => row[key as keyof Where] === value,
    );
  }
}

describe('SyncService', () => {
  it('push 接受新变更并可按游标 pull', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);

    const pushed = await service.push(7, [
      {
        entity: 'conversation',
        entityId: 'c1',
        op: 'upsert',
        updatedAt: 1000,
        payload: { title: 'hello' },
      },
    ]);

    expect(pushed.accepted).toHaveLength(1);
    expect(pushed.accepted[0]).not.toHaveProperty('payload');
    expect(pushed.conflicts).toEqual([]);
    const pulled = await service.pull(7, 0, 20);
    expect(pulled.cursor).toBe(1);
    expect(pulled.changes[0]).toMatchObject({
      id: 1,
      entity: 'conversation',
      entityId: 'c1',
      updatedAt: 1000,
      payload: { title: 'hello' },
    });
  });

  it('远端更新时拒绝旧时间戳，本地新时间戳覆盖', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);
    await service.push(7, [
      {
        entity: 'message',
        entityId: 'm1',
        op: 'upsert',
        updatedAt: 2000,
        payload: { text: 'remote' },
      },
    ]);

    const stale = await service.push(7, [
      {
        entity: 'message',
        entityId: 'm1',
        op: 'upsert',
        updatedAt: 1000,
        payload: { text: 'old' },
      },
    ]);
    expect(stale.accepted).toEqual([]);
    expect(stale.conflicts).toMatchObject([
      { entity: 'message', entityId: 'm1', reason: 'remote_newer' },
    ]);

    const newer = await service.push(7, [
      {
        entity: 'message',
        entityId: 'm1',
        op: 'upsert',
        updatedAt: 3000,
        payload: { text: 'local' },
      },
    ]);
    expect(newer.accepted).toHaveLength(1);
    const pulled = await service.pull(7, 1, 20);
    expect(pulled.changes).toHaveLength(1);
    expect(pulled.changes[0].payload).toEqual({ text: 'local' });
  });

  it('相同时间戳但内容不同会返回冲突', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);
    await service.push(7, [
      {
        entity: 'assistant',
        entityId: 'a1',
        op: 'upsert',
        updatedAt: 1000,
        payload: { name: 'A' },
      },
    ]);

    const result = await service.push(7, [
      {
        entity: 'assistant',
        entityId: 'a1',
        op: 'upsert',
        updatedAt: 1000,
        payload: { name: 'B' },
      },
    ]);

    expect(result.accepted).toEqual([]);
    expect(result.conflicts).toMatchObject([
      { entity: 'assistant', entityId: 'a1', reason: 'same_timestamp' },
    ]);
  });

  it('用户之间互相隔离', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);
    await service.push(1, [
      {
        entity: 'conversation',
        entityId: 'same',
        op: 'upsert',
        updatedAt: 1000,
        payload: { user: 1 },
      },
    ]);
    await service.push(2, [
      {
        entity: 'conversation',
        entityId: 'same',
        op: 'upsert',
        updatedAt: 500,
        payload: { user: 2 },
      },
    ]);

    expect((await service.pull(1)).changes).toHaveLength(1);
    expect((await service.pull(2)).changes).toHaveLength(1);
    expect((await service.pull(2)).changes[0].payload).toEqual({ user: 2 });
  });

  it('pull 按 limit 分页返回 hasMore 与下一页游标', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);
    await service.push(7, [
      {
        entity: 'conversation',
        entityId: 'c1',
        op: 'upsert',
        updatedAt: 1000,
        payload: { title: '1' },
      },
      {
        entity: 'conversation',
        entityId: 'c2',
        op: 'upsert',
        updatedAt: 1001,
        payload: { title: '2' },
      },
      {
        entity: 'conversation',
        entityId: 'c3',
        op: 'upsert',
        updatedAt: 1002,
        payload: { title: '3' },
      },
    ]);

    const firstPage = await service.pull(7, 0, 2);
    expect(firstPage.hasMore).toBe(true);
    expect(firstPage.cursor).toBe(2);
    expect(firstPage.changes.map((change) => change.entityId)).toEqual([
      'c1',
      'c2',
    ]);

    const secondPage = await service.pull(7, firstPage.cursor, 2);
    expect(secondPage.hasMore).toBe(false);
    expect(secondPage.cursor).toBe(3);
    expect(secondPage.changes.map((change) => change.entityId)).toEqual(['c3']);
  });

  it('pull 对非法 cursor/limit 容错，并限制单页最多 500 条', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);
    const changes = Array.from({ length: 501 }, (_, index) => ({
      entity: 'message',
      entityId: `m${index}`,
      op: 'upsert' as const,
      updatedAt: 1000 + index,
      payload: { index },
    }));
    await service.push(7, changes.slice(0, 500));
    await service.push(7, changes.slice(500));

    const fallback = await service.pull(7, Number.NaN, 0);
    expect(fallback.hasMore).toBe(true);
    expect(fallback.cursor).toBe(200);
    expect(fallback.changes).toHaveLength(200);

    const capped = await service.pull(7, -1, 999);
    expect(capped.hasMore).toBe(true);
    expect(capped.changes).toHaveLength(500);
    expect(capped.cursor).toBe(500);
  });

  it('拒绝越界或身份不匹配的角色卡资源分块', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);

    await expect(
      service.push(7, [
        {
          entity: 'assistant_role_asset_chunk',
          entityId: '1:0:0',
          op: 'upsert',
          updatedAt: 1000,
          payload: {
            assistantId: 2,
            assetIndex: 0,
            chunkIndex: 0,
            totalChunks: 1,
            assetCount: 1,
            assistantUpdatedAt: 1000,
            metadata: { type: 'background' },
            base64: 'AQID',
          },
        },
      ]),
    ).rejects.toThrow('角色卡资源分块不合法');
  });

  it('pull 按 JSON 体积分页，大资源块不会一次全部返回', async () => {
    const repo = new FakeSyncRepo();
    const service = new SyncService(repo as never);
    const payload = 'x'.repeat(260_000);
    for (let i = 0; i < 20; i += 1) {
      await repo.save(
        repo.create({
          userId: 7,
          entity: 'large_test',
          entityId: `${i}`,
          op: 'upsert',
          updatedAt: `${1000 + i}`,
          payload: { payload },
          deviceId: null,
        }),
      );
    }

    const first = await service.pull(7, 0, 200);
    expect(first.changes.length).toBeGreaterThan(0);
    expect(first.changes.length).toBeLessThan(20);
    expect(first.hasMore).toBe(true);

    const second = await service.pull(7, first.cursor, 200);
    expect(second.changes[0].id).toBe(first.cursor + 1);
  });
});
