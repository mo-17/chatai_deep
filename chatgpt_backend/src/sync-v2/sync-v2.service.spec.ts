import { BadRequestException } from '@nestjs/common';
import { SyncV2EventEntity } from './sync-v2-event.entity';
import { SyncV2HeadEntity } from './sync-v2-head.entity';
import { SyncV2ReceiptEntity } from './sync-v2-receipt.entity';
import { SyncV2Service } from './sync-v2.service';
import {
  SyncV2EventWrite,
  SyncV2HeadWrite,
  SyncV2ReceiptWrite,
  SyncV2Store,
  SyncV2Transaction,
} from './sync-v2.store';
import type { PushSyncV2Dto, SyncV2ChangeDto } from './dto/sync-v2.dto';

const uuid = (value: number) =>
  `00000000-0000-4000-8000-${value.toString().padStart(12, '0')}`;

const deviceId = uuid(9000);

function change(
  value: number,
  overrides: Partial<SyncV2ChangeDto & { parentChangeId?: string | null }> = {},
): SyncV2ChangeDto & { parentChangeId?: string | null } {
  return {
    changeId: uuid(value),
    entity: 'conversation',
    syncId: uuid(value + 1000),
    revision: '1',
    op: 'upsert',
    payload: { localId: 1, title: `title-${value}` },
    ...overrides,
  };
}

function body(changes: SyncV2ChangeDto[]): PushSyncV2Dto {
  return { deviceId, changes };
}

class MemorySyncV2Store implements SyncV2Store {
  events: SyncV2EventEntity[] = [];
  heads: SyncV2HeadEntity[] = [];
  receipts: SyncV2ReceiptEntity[] = [];
  nextSequence = 1;
  failOnSaveReceipt = false;

  async transaction<T>(
    action: (tx: SyncV2Transaction) => Promise<T>,
  ): Promise<T> {
    const snapshot = {
      events: this.events.map((row) => ({ ...row })),
      heads: this.heads.map((row) => ({ ...row })),
      receipts: this.receipts.map((row) => ({ ...row })),
      nextSequence: this.nextSequence,
    };
    try {
      return await action(new MemorySyncV2Transaction(this));
    } catch (error) {
      this.events = snapshot.events;
      this.heads = snapshot.heads;
      this.receipts = snapshot.receipts;
      this.nextSequence = snapshot.nextSequence;
      throw error;
    }
  }

  pullEvents(
    userId: number,
    cursor: string,
    limit: number,
  ): Promise<SyncV2EventEntity[]> {
    const after = BigInt(cursor);
    return Promise.resolve(
      this.events
        .filter((row) => row.userId === userId && BigInt(row.sequence) > after)
        .sort((a, b) => (BigInt(a.sequence) < BigInt(b.sequence) ? -1 : 1))
        .slice(0, limit),
    );
  }
}

class MemorySyncV2Transaction implements SyncV2Transaction {
  constructor(private readonly store: MemorySyncV2Store) {}

  lock(_keys: string[]): Promise<void> {
    return Promise.resolve();
  }

  findReceipt(
    userId: number,
    changeId: string,
  ): Promise<SyncV2ReceiptEntity | null> {
    return Promise.resolve(
      this.store.receipts.find(
        (row) => row.userId === userId && row.changeId === changeId,
      ) ?? null,
    );
  }

  findHead(
    userId: number,
    entity: string,
    syncId: string,
  ): Promise<SyncV2HeadEntity | null> {
    return Promise.resolve(
      this.store.heads.find(
        (row) =>
          row.userId === userId &&
          row.entity === entity &&
          row.syncId === syncId,
      ) ?? null,
    );
  }

  findEvent(
    userId: number,
    sequence: string,
  ): Promise<SyncV2EventEntity | null> {
    return Promise.resolve(
      this.store.events.find(
        (row) => row.userId === userId && row.sequence === sequence,
      ) ?? null,
    );
  }

