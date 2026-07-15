import dataSource from '../data-source';
import type { PushSyncV2Dto } from './dto/sync-v2.dto';
import { SyncV2Service } from './sync-v2.service';
import { TypeOrmSyncV2Store } from './sync-v2.store';

const describePostgres =
  process.env.SYNC_V2_PG_INTEGRATION === '1' ? describe : describe.skip;

const deviceA = '00000000-0000-4000-8000-000000000001';
const deviceB = '00000000-0000-4000-9000-000000000002';
const syncId = '10000000-0000-4000-8000-000000000001';
const testUserIds = [4101, 4201, 4301, 4401, 4501, 4601];

function request({
  changeId,
  deviceId,
  payload,
  entitySyncId = syncId,
}: {
  changeId: string;
  deviceId: string;
  payload: Record<string, unknown>;
  entitySyncId?: string;
}): PushSyncV2Dto {
  return {
    deviceId,
    changes: [
      {
        changeId,
        entity: 'conversation',
        syncId: entitySyncId,
        parentChangeId: null,
        revision: '1',
        op: 'upsert',
        payload,
      },
    ],
  };
}

describePostgres('SyncV2 PostgreSQL concurrency', () => {
  let store: TypeOrmSyncV2Store;
  let service: SyncV2Service;

  beforeAll(async () => {
    if (!dataSource.isInitialized) await dataSource.initialize();
    store = new TypeOrmSyncV2Store(dataSource);
    service = new SyncV2Service(store);
  });

  beforeEach(async () => {
    await dataSource.query(
      `INSERT INTO "users" ("id", "userName")
       SELECT test_user_id, 'sync-v2-pg-' || test_user_id::text
       FROM unnest($1::int[]) AS test_user_id
       ON CONFLICT ("id") DO NOTHING`,
      [testUserIds],
    );
  });

  afterEach(async () => {
    await dataSource.query(
      'TRUNCATE TABLE sync_v2_receipts, sync_v2_heads, sync_v2_events ' +
        'RESTART IDENTITY CASCADE',
    );
    await dataSource.query('DELETE FROM "users" WHERE "id" = ANY($1::int[])', [
      testUserIds,
    ]);
  });

  afterAll(async () => {
    if (dataSource.isInitialized) await dataSource.destroy();
  });

  it('serializes concurrent first revisions for the same entity head', async () => {
    const [left, right] = await Promise.all([
      service.push(
        4101,
        request({
          changeId: '20000000-0000-4000-8000-000000000001',
          deviceId: deviceA,
          payload: { title: 'left' },
        }),
      ),
      service.push(
        4101,
        request({
          changeId: '20000000-0000-4000-9000-000000000002',
          deviceId: deviceB,
          payload: { title: 'right' },
        }),
      ),
    ]);

    const acks = [left.acks[0], right.acks[0]];
    expect(acks.map((ack) => ack.result).sort()).toEqual([
      'accepted',
      'conflict',
    ]);
    expect(await dataSource.query('SELECT * FROM sync_v2_events')).toHaveLength(
      1,
    );
    expect(await dataSource.query('SELECT * FROM sync_v2_heads')).toHaveLength(
      1,
    );
    expect(
      await dataSource.query('SELECT * FROM sync_v2_receipts'),
    ).toHaveLength(2);
  });

  it('replays one durable receipt for concurrent duplicate changeId', async () => {
    const body = request({
      changeId: '30000000-0000-4000-8000-000000000001',
      deviceId: deviceA,
      payload: { title: 'same' },
    });

    const [left, right] = await Promise.all([
      service.push(4201, body),
      service.push(4201, body),
    ]);

    const acks = [left.acks[0], right.acks[0]];
    expect(acks.every((ack) => ack.result === 'accepted')).toBe(true);
    expect(acks.map((ack) => ack.duplicate).sort()).toEqual([false, true]);
    expect(await dataSource.query('SELECT * FROM sync_v2_events')).toHaveLength(
      1,
    );
    expect(
      await dataSource.query('SELECT * FROM sync_v2_receipts'),
    ).toHaveLength(1);
  });

  it('rolls back an event when the surrounding transaction fails', async () => {
    await expect(
      store.transaction(async (transaction) => {
        await transaction.appendEvent({
          userId: 4301,
          changeId: '40000000-0000-4000-8000-000000000001',
          entity: 'conversation',
          syncId,
          parentChangeId: null,
          revision: '1',
          op: 'upsert',
          payload: { title: 'rollback' },
          deviceId: deviceA,
        });
        throw new Error('injected rollback');
      }),
    ).rejects.toThrow('injected rollback');

    expect(await dataSource.query('SELECT * FROM sync_v2_events')).toHaveLength(
      0,
    );
  });

  it('enforces receipt reason checks in the real schema', async () => {
    await expect(
      dataSource.query(
        `INSERT INTO sync_v2_receipts (
          user_id, change_id, request_hash, entity, sync_id,
          parent_change_id, revision, op, result, reason,
          expected_revision, accepted_sequence, remote_sequence
        ) VALUES ($1, $2, $3, $4, $5, NULL, 1, 'upsert',
          'rejected', NULL, 1, NULL, NULL)`,
        [
          4401,
          '50000000-0000-4000-8000-000000000001',
          '0'.repeat(64),
          'conversation',
          syncId,
        ],
      ),
    ).rejects.toThrow();
  });

  it('rejects an accepted receipt that points at another change event', async () => {
    const firstChangeId = '60000000-0000-4000-8000-000000000001';
    const secondChangeId = '60000000-0000-4000-9000-000000000002';
    await service.push(
      4501,
      request({
        changeId: firstChangeId,
        deviceId: deviceA,
        payload: { title: 'first' },
      }),
    );
    await service.push(
      4501,
      request({
        changeId: secondChangeId,
        deviceId: deviceB,
        entitySyncId: '10000000-0000-4000-9000-000000000002',
        payload: { title: 'second' },
      }),
    );
    const [otherEvent] = await dataSource.query<Array<{ sequence: string }>>(
      'SELECT sequence FROM sync_v2_events WHERE user_id=$1 AND change_id=$2',
      [4501, secondChangeId],
    );

    await expect(
      dataSource.query(
        `UPDATE sync_v2_receipts SET accepted_sequence=$1
         WHERE user_id=$2 AND change_id=$3`,
        [otherEvent.sequence, 4501, firstChangeId],
      ),
    ).rejects.toThrow();
  });

  it('deleting a user cascades all sync v2 rows without FK conflicts', async () => {
    await service.push(
      4601,
      request({
        changeId: '70000000-0000-4000-8000-000000000001',
        deviceId: deviceA,
        payload: { title: 'delete-account' },
      }),
    );

    await dataSource.query('DELETE FROM "users" WHERE "id"=$1', [4601]);

    for (const table of [
      'sync_v2_events',
      'sync_v2_heads',
      'sync_v2_receipts',
    ]) {
      const [{ count }] = await dataSource.query<Array<{ count: number }>>(
        `SELECT count(*)::int AS count FROM ${table} WHERE user_id=$1`,
        [4601],
      );
      expect(count).toBe(0);
    }
  });
});
