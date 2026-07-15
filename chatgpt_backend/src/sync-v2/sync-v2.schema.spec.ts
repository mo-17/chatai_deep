import { getMetadataArgsStorage } from 'typeorm';
import type { QueryRunner } from 'typeorm';
import { CreateSyncV21784000000000 } from '../migrations/1784000000000-CreateSyncV2';
import { SyncV2EventEntity } from './sync-v2-event.entity';
import { SyncV2HeadEntity } from './sync-v2-head.entity';
import { SyncV2ReceiptEntity } from './sync-v2-receipt.entity';

describe('Sync v2 schema contract', () => {
  it('三张 v2 表禁用 synchronize，建表必须由 migration 完成', () => {
    const storage = getMetadataArgsStorage();
    for (const target of [
      SyncV2EventEntity,
      SyncV2HeadEntity,
      SyncV2ReceiptEntity,
    ]) {
      const table = storage.tables.find((item) => item.target === target);
      expect(table?.synchronize).toBe(false);
    }
  });

  it('entity metadata 覆盖三表身份与 parent 字段', () => {
    const storage = getMetadataArgsStorage();
    const columnNames = (target: unknown) =>
      storage.columns
        .filter((column) => column.target === target)
        .map((column) => column.propertyName);

    const eventColumns = columnNames(SyncV2EventEntity);
    const headColumns = columnNames(SyncV2HeadEntity);
    const receiptColumns = columnNames(SyncV2ReceiptEntity);
    for (const column of [
      'userId',
      'changeId',
      'syncId',
      'parentChangeId',
      'revision',
    ]) {
      expect(eventColumns).toContain(column);
    }
    for (const column of ['userId', 'changeId', 'syncId', 'eventSequence']) {
      expect(headColumns).toContain(column);
    }
    for (const column of [
      'requestHash',
      'result',
      'reason',
      'acceptedSequence',
      'remoteSequence',
    ]) {
      expect(receiptColumns).toContain(column);
    }
  });

  it('明确 composite FK 只由 migration 提供，不能用 synchronize 代替 migration', async () => {
    const storage = getMetadataArgsStorage();
    const v2Targets = new Set<unknown>([
      SyncV2EventEntity,
      SyncV2HeadEntity,
      SyncV2ReceiptEntity,
    ]);
    const relations = storage.relations.filter(
      (relation) =>
        typeof relation.target === 'function' && v2Targets.has(relation.target),
    );
    expect(relations).toHaveLength(0);

    const queries: string[] = [];
    const queryRunner = {
      query: jest.fn((sql: string) => {
        queries.push(sql);
        return Promise.resolve();
      }),
    } as unknown as QueryRunner;
    await new CreateSyncV21784000000000().up(queryRunner);
    const sql = queries.join('\n');
    const compactSql = sql.replace(/\s+/g, ' ');

    expect(sql).toContain('FK_sync_v2_events_parent');
    expect(sql).toContain('FK_sync_v2_heads_event');
    expect(sql).toContain('FK_sync_v2_receipts_accepted_event');
    expect(sql).toContain('FK_sync_v2_receipts_remote_event');
    expect(sql).toContain('FK_sync_v2_events_user');
    expect(sql).toContain('FK_sync_v2_heads_user');
    expect(sql).toContain('FK_sync_v2_receipts_user');
    expect(compactSql).toContain(
      '("user_id", "accepted_sequence", "change_id") REFERENCES "sync_v2_events" ("user_id", "sequence", "change_id")',
    );
    expect(sql).toContain(
      "\"result\" IN ('accepted', 'conflict', 'rejected', 'blocked')",
    );
    expect(compactSql).toContain(
      '"result" = \'conflict\' AND "accepted_sequence" IS NULL AND "remote_sequence" IS NOT NULL AND "reason" IS NOT NULL AND "reason" = \'remote_ahead\'',
    );
    expect(compactSql).toContain(
      '"result" = \'rejected\' AND "accepted_sequence" IS NULL AND "reason" IS NOT NULL AND "reason" = \'revision_gap\'',
    );
    expect(compactSql).toContain(
      '"result" = \'blocked\' AND "accepted_sequence" IS NULL AND "reason" IS NOT NULL AND "reason" = \'blocked_by_ancestor\'',
    );
  });
});
