import 'package:chatgpt_app_core/sync/v2/sync_v2_transaction.dart';
import 'package:sqflite/sqflite.dart';

/// Sync v2 的本地 sidecar schema。
///
/// 本类不会被 `DbMigration` 自动调用；core-only 阶段只允许 shadow migration
/// 在显式 gate 下创建，避免旧用户无意切换协议。
class SyncV2Schema {
  SyncV2Schema._();

  static const outboxTable = 'tb_sync_outbox';
  static const inboxTable = 'tb_sync_inbox';
  static const conflictTable = 'tb_sync_conflict';
  static const entityStateTable = 'tb_sync_entity_state';
  static const stateTable = 'tb_sync_state';

  static const tableNames = <String>[
    outboxTable,
    inboxTable,
    conflictTable,
    entityStateTable,
    stateTable,
  ];

  static const indexNames = <String>[
    'idx_sync_outbox_pending_order',
    'idx_sync_outbox_entity_revision',
    'idx_sync_inbox_pending_order',
    'idx_sync_inbox_entity_revision',
    'idx_sync_conflict_unresolved',
    'idx_sync_entity_state_local_key',
  ];

  static const _entityCheck = "entity in ('project','assistant',"
      "'conversation','message','favorite','knowledge_doc',"
      "'knowledge_chunk','project_knowledge','assistant_memory')";

  static Future<void> ensure(DatabaseExecutor executor) =>
      SyncV2Transaction.run(
        executor,
        (txn) => _ensureInTransaction(txn),
      );

