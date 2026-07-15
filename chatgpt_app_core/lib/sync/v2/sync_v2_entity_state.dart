import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_uuid.dart';
import 'package:sqflite/sqflite.dart';

class SyncV2EntityStateStore {
  SyncV2EntityStateStore({
    SyncV2UuidGenerator? uuidGenerator,
    int Function()? nowProvider,
  })  : _uuidGenerator = uuidGenerator ?? SyncV2Uuid.generate,
        _nowProvider =
            nowProvider ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncV2UuidGenerator _uuidGenerator;
  final int Function() _nowProvider;

  Future<SyncV2EntityState?> findBySyncId(
    DatabaseExecutor db,
    SyncV2Entity entity,
    String syncId,
  ) async {
    SyncV2Uuid.require(syncId, 'syncId');
    final rows = await db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ? and syncId = ?',
      whereArgs: [entity.wireName, syncId],
      limit: 1,
    );
    return rows.isEmpty ? null : SyncV2EntityState.fromDatabaseRow(rows.single);
  }

  Future<SyncV2EntityState?> findByLocalKey(
    DatabaseExecutor db,
    SyncV2Entity entity,
    String localKey,
  ) async {
    final normalized = _requireLocalKey(localKey);
    final rows = await db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ? and localKey = ?',
      whereArgs: [entity.wireName, normalized],
      limit: 1,
    );
    return rows.isEmpty ? null : SyncV2EntityState.fromDatabaseRow(rows.single);
  }

  /// 为 shadow/test namespace 回填身份。返回 `(state, created)`。
  Future<({SyncV2EntityState state, bool created})> ensureShadowIdentity(
    DatabaseExecutor db, {
    required SyncV2Entity entity,
    required String localKey,
  }) async {
    final normalized = _requireLocalKey(localKey);
    final existing = await findByLocalKey(db, entity, normalized);
    if (existing != null) return (state: existing, created: false);
    final syncId = SyncV2Uuid.require(_uuidGenerator(), 'generated syncId');
    final now = _now();
    await db.insert(SyncV2Schema.entityStateTable, {
      'entity': entity.wireName,
      'syncId': syncId,
      'localKey': normalized,
      'serverRevision': 0,
      'serverChangeId': null,
      'localRevision': 0,
      'localHeadChangeId': null,
      'op': SyncV2Operation.upsert.wireName,
      'updatedAt': now,
    });
    return (
      state: (await findBySyncId(db, entity, syncId))!,
      created: true,
    );
  }

  /// 新建/读取 outbox mutation 所需的 identity state。
  Future<SyncV2EntityState> ensureForMutation(
    DatabaseExecutor db, {
    required SyncV2Entity entity,
    required String syncId,
    required String localKey,
  }) async {
    final normalizedSyncId = SyncV2Uuid.require(syncId, 'syncId');
    final normalizedLocalKey = _requireLocalKey(localKey);
    final bySyncId = await findBySyncId(db, entity, normalizedSyncId);
    if (bySyncId != null) {
      if (bySyncId.localKey != normalizedLocalKey) {
        throw StateError('syncId 已绑定到其他 localKey');
      }
      return bySyncId;
    }
    final byLocalKey = await findByLocalKey(db, entity, normalizedLocalKey);
    if (byLocalKey != null) {
      throw StateError('localKey 已绑定到其他 syncId');
    }
    final now = _now();
    await db.insert(SyncV2Schema.entityStateTable, {
      'entity': entity.wireName,
      'syncId': normalizedSyncId,
      'localKey': normalizedLocalKey,
      'serverRevision': 0,
      'serverChangeId': null,
      'localRevision': 0,
      'localHeadChangeId': null,
      'op': SyncV2Operation.upsert.wireName,
      'updatedAt': now,
    });
    return (await findBySyncId(db, entity, normalizedSyncId))!;
  }

  Future<SyncV2EntityState> advanceLocalHead(
    DatabaseExecutor db, {
    required SyncV2EntityState current,
    required String changeId,
    required SyncV2Operation operation,
    required int revision,
    required int updatedAt,
  }) async {
    SyncV2Uuid.require(changeId, 'changeId');
    if (revision != current.localRevision + 1) {
      throw StateError('outbox revision 未紧接 local head');
    }
    final changed = await db.update(
      SyncV2Schema.entityStateTable,
      {
        'localRevision': revision,
        'localHeadChangeId': changeId,
        'op': operation.wireName,
        'updatedAt': updatedAt,
      },
      where: 'entity = ? and syncId = ? and localRevision = ?',
      whereArgs: [
        current.entity.wireName,
        current.syncId,
        current.localRevision,
      ],
    );
    if (changed != 1) {
      throw StateError('entity state optimistic head 并发变化');
    }
    return (await findBySyncId(db, current.entity, current.syncId))!;
  }

  Future<void> recordAccepted(
    DatabaseExecutor db, {
    required SyncV2OutboxEntry entry,
  }) async {
    final current = await findBySyncId(db, entry.entity, entry.syncId);
    if (current == null) throw StateError('accepted ACK 缺少 entity state');
    if (entry.revision > current.localRevision) {
      throw StateError('accepted revision 超出 local head');
    }
    if (entry.revision < current.serverRevision) return;
    if (entry.revision == current.serverRevision) {
      if (current.serverChangeId != entry.changeId) {
        throw StateError('同一 server revision 对应不同 changeId');
      }
      return;
    }
    final changed = await db.update(
      SyncV2Schema.entityStateTable,
      {
        'serverRevision': entry.revision,
        'serverChangeId': entry.changeId,
        'updatedAt': _now(),
      },
      where: 'entity = ? and syncId = ? and serverRevision = ?',
      whereArgs: [
        entry.entity.wireName,
        entry.syncId,
        current.serverRevision,
      ],
    );
    if (changed != 1) {
      throw StateError('entity state accepted head CAS 失败');
    }
  }

  int _now() {
    final value = _nowProvider();
    if (value < 0) throw StateError('nowProvider 返回负数');
    return value;
  }

  static String _requireLocalKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw const FormatException('localKey 必须是 1..512 字符');
    }
    return normalized;
  }
}
