import 'dart:convert';

import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_transaction.dart';
import 'package:sqflite/sqflite.dart';

class SyncV2Inbox {
  SyncV2Inbox({int Function()? nowProvider})
      : _nowProvider =
            nowProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowProvider;

  Future<void> persist(
    DatabaseExecutor executor,
    Iterable<SyncV2RemoteChange> changes,
  ) =>
      SyncV2Transaction.run(
        executor,
        (txn) => _persistInTransaction(txn, changes),
      );

  Future<void> _persistInTransaction(
    DatabaseExecutor txn,
    Iterable<SyncV2RemoteChange> changes,
  ) async {
    final receivedAt = _now();
    for (final change in changes) {
      final byServerId = await txn.query(
        SyncV2Schema.inboxTable,
        where: 'serverId = ?',
        whereArgs: [change.sequence],
        limit: 1,
      );
      final byChangeId = await txn.query(
        SyncV2Schema.inboxTable,
        where: 'changeId = ?',
        whereArgs: [change.changeId],
        limit: 1,
      );
      if (byServerId.isNotEmpty || byChangeId.isNotEmpty) {
        final existing = SyncV2InboxEntry.fromDatabaseRow(
          byServerId.isNotEmpty ? byServerId.single : byChangeId.single,
        );
        if (!_same(existing, change)) {
          throw const FormatException('inbox serverId/changeId 被不同内容复用');
        }
        continue;
      }
      await txn.insert(SyncV2Schema.inboxTable, {
        'serverId': change.sequence,
        'changeId': change.changeId,
        'entity': change.entity.wireName,
        'syncId': change.syncId,
        'parentChangeId': change.parentChangeId,
        'revision': change.revision,
        'op': change.operation.wireName,
        'payload': change.payload == null ? null : jsonEncode(change.payload),
        'state': SyncV2InboxState.pending.wireName,
        'lastError': null,
        'receivedAt': receivedAt,
        'appliedAt': null,
      });
    }
  }

  Future<List<SyncV2InboxEntry>> loadPending(DatabaseExecutor db) async {
    final rows = await db.query(
      SyncV2Schema.inboxTable,
      where: 'state = ?',
      whereArgs: [SyncV2InboxState.pending.wireName],
      orderBy: 'serverId asc',
    );
    return rows.map(SyncV2InboxEntry.fromDatabaseRow).toList(growable: false);
  }

  Future<List<SyncV2InboxEntry>> loadAll(DatabaseExecutor db) async {
    final rows = await db.query(
      SyncV2Schema.inboxTable,
      orderBy: 'serverId asc',
    );
    return rows.map(SyncV2InboxEntry.fromDatabaseRow).toList(growable: false);
  }

  Future<void> markApplied(
    DatabaseExecutor db,
    String changeId, {
    int? appliedAt,
  }) async {
    final changed = await db.update(
      SyncV2Schema.inboxTable,
      {
        'state': SyncV2InboxState.applied.wireName,
        'lastError': null,
        'appliedAt': appliedAt ?? _now(),
      },
      where: 'changeId = ? and state = ?',
      whereArgs: [changeId, SyncV2InboxState.pending.wireName],
    );
    if (changed != 1) throw StateError('inbox change 不存在或已应用');
  }

  Future<void> markFailed(
    DatabaseExecutor db,
    String changeId,
    Object error,
  ) async {
    final changed = await db.update(
      SyncV2Schema.inboxTable,
      {'lastError': _safeError(error)},
      where: 'changeId = ? and state = ?',
      whereArgs: [changeId, SyncV2InboxState.pending.wireName],
    );
    if (changed != 1) throw StateError('inbox change 不存在或已应用');
  }

  int _now() {
    final value = _nowProvider();
    if (value < 0) throw StateError('nowProvider 返回负数');
    return value;
  }

  static bool _same(SyncV2InboxEntry local, SyncV2RemoteChange remote) =>
      local.serverId == remote.sequence &&
      local.changeId == remote.changeId &&
      local.entity == remote.entity &&
      local.syncId == remote.syncId &&
      local.parentChangeId == remote.parentChangeId &&
      local.revision == remote.revision &&
      local.operation == remote.operation &&
      _jsonEquals(local.payload, remote.payload);

  static bool _jsonEquals(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_jsonEquals(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_jsonEquals(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }

  static String _safeError(Object error) => error.runtimeType.toString();
}
