import 'dart:async';

import 'package:chatgpt_app_core/sync/v2/sync_v2_conflict_store.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_entity_state.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_transaction.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_uuid.dart';
import 'package:sqflite/sqflite.dart';

enum SyncV2OutboxFailurePoint { beforeOutboxInsert }

typedef SyncV2OutboxFailureHook = FutureOr<void> Function(
  SyncV2OutboxFailurePoint point,
);

class SyncV2Outbox {
  SyncV2Outbox({
    SyncV2UuidGenerator? uuidGenerator,
    int Function()? nowProvider,
    SyncV2OutboxFailureHook? failureHook,
  })  : _uuidGenerator = uuidGenerator ?? SyncV2Uuid.generate,
        _nowProvider =
            nowProvider ?? (() => DateTime.now().millisecondsSinceEpoch),
        _failureHook = failureHook;

  final SyncV2UuidGenerator _uuidGenerator;
  final int Function() _nowProvider;
  final SyncV2OutboxFailureHook? _failureHook;

  Future<SyncV2OutboxEntry> enqueueUpsert({
    required DatabaseExecutor executor,
    required SyncV2Entity entity,
    required String syncId,
    required String localKey,
    required Map<String, dynamic> payload,
  }) {
    // async transaction 开始前就截断调用方对嵌套 Map/List 的后续修改。
    final snapshot = SyncV2OutboxEntry.snapshotUpsertPayload(payload);
    return _enqueue(
      executor: executor,
      entity: entity,
      syncId: syncId,
      localKey: localKey,
      operation: SyncV2Operation.upsert,
      payload: snapshot,
    );
  }

  Future<SyncV2OutboxEntry> enqueueDelete({
    required DatabaseExecutor executor,
    required SyncV2Entity entity,
    required String syncId,
    required String localKey,
  }) =>
      _enqueue(
        executor: executor,
        entity: entity,
        syncId: syncId,
        localKey: localKey,
        operation: SyncV2Operation.delete,
        payload: null,
      );

  Future<SyncV2OutboxEntry> _enqueue({
    required DatabaseExecutor executor,
    required SyncV2Entity entity,
    required String syncId,
    required String localKey,
    required SyncV2Operation operation,
    required Map<String, dynamic>? payload,
  }) =>
      SyncV2Transaction.run(
        executor,
        (txn) => _enqueueInTransaction(
          txn: txn,
          entity: entity,
          syncId: syncId,
          localKey: localKey,
          operation: operation,
          payload: payload,
        ),
      );

  Future<SyncV2OutboxEntry> _enqueueInTransaction({
    required DatabaseExecutor txn,
    required SyncV2Entity entity,
    required String syncId,
    required String localKey,
    required SyncV2Operation operation,
    required Map<String, dynamic>? payload,
  }) async {
    final stateStore = SyncV2EntityStateStore(nowProvider: _nowProvider);
    final current = await stateStore.ensureForMutation(
      txn,
      entity: entity,
      syncId: syncId,
      localKey: localKey,
    );
    final parentChangeId = current.localHeadChangeId ?? current.serverChangeId;
    final terminalAncestor = await _findBlockingAncestor(
      txn,
      entity: entity,
      syncId: syncId,
      parentChangeId: parentChangeId,
    );
    final changeId = SyncV2Uuid.require(_uuidGenerator(), 'generated changeId');
    final revision = current.localRevision + 1;
    final now = _now();
    final state = terminalAncestor == null
        ? SyncV2OutboxState.pending
        : SyncV2OutboxState.blocked;
    final expectedRevision = terminalAncestor == null
        ? null
        : terminalAncestor.expectedRevision ?? current.serverRevision + 1;
    final candidate = SyncV2OutboxEntry(
      changeId: changeId,
      entity: entity,
      syncId: syncId,
      parentChangeId: parentChangeId,
      revision: revision,
      operation: operation,
      payload: payload,
      state: state,
      attempts: 0,
      lastError: null,
      ackReason: terminalAncestor == null ? null : 'blocked_by_ancestor',
      expectedRevision: expectedRevision,
      createdAt: now,
      updatedAt: now,
    );
    // 统一走严格 row parser，调用方传入的嵌套 JSON 也必须可持久化。
    final entry = SyncV2OutboxEntry.fromDatabaseRow(
      candidate.toDatabaseRow(),
    );
    await stateStore.advanceLocalHead(
      txn,
      current: current,
      changeId: changeId,
      operation: operation,
      revision: revision,
      updatedAt: now,
    );
    await _runFailureHook(SyncV2OutboxFailurePoint.beforeOutboxInsert);
    await txn.insert(SyncV2Schema.outboxTable, entry.toDatabaseRow());
    return entry;
  }

  Future<List<SyncV2OutboxEntry>> loadPending(
    DatabaseExecutor db, {
    int? limit,
  }) async {
    if (limit != null && limit <= 0) {
      throw ArgumentError.value(limit, 'limit', '必须大于 0');
    }
    final rows = await db.query(
      SyncV2Schema.outboxTable,
      where: 'state = ?',
      whereArgs: [SyncV2OutboxState.pending.wireName],
      orderBy: 'createdAt asc, revision asc, changeId asc',
      limit: limit,
    );
    return rows.map(SyncV2OutboxEntry.fromDatabaseRow).toList(growable: false);
  }