  static Future<void> _ensureInTransaction(DatabaseExecutor db) async {
    await db.execute('''
      create table if not exists $outboxTable (
        changeId text primary key,
        entity text not null check ($_entityCheck),
        syncId text not null,
        parentChangeId text,
        revision integer not null check (revision >= 1),
        op text not null check (op in ('upsert', 'delete')),
        payload text,
        state text not null default 'pending'
          check (state in ('pending', 'conflict', 'rejected', 'blocked')),
        attempts integer not null default 0 check (attempts >= 0),
        lastError text,
        ackReason text,
        expectedRevision integer,
        ackRemoteEvidence text,
        createdAt integer not null check (createdAt >= 0),
        updatedAt integer not null check (updatedAt >= 0),
        check ((op = 'upsert' and payload is not null) or
               (op = 'delete' and payload is null)),
        check (expectedRevision is null or expectedRevision >= 1),
        check (
          (state = 'pending' and ackReason is null and
           expectedRevision is null and ackRemoteEvidence is null) or
          (state = 'conflict' and ackReason is not null and
           ackReason = 'remote_ahead' and
           expectedRevision is not null and ackRemoteEvidence is not null) or
          (state = 'rejected' and ackReason is not null and
            ((ackReason = 'revision_gap' and expectedRevision is not null) or
             (ackReason = 'change_id_reused' and
              expectedRevision is null)) and
           ackRemoteEvidence is not null) or
          (state = 'blocked' and ackReason is not null and
           ackReason = 'blocked_by_ancestor' and
           expectedRevision is not null)
        ),
        check (state = 'pending' or lastError is null)
      )
    ''');
    await db.execute('''
      create table if not exists $inboxTable (
        serverId integer primary key check (serverId >= 1),
        changeId text not null unique,
        entity text not null check ($_entityCheck),
        syncId text not null,
        parentChangeId text,
        revision integer not null check (revision >= 1),
        op text not null check (op in ('upsert', 'delete')),
        payload text,
        state text not null default 'pending'
          check (state in ('pending', 'applied')),
        lastError text,
        receivedAt integer not null check (receivedAt >= 0),
        appliedAt integer,
        check (appliedAt is null or appliedAt >= 0),
        check ((op = 'upsert' and payload is not null) or
               (op = 'delete' and payload is null))
      )
    ''');
    await db.execute('''
      create table if not exists $conflictTable (
        id integer primary key autoincrement,
        changeId text not null unique,
        entity text not null check ($_entityCheck),
        syncId text not null,
        reason text not null,
        localPayload text,
        remoteSequence integer not null check (remoteSequence >= 1),
        remoteChangeId text not null,
        remoteParentChangeId text,
        remoteRevision integer not null check (remoteRevision >= 1),
        remoteOp text not null check (remoteOp in ('upsert', 'delete')),
        remotePayload text,
        remoteDeviceId text not null,
        createdAt integer not null check (createdAt >= 0),
        resolvedAt integer,
        resolution text check (
          resolution is null or
          resolution in ('keep_local', 'use_remote', 'keep_both')
        ),
        check (resolvedAt is null or resolvedAt >= 0),
        check ((resolvedAt is null and resolution is null) or
               (resolvedAt is not null and resolution is not null)),
        check (reason = 'remote_ahead'),
        check ((remoteOp = 'upsert' and remotePayload is not null) or
               (remoteOp = 'delete' and remotePayload is null))
      )
    ''');
    await db.execute('''
      create table if not exists $entityStateTable (
        entity text not null check ($_entityCheck),
        syncId text not null,
        localKey text,
        serverRevision integer not null check (serverRevision >= 0),
        serverChangeId text,
        localRevision integer not null check (localRevision >= 0),
        localHeadChangeId text,
        op text not null check (op in ('upsert', 'delete')),
        updatedAt integer not null check (updatedAt >= 0),
        primary key(entity, syncId),
        check (localRevision >= serverRevision),
        check ((serverRevision = 0 and serverChangeId is null) or
               (serverRevision > 0 and serverChangeId is not null)),
        check ((localRevision = 0 and localHeadChangeId is null) or
               (localRevision > 0 and localHeadChangeId is not null))
      )
    ''');
    await db.execute('''
      create table if not exists $stateTable (
        key text primary key,
        value text not null
      )
    ''');

    // 这些表尚未进入正式版，不能为旧实验冲突行伪造远端身份。
    // 遇到弱 schema 直接失败关闭，由上层删除隔离的 shadow data 后重建。
    await _requireBaselineColumns(db, outboxTable, const {
      'changeId',
      'entity',
      'syncId',
      'parentChangeId',
      'revision',
      'op',
      'payload',
      'state',
      'attempts',
      'lastError',
      'ackReason',
      'expectedRevision',
      'ackRemoteEvidence',
      'createdAt',
      'updatedAt',
    });
    await _requireBaselineColumns(db, conflictTable, const {
      'id',
      'changeId',
      'entity',
      'syncId',
      'reason',
      'localPayload',
      'remoteSequence',
      'remoteChangeId',
      'remoteParentChangeId',
      'remoteRevision',
      'remoteOp',
      'remotePayload',
      'remoteDeviceId',
      'createdAt',
      'resolvedAt',
      'resolution',
    });

    await db.execute('''
      create index if not exists idx_sync_outbox_pending_order
      on $outboxTable(state, createdAt, revision, changeId)
    ''');
    await db.execute('''
      create unique index if not exists idx_sync_outbox_entity_revision
      on $outboxTable(entity, syncId, revision)
    ''');
    await db.execute('''
      create index if not exists idx_sync_inbox_pending_order
      on $inboxTable(state, serverId)
    ''');
    await db.execute('''
      create unique index if not exists idx_sync_inbox_entity_revision
      on $inboxTable(entity, syncId, revision)
    ''');
    await db.execute('''
      create index if not exists idx_sync_conflict_unresolved
      on $conflictTable(resolvedAt, createdAt, id)
    ''');
    await db.execute('''
      create unique index if not exists idx_sync_entity_state_local_key
      on $entityStateTable(entity, localKey)
      where localKey is not null
    ''');
  }

  static Future<void> _requireBaselineColumns(
    DatabaseExecutor db,
    String table,
    Set<String> required,
  ) async {
    final rows = await db.rawQuery('pragma table_info($table)');
    final actual = rows.map((row) => row['name']).whereType<String>().toSet();
    final missing = required.difference(actual);
    if (missing.isNotEmpty) {
      throw StateError('$table 缺少 Sync v2 baseline 列: ${missing.join(',')}');
    }
  }
}
