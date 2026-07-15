import 'dart:convert';

import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:sqflite/sqflite.dart';

class SyncV2ConflictStore {
  SyncV2ConflictStore({int Function()? nowProvider})
      : _nowProvider =
            nowProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _nowProvider;

  Future<SyncV2Conflict> recordRemoteAhead(
    DatabaseExecutor db, {
    required SyncV2PushAck ack,
    required Map<String, dynamic>? localPayload,
  }) async {
    ack.validate();
    if (ack.result != SyncV2AckResult.conflict ||
        ack.reason != 'remote_ahead' ||
        ack.remote == null) {
      throw const FormatException('只有完整 remote_ahead ACK 可建立冲突');
    }
    final localSnapshot = _snapshotJsonObject(localPayload);
    final existing = await _findByChangeId(db, ack.changeId);
    if (existing != null) {
      if (!_sameSnapshot(existing, ack, localSnapshot)) {
        throw StateError('同一 conflict changeId 对应不同 snapshot');
      }
      return existing;
    }
    final now = _now();
    final remote = ack.remote!;
    await db.insert(SyncV2Schema.conflictTable, {
      'changeId': ack.changeId,
      'entity': ack.entity.wireName,
      'syncId': ack.syncId,
      'reason': ack.reason,
      'localPayload': localSnapshot == null ? null : jsonEncode(localSnapshot),
      'remoteSequence': remote.sequence,
      'remoteChangeId': remote.changeId,
      'remoteParentChangeId': remote.parentChangeId,
      'remoteRevision': remote.revision,
      'remoteOp': remote.operation.wireName,
      'remotePayload':
          remote.payload == null ? null : jsonEncode(remote.payload),
      'remoteDeviceId': remote.deviceId,
      'createdAt': now,
      'resolvedAt': null,
      'resolution': null,
    });
    return (await _findByChangeId(db, ack.changeId))!;
  }

  static bool _sameSnapshot(
    SyncV2Conflict existing,
    SyncV2PushAck ack,
    Map<String, dynamic>? localPayload,
  ) {
    final remote = ack.remote!;
    return existing.changeId == ack.changeId &&
        existing.entity == ack.entity &&
        existing.syncId == ack.syncId &&
        existing.reason == ack.reason &&
        _jsonDeepEquals(existing.localPayload, localPayload) &&
        existing.remoteSequence == remote.sequence &&
        existing.remoteChangeId == remote.changeId &&
        existing.remoteParentChangeId == remote.parentChangeId &&
        existing.remoteRevision == remote.revision &&
        existing.remoteOperation == remote.operation &&
        _jsonDeepEquals(existing.remotePayload, remote.payload) &&
        existing.remoteDeviceId == remote.deviceId;
  }

  Future<List<SyncV2Conflict>> loadUnresolved(DatabaseExecutor db) async {
    final rows = await db.query(
      SyncV2Schema.conflictTable,
      where: 'resolvedAt is null',
      orderBy: 'createdAt asc, id asc',
    );
    return rows.map(SyncV2Conflict.fromDatabaseRow).toList(growable: false);
  }

  Future<void> resolve(
    DatabaseExecutor db,
    String changeId,
    SyncV2ConflictResolution resolution,
  ) async {
    final changed = await db.update(
      SyncV2Schema.conflictTable,
      {
        'resolvedAt': _now(),
        'resolution': resolution.wireName,
      },
      where: 'changeId = ? and resolvedAt is null',
      whereArgs: [changeId],
    );
    if (changed != 1) throw StateError('冲突不存在或已处理');
  }

  Future<SyncV2Conflict?> _findByChangeId(
    DatabaseExecutor db,
    String changeId,
  ) async {
    final rows = await db.query(
      SyncV2Schema.conflictTable,
      where: 'changeId = ?',
      whereArgs: [changeId],
      limit: 1,
    );
    return rows.isEmpty ? null : SyncV2Conflict.fromDatabaseRow(rows.single);
  }

  int _now() {
    final value = _nowProvider();
    if (value < 0) throw StateError('nowProvider 返回负数');
    return value;
  }

  static Map<String, dynamic>? _snapshotJsonObject(
    Map<String, dynamic>? value,
  ) {
    if (value == null) return null;
    final decoded = jsonDecode(jsonEncode(value));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('localPayload 必须是 JSON object');
    }
    return decoded;
  }

  static bool _jsonDeepEquals(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_jsonDeepEquals(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!_jsonDeepEquals(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }
}