  Future<List<SyncV2OutboxEntry>> loadAll(DatabaseExecutor db) async {
    final rows = await db.query(
      SyncV2Schema.outboxTable,
      orderBy: 'createdAt asc, revision asc, changeId asc',
    );
    return rows.map(SyncV2OutboxEntry.fromDatabaseRow).toList(growable: false);
  }

  Future<void> applyAcks(
    DatabaseExecutor executor,
    Iterable<SyncV2PushAck> acks,
  ) async {
    final validated = acks.toList(growable: false);
    for (final ack in validated) {
      ack.validate();
    }
    await SyncV2Transaction.run(
      executor,
      (txn) => _applyAcksInTransaction(txn, validated),
    );
  }

  Future<void> _applyAcksInTransaction(
    DatabaseExecutor txn,
    Iterable<SyncV2PushAck> acks,
  ) async {
    final stateStore = SyncV2EntityStateStore(nowProvider: _nowProvider);
    final conflictStore = SyncV2ConflictStore(nowProvider: _nowProvider);
    for (final ack in acks) {
      final rows = await txn.query(
        SyncV2Schema.outboxTable,
        where: 'changeId = ?',
        whereArgs: [ack.changeId],
        limit: 1,
      );
      if (rows.isEmpty) {
        if (ack.result == SyncV2AckResult.accepted) continue;
        throw StateError('未知 changeId 不能建立本地 ACK 终态');
      }
      final entry = SyncV2OutboxEntry.fromDatabaseRow(rows.single);
      _requireMatchingAck(entry, ack);
      if (entry.state != SyncV2OutboxState.pending) {
        await _applyTerminalReplay(
          conflictStore,
          txn,
          entry: entry,
          ack: ack,
        );
        continue;
      }
      switch (ack.result) {
        case SyncV2AckResult.accepted:
          await stateStore.recordAccepted(txn, entry: entry);
          final deleted = await txn.delete(
            SyncV2Schema.outboxTable,
            where: 'changeId = ? and state = ?',
            whereArgs: [
              entry.changeId,
              SyncV2OutboxState.pending.wireName,
            ],
          );
          if (deleted != 1) throw StateError('accepted outbox 未精确删除');
          break;
        case SyncV2AckResult.conflict:
          await _setTerminalState(txn, entry, ack);
          await _blockDescendants(
            txn,
            entry,
            expectedRevision: ack.expectedRevision!,
          );
          await conflictStore.recordRemoteAhead(
            txn,
            ack: ack,
            localPayload: entry.payload,
          );
          break;
        case SyncV2AckResult.rejected:
          await _setTerminalState(txn, entry, ack);
          if (ack.reason != 'change_id_reused') {
            await _blockDescendants(
              txn,
              entry,
              expectedRevision: ack.expectedRevision!,
            );
          }
          break;
        case SyncV2AckResult.blocked:
          await _setTerminalState(txn, entry, ack);
          await _blockDescendants(
            txn,
            entry,
            expectedRevision: ack.expectedRevision!,
          );
          break;
      }
    }
  }

  Future<void> markAttemptFailed(
    DatabaseExecutor db,
    String changeId,
    Object error,
  ) async {
    final changed = await db.rawUpdate(
      '''
        update ${SyncV2Schema.outboxTable}
        set attempts = attempts + 1, lastError = ?, updatedAt = ?
        where changeId = ? and state = ?
      ''',
      [
        _safeError(error),
        _now(),
        changeId,
        SyncV2OutboxState.pending.wireName,
      ],
    );
    if (changed != 1) throw StateError('pending outbox change 不存在');
  }

  Future<void> _setTerminalState(
    DatabaseExecutor db,
    SyncV2OutboxEntry entry,
    SyncV2PushAck ack,
  ) async {
    final state = _stateForResult(ack.result);
    final changed = await db.update(
      SyncV2Schema.outboxTable,
      {
        'state': state.wireName,
        'lastError': null,
        'ackReason': ack.reason,
        'expectedRevision': ack.expectedRevision,
        'ackRemoteEvidence': ack.remoteEvidence,
        'updatedAt': _now(),
      },
      where: 'changeId = ? and state = ?',
      whereArgs: [entry.changeId, SyncV2OutboxState.pending.wireName],
    );
    if (changed != 1) throw StateError('pending outbox CAS 转终态失败');
  }

