import 'dart:async';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_entity_state.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_models.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_schema.dart';
import 'package:chatgpt_app_core/sync/v2/sync_v2_uuid.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite/sqflite.dart';

class SyncV2ShadowGate {
  const SyncV2ShadowGate({
    this.enabled = false,
    this.shadowSupported = false,
  });

  final bool enabled;
  final bool shadowSupported;

  bool get allowsPreparation => enabled && shadowSupported;
}

enum SyncV2ShadowMigrationStatus { unsupported, guestSkipped, ready }

class SyncV2ShadowMigrationResult {
  const SyncV2ShadowMigrationResult({
    required this.status,
    this.createdIdentities = 0,
    this.totalIdentities = 0,
  });

  final SyncV2ShadowMigrationStatus status;
  final int createdIdentities;
  final int totalIdentities;
}

enum SyncV2ShadowMigrationPoint {
  afterSchema,
  afterIdentityBackfill,
  beforeReadyMarker,
}

typedef SyncV2ShadowMigrationFailureHook = FutureOr<void> Function(
  SyncV2ShadowMigrationPoint point,
);

/// 只准备 shadow/test sidecar，永不写生产 outbox、bootstrap mapping 或 v2 active。
class SyncV2ShadowMigration {
  SyncV2ShadowMigration({
    SyncV2UuidGenerator? uuidGenerator,
    int Function()? nowProvider,
    SyncV2ShadowMigrationFailureHook? failureHook,
  })  : _uuidGenerator = uuidGenerator ?? SyncV2Uuid.generate,
        _nowProvider =
            nowProvider ?? (() => DateTime.now().millisecondsSinceEpoch),
        _failureHook = failureHook;

  static const readyKey = 'protocol_v2_shadow_ready';
  static const namespaceKey = 'protocol_v2_identity_namespace';
  static const _namespaceValue = 'shadow_only_v1';

  final SyncV2UuidGenerator _uuidGenerator;
  final int Function() _nowProvider;
  final SyncV2ShadowMigrationFailureHook? _failureHook;