  appendEvent(write: SyncV2EventWrite): Promise<SyncV2EventEntity> {
    const event = {
      ...write,
      sequence: String(this.store.nextSequence++),
      serverCreatedAt: new Date(),
    };
    this.store.events.push(event);
    return Promise.resolve(event);
  }

  async saveHead(write: SyncV2HeadWrite): Promise<SyncV2HeadEntity> {
    const existing = await this.findHead(
      write.userId,
      write.entity,
      write.syncId,
    );
    if (existing) {
      Object.assign(existing, write, { updatedAt: new Date() });
      return existing;
    }
    const head = {
      ...write,
      id: String(this.store.heads.length + 1),
      updatedAt: new Date(),
    };
    this.store.heads.push(head);
    return head;
  }

  saveReceipt(write: SyncV2ReceiptWrite): Promise<SyncV2ReceiptEntity> {
    if (this.store.failOnSaveReceipt) {
      return Promise.reject(new Error('receipt write failed'));
    }
    const receipt = {
      ...write,
      id: String(this.store.receipts.length + 1),
      createdAt: new Date(),
    };
    this.store.receipts.push(receipt);
    return Promise.resolve(receipt);
  }
}

describe('SyncV2Service', () => {
  it('把两台设备相同本地数字 ID、不同 syncId 保存成两个实体', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);

    const result = await service.push(
      7,
      body([
        change(1, { syncId: uuid(101), payload: { localId: 1 } }),
        change(2, { syncId: uuid(102), payload: { localId: 1 } }),
      ]),
    );

    expect(result.acks.map((ack) => ack.result)).toEqual([
      'accepted',
      'accepted',
    ]);
    expect(store.heads.map((row) => row.syncId)).toEqual([
      uuid(101),
      uuid(102),
    ]);
  });

  it('精确重复 changeId 返回首次 ACK 且只创建一个 event', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const request = body([change(10)]);

    const first = await service.push(7, request);
    const retry = await service.push(7, request);

    expect(first.acks[0]).toMatchObject({
      result: 'accepted',
      duplicate: false,
      sequence: '1',
    });
    expect(retry.acks[0]).toMatchObject({
      result: 'accepted',
      duplicate: true,
      sequence: '1',
    });
    expect(store.events).toHaveLength(1);
    expect(store.receipts).toHaveLength(1);
  });

  it('同一 changeId 内容变化返回 change_id_reused 且不覆盖 receipt', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    await service.push(7, body([change(20)]));

    const result = await service.push(
      7,
      body([change(20, { payload: { title: 'changed' } })]),
    );

    expect(result.acks[0]).toMatchObject({
      result: 'rejected',
      reason: 'change_id_reused',
      duplicate: false,
    });
    expect(store.events).toHaveLength(1);
    expect(store.receipts).toHaveLength(1);
  });

  it('同批重复的 reused changeId 都不是 receipt replay', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    await service.push(7, body([change(21)]));
    const reused = change(21, { payload: { title: 'changed twice' } });

    const result = await service.push(7, body([reused, { ...reused }]));

    expect(result.acks).toEqual([
      expect.objectContaining({
        result: 'rejected',
        reason: 'change_id_reused',
        duplicate: false,
      }),
      expect.objectContaining({
        result: 'rejected',
        reason: 'change_id_reused',
        duplicate: false,
      }),
    ]);
    expect(store.receipts).toHaveLength(1);
  });

  it('reused current head 不阻断指向原 accepted head 的合法后继', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(2201);
    const currentHead = change(22, { syncId });
    await service.push(7, body([currentHead]));

    const result = await service.push(
      7,
      body([
        change(22, {
          syncId,
          payload: { title: 'illegal reused head' },
        }),
        change(23, {
          syncId,
          revision: '2',
          parentChangeId: currentHead.changeId,
        }),
      ]),
    );

    expect(result.acks).toEqual([
      expect.objectContaining({
        changeId: uuid(22),
        result: 'rejected',
        reason: 'change_id_reused',
      }),
      expect.objectContaining({
        changeId: uuid(23),
        result: 'accepted',
        sequence: '2',
      }),
    ]);
    expect(store.events).toHaveLength(2);
    expect(store.heads[0]).toMatchObject({
      revision: '2',
      changeId: uuid(23),
    });
  });

  it('同批 stale revision 冲突不阻断后续独立变更', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const existingSyncId = uuid(3001);
    await service.push(7, body([change(30, { syncId: existingSyncId })]));

    const result = await service.push(
      7,
      body([
        change(31, { syncId: existingSyncId, revision: '1' }),
        change(32, { syncId: uuid(3002), revision: '1' }),
      ]),
    );

    expect(result.acks).toEqual([
      expect.objectContaining({
        changeId: uuid(31),
        result: 'conflict',
        reason: 'remote_ahead',
        expectedRevision: '2',
      }),
      expect.objectContaining({
        changeId: uuid(32),
        result: 'accepted',
      }),
    ]);
    expect(store.events).toHaveLength(2);
    expect(store.receipts).toHaveLength(3);
  });

  it('同实体祖先 revision 冲突后阻断更高 revision', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(3301);
    await service.push(7, body([change(33, { syncId, revision: '1' })]));
    await service.push(
      7,
      body([
        change(34, {
          syncId,
          revision: '2',
          parentChangeId: uuid(33),
        }),
      ]),
    );

    const result = await service.push(
      7,
      body([
        change(35, {
          syncId,
          revision: '2',
          payload: { title: 'conflicting local ancestor' },
        }),
        change(36, {
          syncId,
          revision: '3',
          parentChangeId: uuid(35),
          payload: { title: 'depends on rejected revision 2' },
        }),
      ]),
    );

    expect(result.acks).toEqual([
      expect.objectContaining({
        changeId: uuid(35),
        result: 'conflict',
        reason: 'remote_ahead',
      }),
      expect.objectContaining({
        changeId: uuid(36),
        result: 'blocked',
        reason: 'blocked_by_ancestor',
        expectedRevision: '3',
      }),
    ]);
    expect(store.events).toHaveLength(2);
    expect(store.heads[0]).toMatchObject({ revision: '2', eventSequence: '2' });
  });

  it('同实体无关 stale 失败不阻断指向当前 head 的合法后继', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(3701);
    const currentHead = change(37, { syncId });
    await service.push(7, body([currentHead]));

    const result = await service.push(
      7,
      body([
        change(38, {
          syncId,
          revision: '1',
          payload: { title: 'unrelated stale write' },
        }),
        change(39, {
          syncId,
          revision: '2',
          parentChangeId: currentHead.changeId,
        }),
      ]),
    );

    expect(result.acks).toEqual([
      expect.objectContaining({
        changeId: uuid(38),
        result: 'conflict',
        reason: 'remote_ahead',
      }),
      expect.objectContaining({
        changeId: uuid(39),
        result: 'accepted',
        sequence: '2',
      }),
    ]);
    expect(store.events).toHaveLength(2);
    expect(store.heads[0]).toMatchObject({
      revision: '2',
      changeId: uuid(39),
    });
  });

  it('revision gap 返回精确 expectedRevision', async () => {
    const service = new SyncV2Service(new MemorySyncV2Store());

    const result = await service.push(7, body([change(40, { revision: '3' })]));

    expect(result.acks[0]).toMatchObject({
      result: 'rejected',
      reason: 'revision_gap',
      expectedRevision: '1',
      remote: null,
    });
  });

  it('新实体 revision 1 必须没有 parentChangeId', async () => {
    const service = new SyncV2Service(new MemorySyncV2Store());

    await expect(
      service.push(7, body([change(41, { parentChangeId: uuid(999) })])),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  it('跨批 revision=head+1 但 parent 不是当前 head 时仍被阻断', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(4201);
    await service.push(7, body([change(42, { syncId })]));
    await service.push(
      7,
      body([
        change(43, {
          syncId,
          revision: '2',
          parentChangeId: uuid(42),
        }),
      ]),
    );
    await service.push(
      7,
      body([
        change(44, {
          syncId,
          revision: '2',
          parentChangeId: uuid(42),
          payload: { title: 'losing revision 2' },
        }),
      ]),
    );

    const blockedRequest = body([
      change(45, {
        syncId,
        revision: '3',
        parentChangeId: uuid(44),
      }),
    ]);
    const result = await service.push(7, blockedRequest);
    const retry = await service.push(7, blockedRequest);

    expect(result.acks[0]).toMatchObject({
      result: 'blocked',
      duplicate: false,
      reason: 'blocked_by_ancestor',
      expectedRevision: '3',
      remote: { changeId: uuid(43), revision: '2' },
    });
    expect(retry.acks[0]).toMatchObject({
      result: 'blocked',
      duplicate: true,
      reason: 'blocked_by_ancestor',
      remote: { changeId: uuid(43), revision: '2' },
    });
    expect(store.events).toHaveLength(2);
    expect(store.heads[0]).toMatchObject({
      revision: '2',
      changeId: uuid(43),
    });
  });

  it('revision_gap receipt 重试仍返回 rejected', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const request = body([change(46, { revision: '3' })]);

    const first = await service.push(7, request);
    const retry = await service.push(7, request);

    expect(first.acks[0]).toMatchObject({
      result: 'rejected',
      duplicate: false,
      reason: 'revision_gap',
    });
    expect(retry.acks[0]).toMatchObject({
      result: 'rejected',
      duplicate: true,
      reason: 'revision_gap',
    });
    expect(store.receipts).toHaveLength(1);
  });

  it('跨批 parent 指向 rejected receipt 时返回 blocked', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(4701);
    await service.push(7, body([change(47, { syncId, revision: '3' })]));

    const result = await service.push(
      7,
      body([
        change(48, {
          syncId,
          revision: '4',
          parentChangeId: uuid(47),
        }),
      ]),
    );

    expect(result.acks[0]).toMatchObject({
      result: 'blocked',
      duplicate: false,
      reason: 'blocked_by_ancestor',
      expectedRevision: '1',
      remote: null,
    });
    expect(store.events).toHaveLength(0);
    expect(store.receipts).toHaveLength(2);
  });

  it('delete tombstone 阻止较旧 upsert 复活', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(5001);
    await service.push(7, body([change(50, { syncId })]));
    await service.push(
      7,
      body([
        change(51, {
          syncId,
          revision: '2',
          parentChangeId: uuid(50),
          op: 'delete',
          payload: undefined,
        }),
      ]),
    );

    const stale = await service.push(
      7,
      body([change(52, { syncId, revision: '1' })]),
    );

    expect(stale.acks[0]).toMatchObject({
      result: 'conflict',
      reason: 'remote_ahead',
      remote: { revision: '2', op: 'delete', payload: null },
    });
    expect(store.heads[0]).toMatchObject({ revision: '2', op: 'delete' });
  });

  it('冲突 receipt 重试返回首次 remote 快照而不是后来 head', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(6001);
    await service.push(7, body([change(60, { syncId })]));
    const conflictRequest = body([
      change(61, { syncId, revision: '1', payload: { title: 'loser' } }),
    ]);
    const firstConflict = await service.push(7, conflictRequest);
    await service.push(
      7,
      body([
        change(62, {
          syncId,
          revision: '2',
          parentChangeId: uuid(60),
        }),
      ]),
    );

    const retry = await service.push(7, conflictRequest);

    expect(firstConflict.acks[0]).toMatchObject({
      remote: { sequence: '1', revision: '1' },
    });
    expect(retry.acks[0]).toMatchObject({
      result: 'conflict',
      duplicate: true,
      remote: { sequence: '1', revision: '1' },
    });
  });

  it('canonical hash 不包含可变 deviceId', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const request = body([change(65)]);
    await service.push(7, request);

    const retry = await service.push(7, {
      ...request,
      deviceId: uuid(9001),
    });

    expect(retry.acks[0]).toMatchObject({
      result: 'accepted',
      duplicate: true,
      sequence: '1',
    });
    expect(store.events).toHaveLength(1);
  });

  it('同实体连续 revision 按因果顺序处理但 ACK 保持原请求顺序', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const syncId = uuid(7001);
    const revision1 = change(71, { syncId, revision: '1' });
    const revision2 = change(70, {
      syncId,
      revision: '2',
      parentChangeId: revision1.changeId,
    });

    const result = await service.push(7, body([revision2, revision1]));

    expect(result.acks.map((ack) => ack.changeId)).toEqual([
      revision2.changeId,
      revision1.changeId,
    ]);
    expect(result.acks).toEqual([
      expect.objectContaining({
        result: 'accepted',
        sequence: '2',
        parentChangeId: revision1.changeId,
      }),
      expect.objectContaining({
        result: 'accepted',
        sequence: '1',
        parentChangeId: null,
      }),
    ]);
    expect(store.events.map((event) => event.revision)).toEqual(['1', '2']);
  });

  it('pull 按 server sequence、limit+1 分页并按 userId 隔离', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    await service.push(1, body([change(80)]));
    await service.push(2, body([change(81)]));
    await service.push(1, body([change(82)]));

    const first = await service.pull(1, '0', 1);
    const second = await service.pull(1, first.cursor, 1);

    expect(first).toMatchObject({ cursor: '1', hasMore: true });
    expect(first.changes.map((row) => row.sequence)).toEqual(['1']);
    expect(second).toMatchObject({ cursor: '3', hasMore: false });
    expect(second.changes.map((row) => row.sequence)).toEqual(['3']);
  });

  it('pull 按响应体积截断大 payload 并保留 hasMore', async () => {
    const store = new MemorySyncV2Store();
    const service = new SyncV2Service(store);
    const large = 'x'.repeat(500_000);
    for (let index = 0; index < 9; index += 1) {
      await service.push(
        7,
        body([change(200 + index, { payload: { large } })]),
      );
    }

    const result = await service.pull(7, '0', 20);

    expect(result.changes.length).toBeGreaterThan(0);
    expect(result.changes.length).toBeLessThan(9);
    expect(result.hasMore).toBe(true);
  });

  it('push 响应不包含 pull cursor', async () => {
    const service = new SyncV2Service(new MemorySyncV2Store());

    const result = await service.push(7, body([change(90)]));

    expect(result).not.toHaveProperty('cursor');
    expect(result).toHaveProperty('acks');
  });

  it('event/head/receipt 任一步失败时回滚整个数据库事务', async () => {
    const store = new MemorySyncV2Store();
    store.failOnSaveReceipt = true;
    const service = new SyncV2Service(store);

    await expect(service.push(7, body([change(100)]))).rejects.toThrow(
      'receipt write failed',
    );
    expect(store.events).toEqual([]);
    expect(store.heads).toEqual([]);
    expect(store.receipts).toEqual([]);
  });

  it('拒绝非规范 revision、非法 UUID、未知 entity 和 delete payload', async () => {
    const service = new SyncV2Service(new MemorySyncV2Store());
    const invalid = [
      change(110, { revision: '01' }),
      change(111, { changeId: 'not-a-uuid' }),
      change(112, { entity: 'unknown' as never }),
      change(113, { op: 'delete', payload: { should: 'not exist' } }),
    ];

    for (const item of invalid) {
      await expect(service.push(7, body([item]))).rejects.toBeInstanceOf(
        BadRequestException,
      );
    }
  });

  it('capabilities 明确为 shadow、不可激活且 bootstrap 尚不可用', () => {
    const service = new SyncV2Service(new MemorySyncV2Store());

    const capabilities = service.capabilities();
    expect(capabilities).toMatchObject({
      protocol: 2,
      mode: 'shadow',
      shadowOnly: true,
      activationEnabled: false,
      bootstrapAvailable: false,
      requiresMigration: true,
      limits: { maxChanges: 500 },
    });
    expect(capabilities.entities).toContain('conversation');
    expect(capabilities.entities).toContain('assistant_memory');
  });
});