  Future<void> _blockDescendants(
    DatabaseExecutor db,
    SyncV2OutboxEntry root, {
    required int expectedRevision,
  }) async {
    final rows = await db.query(
      SyncV2Schema.outboxTable,
      where: 'entity = ? and syncId = ? and state = ?',
      whereArgs: [
        root.entity.wireName,
        root.syncId,
        SyncV2OutboxState.pending.wireName,
      ],
      orderBy: 'revision asc, changeId asc',
    );
    final remaining =
        rows.map(SyncV2OutboxEntry.fromDatabaseRow).toList(growable: true);
    final blockedIds = <String>{root.changeId};
    while (true) {
      final next = remaining
          .where((entry) =>
              entry.parentChangeId != null &&
              blockedIds.contains(entry.parentChangeId))
          .toList(growable: false);
      if (next.isEmpty) break;
      final nextIds = next.map((entry) => entry.changeId).toSet();
      for (final entry in next) {
        final changed = await db.update(
          SyncV2Schema.outboxTable,
          {
            'state': SyncV2OutboxState.blocked.wireName,
            'lastError': null,
            'ackReason': 'blocked_by_ancestor',
            'expectedRevision': expectedRevision,
            'ackRemoteEvidence': null,
            'updatedAt': _now(),
          },
          where: 'changeId = ? and state = ?',
          whereArgs: [
            entry.changeId,
            SyncV2OutboxState.pending.wireName,
          ],
        );
        if (changed != 1) {
          throw StateError('pending descendant CAS 转 blocked 失败');
        }
        blockedIds.add(entry.changeId);
      }
      remaining.removeWhere((entry) => nextIds.contains(entry.changeId));
    }
  }

  Future<SyncV2OutboxEntry?> _findBlockingAncestor(
    DatabaseExecutor db, {
    required SyncV2Entity entity,
    required String syncId,
    required String? parentChangeId,
  }) async {
    var cursor = parentChangeId;
    final visited = <String>{};
    while (cursor != null) {
      if (!visited.add(cursor)) {
        throw StateError('outbox parentChangeId 存在环');
      }
      final rows = await db.query(
        SyncV2Schema.outboxTable,
        where: 'changeId = ? and entity = ? and syncId = ?',
        whereArgs: [cursor, entity.wireName, syncId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final entry = SyncV2OutboxEntry.fromDatabaseRow(rows.single);
      if (entry.state == SyncV2OutboxState.rejected &&
          entry.ackReason == 'change_id_reused') {
        return null;
      }
      if (entry.state != SyncV2OutboxState.pending) return entry;
      cursor = entry.parentChangeId;
    }
    return null;
  }

  Future<void> _applyTerminalReplay(
    SyncV2ConflictStore conflictStore,
    DatabaseExecutor db, {
    required SyncV2OutboxEntry entry,
    required SyncV2PushAck ack,
  }) async {
    if (ack.result == SyncV2AckResult.accepted) {
      throw StateError('accepted ACK 不得覆盖已有 outbox 终态');
    }
    final expectedState = _stateForResult(ack.result);
    if (entry.state != expectedState ||
        entry.ackReason != ack.reason ||
        entry.expectedRevision != ack.expectedRevision) {
      throw StateError('同一 changeId 对应不同 ACK 终态');
    }
    final evidence = ack.remoteEvidence;
    if (entry.ackRemoteEvidence == null) {
      if (entry.state != SyncV2OutboxState.blocked) {
        throw StateError('非 blocked 终态缺少 remote evidence');
      }
      final changed = await db.update(
        SyncV2Schema.outboxTable,
        {
          'ackRemoteEvidence': evidence,
          'updatedAt': _now(),
        },
        where: 'changeId = ? and state = ? and ackRemoteEvidence is null',
        whereArgs: [entry.changeId, SyncV2OutboxState.blocked.wireName],
      );
      if (changed != 1) {
        throw StateError('predicted blocked remote evidence CAS 失败');
      }
    } else if (entry.ackRemoteEvidence != evidence) {
      throw StateError('同一 ACK 终态对应不同 remote snapshot');
    }
    if (ack.result == SyncV2AckResult.conflict) {
      await conflictStore.recordRemoteAhead(
        db,
        ack: ack,
        localPayload: entry.payload,
      );
    }
  }

  static SyncV2OutboxState _stateForResult(SyncV2AckResult result) {
    switch (result) {
      case SyncV2AckResult.accepted:
        throw StateError('accepted 不是可持久 outbox 终态');
      case SyncV2AckResult.conflict:
        return SyncV2OutboxState.conflict;
      case SyncV2AckResult.rejected:
        return SyncV2OutboxState.rejected;
      case SyncV2AckResult.blocked:
        return SyncV2OutboxState.blocked;
    }
  }

  static void _requireMatchingAck(
    SyncV2OutboxEntry entry,
    SyncV2PushAck ack,
  ) {
    if (entry.changeId != ack.changeId ||
        entry.entity != ack.entity ||
        entry.syncId != ack.syncId ||
        entry.parentChangeId != ack.parentChangeId ||
        entry.revision != ack.revision) {
      throw const FormatException('ACK 与本地 exact changeId 内容不一致');
    }
  }

  Future<void> _runFailureHook(SyncV2OutboxFailurePoint point) async {
    final hook = _failureHook;
    if (hook != null) await hook(point);
  }

  int _now() {
    final value = _nowProvider();
    if (value < 0) throw StateError('nowProvider 返回负数');
    return value;
  }

  static String _safeError(Object error) => error.runtimeType.toString();
}