  Future<SyncV2ShadowMigrationResult> prepare(
    HiDBManager storage, {
    SyncV2ShadowGate gate = const SyncV2ShadowGate(),
    bool? isGuest,
  }) async {
    if (!gate.allowsPreparation) {
      return const SyncV2ShadowMigrationResult(
        status: SyncV2ShadowMigrationStatus.unsupported,
      );
    }
    if (isGuest ?? LoginDao.isGuest()) {
      return const SyncV2ShadowMigrationResult(
        status: SyncV2ShadowMigrationStatus.guestSkipped,
      );
    }

    // rerun 开始前先提交 ready 删除，让其它 reader 不会在 reconcile 期间
    // 把旧 shadow 状态当成可用；后续失败也必须保持不可见。
    await _hideReadyMarker(storage.db);

    return storage.db.transaction((txn) async {
      await SyncV2Schema.ensure(txn);
      await _hook(SyncV2ShadowMigrationPoint.afterSchema);

      final stateStore = SyncV2EntityStateStore(
        uuidGenerator: _uuidGenerator,
        nowProvider: _nowProvider,
      );
      final snapshots = <SyncV2Entity, List<Map<String, Object?>>>{};
      var created = 0;
      var total = 0;
      for (final descriptor in _descriptors) {
        if (!await _tableExists(txn, descriptor.table)) continue;
        final rows = await txn.query(descriptor.table);
        snapshots[descriptor.entity] = rows;
      }
      for (final descriptor in _descriptors) {
        final rows = snapshots[descriptor.entity];
        if (rows == null) continue;
        final liveLocalKeys = <String>{
          for (final row in rows) descriptor.localKey(row),
        };
        await _reconcileOrphanIdentities(
          txn,
          descriptor,
          liveLocalKeys,
        );
        for (final row in rows) {
          final localKey = descriptor.localKey(row);
          final result = await stateStore.ensureShadowIdentity(
            txn,
            entity: descriptor.entity,
            localKey: localKey,
          );
          total++;
          if (result.created) created++;
        }
      }
      await _hook(SyncV2ShadowMigrationPoint.afterIdentityBackfill);

      _validateHardRelationships(snapshots);
      await _validateIdentityCoverage(txn, snapshots, stateStore);
      await _hook(SyncV2ShadowMigrationPoint.beforeReadyMarker);

      await txn.insert(
        SyncV2Schema.stateTable,
        {'key': namespaceKey, 'value': _namespaceValue},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      // ready 必须是事务内最后一笔写入；异常或进程中断不会留下半成品 marker。
      await txn.insert(
        SyncV2Schema.stateTable,
        {'key': readyKey, 'value': '1'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return SyncV2ShadowMigrationResult(
        status: SyncV2ShadowMigrationStatus.ready,
        createdIdentities: created,
        totalIdentities: total,
      );
    });
  }

  Future<void> _validateIdentityCoverage(
    DatabaseExecutor db,
    Map<SyncV2Entity, List<Map<String, Object?>>> snapshots,
    SyncV2EntityStateStore stateStore,
  ) async {
    for (final descriptor in _descriptors) {
      final rows = snapshots[descriptor.entity];
      if (rows == null) continue;
      final seen = <String>{};
      for (final row in rows) {
        final localKey = descriptor.localKey(row);
        if (!seen.add(localKey)) {
          throw StateError('${descriptor.entity.wireName} localKey 重复');
        }
        final state = await stateStore.findByLocalKey(
          db,
          descriptor.entity,
          localKey,
        );
        if (state == null) {
          throw StateError('${descriptor.entity.wireName}:$localKey 影子身份缺失');
        }
      }
    }
  }

  static Future<void> _reconcileOrphanIdentities(
    DatabaseExecutor db,
    _ShadowEntityDescriptor descriptor,
    Set<String> liveLocalKeys,
  ) async {
    final states = await db.query(
      SyncV2Schema.entityStateTable,
      where: 'entity = ?',
      whereArgs: [descriptor.entity.wireName],
    );
    for (final state in states) {
      final localKey = '${state['localKey']}';
      if (liveLocalKeys.contains(localKey)) continue;
      final hasHistory = state['serverRevision'] != 0 ||
          state['localRevision'] != 0 ||
          state['serverChangeId'] != null ||
          state['localHeadChangeId'] != null;
      if (hasHistory) {
        throw StateError(
          '${descriptor.entity.wireName}:$localKey orphan identity 含同步历史',
        );
      }
      final deleted = await db.delete(
        SyncV2Schema.entityStateTable,
        where: 'entity = ? and localKey = ? '
            'and serverRevision = 0 and localRevision = 0 '
            'and serverChangeId is null and localHeadChangeId is null',
        whereArgs: [descriptor.entity.wireName, localKey],
      );
      if (deleted != 1) {
        throw StateError(
          '${descriptor.entity.wireName}:$localKey orphan identity 并发变化',
        );
      }
    }
  }

  static void _validateHardRelationships(
    Map<SyncV2Entity, List<Map<String, Object?>>> snapshots,
  ) {
    final conversationIds = _singleKeys(
      snapshots[SyncV2Entity.conversation],
      'cid',
    );
    for (final row in snapshots[SyncV2Entity.message] ?? const []) {
      final cid = _positiveKey(row['cid'], 'message.cid');
      if (!conversationIds.contains(cid)) {
        throw StateError('message.cid 缺少 conversation parent: $cid');
      }
    }

    final docIds = _singleKeys(
      snapshots[SyncV2Entity.knowledgeDoc],
      'id',
    );
    for (final row in snapshots[SyncV2Entity.knowledgeChunk] ?? const []) {
      final docId = _positiveKey(row['docId'], 'knowledge_chunk.docId');
      if (!docIds.contains(docId)) {
        throw StateError('knowledge_chunk.docId 缺少 parent: $docId');
      }
    }

    final projectIds = _singleKeys(
      snapshots[SyncV2Entity.project],
      'id',
    );
    for (final row in snapshots[SyncV2Entity.projectKnowledge] ?? const []) {
      final projectId =
          _positiveKey(row['projectId'], 'project_knowledge.projectId');
      final docId = _positiveKey(row['docId'], 'project_knowledge.docId');
      if (!projectIds.contains(projectId) || !docIds.contains(docId)) {
        throw StateError('project_knowledge 缺少 project/doc parent');
      }
    }
  }

  static Set<String> _singleKeys(
    List<Map<String, Object?>>? rows,
    String column,
  ) =>
      {
        for (final row in rows ?? const <Map<String, Object?>>[])
          _positiveKey(row[column], column),
      };

  static Future<bool> _tableExists(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery(
      "select 1 from sqlite_master where type = 'table' and name = ? limit 1",
      [table],
    );
    return rows.isNotEmpty;
  }

  static Future<void> _hideReadyMarker(DatabaseExecutor db) async {
    if (!await _tableExists(db, SyncV2Schema.stateTable)) return;
    await db.delete(
      SyncV2Schema.stateTable,
      where: 'key = ?',
      whereArgs: [readyKey],
    );
  }

  Future<void> _hook(SyncV2ShadowMigrationPoint point) async {
    final hook = _failureHook;
    if (hook != null) await hook(point);
  }
}

class _ShadowEntityDescriptor {
  const _ShadowEntityDescriptor(
    this.entity,
    this.table,
    this.keyColumns,
  );

  final SyncV2Entity entity;
  final String table;
  final List<String> keyColumns;

  String localKey(Map<String, Object?> row) => keyColumns
      .map((column) => _positiveKey(row[column], '$table.$column'))
      .join(':');
}

const _descriptors = <_ShadowEntityDescriptor>[
  _ShadowEntityDescriptor(SyncV2Entity.assistant, 'tb_assistant', ['id']),
  _ShadowEntityDescriptor(SyncV2Entity.project, 'tb_project', ['id']),
  _ShadowEntityDescriptor(
    SyncV2Entity.knowledgeDoc,
    'tb_kb_doc',
    ['id'],
  ),
  _ShadowEntityDescriptor(
    SyncV2Entity.conversation,
    'tb_conversation_list',
    ['cid'],
  ),
  _ShadowEntityDescriptor(
    SyncV2Entity.knowledgeChunk,
    'tb_kb_chunk',
    ['id'],
  ),
  _ShadowEntityDescriptor(
    SyncV2Entity.assistantMemory,
    'tb_assistant_memory',
    ['id'],
  ),
  _ShadowEntityDescriptor(SyncV2Entity.message, 'tb_messages', ['id']),
  _ShadowEntityDescriptor(SyncV2Entity.favorite, 'tb_favorite', ['id']),
  _ShadowEntityDescriptor(
    SyncV2Entity.projectKnowledge,
    'tb_project_kb',
    ['projectId', 'docId'],
  ),
];

String _positiveKey(Object? raw, String field) {
  final value = raw is int ? raw : int.tryParse('$raw');
  if (value == null || value <= 0) {
    throw StateError('$field 必须是正整数 local key');
  }
  return '$value';
}
