import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';
import 'package:sqflite/sqflite.dart';

/// 本地同步服务：把 SQLite 里的核心业务表转换成可上传的增量变更，
/// 并把服务端下发的变更按 Last-Write-Wins 应用回本机。
///
/// 网络层由 [CloudSyncClient] 负责；这里保持纯 SQLite 合并逻辑，便于离线测试。
class LocalSyncService {
  static const assistantRoleAssetChunkEntity = 'assistant_role_asset_chunk';
  static const _roleAssetChunkBytes = 192 * 1024;
  static const _roleAssetStageTable = 'tb_sync_assistant_role_asset_chunk';
  static const _specs = [
    _SyncEntitySpec(
      entity: 'project',
      table: 'tb_project',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'conversation',
      table: 'tb_conversation_list',
      idColumns: ['cid'],
      timestampColumn: 'updateAt',
    ),
    _SyncEntitySpec(
      entity: 'message',
      table: 'tb_messages',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'assistant',
      table: 'tb_assistant',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'favorite',
      table: 'tb_favorite',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'knowledge_doc',
      table: 'tb_kb_doc',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'knowledge_chunk',
      table: 'tb_kb_chunk',
      idColumns: ['id'],
    ),
    _SyncEntitySpec(
      entity: 'project_knowledge',
      table: 'tb_project_kb',
      idColumns: ['projectId', 'docId'],
    ),
    _SyncEntitySpec(
      entity: 'story_room',
      table: 'tb_story_room',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'story_participant',
      table: 'tb_story_participant',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'story_message',
      table: 'tb_story_message',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'story_artifact',
      table: 'tb_story_artifact',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
    _SyncEntitySpec(
      entity: 'story_artifact_revision',
      table: 'tb_story_artifact_revision',
      idColumns: ['id'],
      timestampColumn: 'createdAt',
    ),
    _SyncEntitySpec(
      entity: 'story_template_translation_task',
      table: 'tb_story_template_translation_task',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
  ];

  final HiDBManager storage;
  final RoleCardAssetDirectoryResolver? roleCardAssetDirectoryResolver;

  const LocalSyncService(
    this.storage, {
    this.roleCardAssetDirectoryResolver,
  });

  Future<List<SyncChange>> exportChanges({int updatedAfter = 0}) async {
    await _ensureTables();
    final changes = <SyncChange>[];
    for (final spec in _specs) {
      final rows = await storage.db.query(
        spec.table,
        where: spec.timestampColumn == null || updatedAfter <= 0
            ? null
            : '${spec.timestampColumn} > ?',
        whereArgs: spec.timestampColumn == null || updatedAfter <= 0
            ? null
            : [updatedAfter],
        orderBy: spec.timestampColumn,
      );
      for (final row in rows) {
        if (spec.entity == 'assistant') {
          changes.addAll(await _assistantChangesFromRow(row));
        } else {
          changes.add(spec.changeFromRow(row));
        }
      }
    }
    final tombstones = await storage.db.query(
      SyncTombstoneStore.tableName,
      where: updatedAfter <= 0 ? null : 'updatedAt > ?',
      whereArgs: updatedAfter <= 0 ? null : [updatedAfter],
      orderBy: 'updatedAt asc',
    );
    for (final row in tombstones) {
      changes.add(SyncChange(
        entity: row['entity'] as String,
        id: '${row['entityId']}',
        op: SyncOp.delete,
        updatedAt: row['updatedAt'] as int,
        payload: const {},
      ));
    }
    changes.sort((a, b) {
      final byTime = a.updatedAt.compareTo(b.updatedAt);
      return byTime == 0 ? a.key.compareTo(b.key) : byTime;
    });
    return changes;
  }

  Future<SyncMergeResult> applyRemoteChanges(
      Iterable<SyncChange> remoteChanges) async {
    await _ensureTables();
    final incoming = remoteChanges.toList(growable: false);
    final accepted = <SyncChange>[];
    final rejectedStale = <SyncChange>[];
    final conflicts = <String>[];
    final deletedAssistantIds = <int>{};
    final upsertedAssistantIds = <int>{};
    final assistantUpsertVersions = <int, int>{};
    final assistantIdsWithChunks = {
      for (final change in incoming)
        if (change.entity == assistantRoleAssetChunkEntity)
          _asInt(change.payload['assistantId']),
    }..removeWhere((id) => id <= 0);

    await storage.db.transaction((txn) async {
      for (final remote in incoming) {
        if (remote.entity == assistantRoleAssetChunkEntity) continue;
        final spec = _specFor(remote.entity);
        if (spec == null) {
          rejectedStale.add(remote);
          continue;
        }
        final currentRows = await txn.query(
          spec.table,
          where: spec.whereClause,
          whereArgs: spec.whereArgs(remote.id),
          limit: 1,
        );
        final current = currentRows.isEmpty ? null : currentRows.first;
        final currentUpdatedAt =
            current == null ? -1 : spec.updatedAtOf(current);
        if (currentUpdatedAt > remote.updatedAt) {
          rejectedStale.add(remote);
          continue;
        }
        final payload = _payloadForApply(remote);
        if (currentUpdatedAt == remote.updatedAt &&
            current != null &&
            !_samePayload(
              current,
              payload,
              spec.idColumns,
              ignoreRoleCardAssets: remote.entity == 'assistant',
            )) {
          conflicts.add(remote.key);
          continue;
        }
        if (remote.op == SyncOp.delete) {
          await txn.delete(
            spec.table,
            where: spec.whereClause,
            whereArgs: spec.whereArgs(remote.id),
          );
        } else if (current == null) {
          await txn.insert(spec.table, payload);
        } else {
          await txn.update(
            spec.table,
            payload,
            where: spec.whereClause,
            whereArgs: spec.whereArgs(remote.id),
          );
        }
        await SyncTombstoneStore.remove(
          txn,
          entity: remote.entity,
          id: remote.id,
        );
        accepted.add(remote);
        if (remote.entity == 'assistant' && remote.op == SyncOp.delete) {
          final id = int.tryParse(remote.id);
          if (id != null && id > 0) deletedAssistantIds.add(id);
        }
        if (remote.entity == 'assistant' && remote.op == SyncOp.upsert) {
          final id = int.tryParse(remote.id);
          if (id != null && id > 0) {
            upsertedAssistantIds.add(id);
            assistantUpsertVersions[id] = remote.updatedAt;
          }
        }
      }
    });

    for (final id in deletedAssistantIds) {
      await AssistantRoleCardAssetStore.delete(
        assistantId: id,
        directoryResolver: roleCardAssetDirectoryResolver,
      );
      await _deleteStagedAssets(id);
    }
    for (final id in upsertedAssistantIds) {
      if (assistantIdsWithChunks.contains(id)) {
        await _deleteOtherStagedAssetVersions(
          id,
          assistantUpsertVersions[id]!,
        );
        continue;
      }
      await AssistantRoleCardAssetStore.delete(
        assistantId: id,
        directoryResolver: roleCardAssetDirectoryResolver,
      );
      await _deleteStagedAssets(id);
    }
    final assetResult = await _applyRoleAssetChunks(incoming);
    accepted.addAll(assetResult.accepted);
    rejectedStale.addAll(assetResult.rejectedStale);

    return SyncMergeResult(
      accepted: accepted,
      rejectedStale: rejectedStale,
      conflicts: conflicts.toSet().toList()..sort(),
    );
  }

  Future<List<SyncChange>> _assistantChangesFromRow(
    Map<String, Object?> row,
  ) async {
    final assistant = _specs
        .firstWhere((spec) => spec.entity == 'assistant')
        .changeFromRow(row);
    final normal = SyncChange(
      entity: assistant.entity,
      id: assistant.id,
      op: assistant.op,
      updatedAt: assistant.updatedAt,
      // 文件引用属于设备本地状态，资源由独立块传输。
      payload: Map<String, dynamic>.from(assistant.payload)
        ..['roleCardAssets'] = '[]',
    );
    final assistantId = int.tryParse(assistant.id);
    if (assistantId == null || assistantId <= 0) return [normal];
    final resources =
        await _loadExportableAssets('${row['roleCardAssets'] ?? ''}');
    if (resources.isEmpty) return [normal];

    final changes = <SyncChange>[normal];
    for (final entry in resources.asMap().entries) {
      final bytes = entry.value.bytes!;
      final totalChunks =
          (bytes.length + _roleAssetChunkBytes - 1) ~/ _roleAssetChunkBytes;
      final metadata = {...entry.value.toJson(), 'size': bytes.length};
      for (var chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        final start = chunkIndex * _roleAssetChunkBytes;
        final end = (start + _roleAssetChunkBytes).clamp(0, bytes.length);
        changes.add(SyncChange(
          entity: assistantRoleAssetChunkEntity,
          id: '$assistantId:${entry.key}:$chunkIndex',
          op: SyncOp.upsert,
          updatedAt: assistant.updatedAt,
          payload: {
            'assistantId': assistantId,
            'assetIndex': entry.key,
            'chunkIndex': chunkIndex,
            'totalChunks': totalChunks,
            'assetCount': resources.length,
            'assistantUpdatedAt': assistant.updatedAt,
            'metadata': metadata,
            'base64': base64Encode(bytes.sublist(start, end)),
          },
        ));
      }
    }
    return changes;
  }

  Future<List<AssistantRoleCardResource>> _loadExportableAssets(
    String raw,
  ) async {
    try {
      final loaded = await AssistantRoleCardAssetStore.load(
        raw,
        directoryResolver: roleCardAssetDirectoryResolver,
      );
      var total = 0;
      final result = <AssistantRoleCardResource>[];
      for (final resource
          in loaded.take(AssistantRoleCardAssetStore.maxAssets)) {
        final bytes = resource.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        if (bytes.length > AssistantRoleCardAssetStore.maxAssetBytes ||
            total + bytes.length > AssistantRoleCardAssetStore.maxTotalBytes) {
          break;
        }
        total += bytes.length;
        result.add(resource);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _payloadForApply(SyncChange remote) {
    final payload = Map<String, dynamic>.from(remote.payload);
    if (remote.entity == 'assistant' && remote.op == SyncOp.upsert) {
      // 远端 payload 不能携带可访问的本机绝对路径。
      payload['roleCardAssets'] = '[]';
    }
    return payload;
  }

  Future<_RoleAssetApplyResult> _applyRoleAssetChunks(
    Iterable<SyncChange> changes,
  ) async {
    final accepted = <SyncChange>[];
    final rejected = <SyncChange>[];
    final candidates = <_RoleAssetChunk>[];
    for (final change in changes) {
      if (change.entity != assistantRoleAssetChunkEntity) continue;
      final chunk = _RoleAssetChunk.tryParse(change);
      if (chunk == null) {
        rejected.add(change);
      } else {
        candidates.add(chunk);
      }
    }
    await storage.db.transaction((txn) async {
      for (final chunk in candidates) {
        final current = await txn.query(
          'tb_assistant',
          columns: const ['updatedAt'],
          where: 'id = ?',
          whereArgs: [chunk.assistantId],
          limit: 1,
        );
        if (current.isEmpty ||
            _asInt(current.single['updatedAt']) != chunk.assistantUpdatedAt) {
          rejected.add(chunk.change);
          continue;
        }
        if (!await _canStageAssetChunk(txn, chunk)) {
          rejected.add(chunk.change);
          continue;
        }
        await txn.insert(
          _roleAssetStageTable,
          chunk.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        accepted.add(chunk.change);
      }
    });
    // 不只处理本轮新到块：若上次完整包因磁盘瞬时错误
    // 写入失败，远端游标已推进，必须从暂存表继续重试。
    for (final key in await _stagedBundleKeys()) {
      final resources = await _completeBundle(key);
      if (resources == null) continue;
      try {
        final manifest = await AssistantRoleCardAssetStore.save(
          assistantId: key.assistantId,
          resources: resources,
          directoryResolver: roleCardAssetDirectoryResolver,
        );
        await storage.db.transaction((txn) async {
          final current = await txn.query(
            'tb_assistant',
            columns: const ['updatedAt'],
            where: 'id = ?',
            whereArgs: [key.assistantId],
            limit: 1,
          );
          if (current.isEmpty ||
              _asInt(current.single['updatedAt']) != key.assistantUpdatedAt) {
            return;
          }
          await txn.update(
            'tb_assistant',
            {'roleCardAssets': manifest},
            where: 'id = ?',
            whereArgs: [key.assistantId],
          );
          await txn.delete(
            _roleAssetStageTable,
            where: 'assistantId = ? and assistantUpdatedAt = ?',
            whereArgs: [key.assistantId, key.assistantUpdatedAt],
          );
        });
      } catch (_) {
        // 保留完整暂存块，后续同步可重试；绝不写入部分资源。
      }
    }
    return _RoleAssetApplyResult(accepted, rejected);
  }

  Future<List<AssistantRoleCardResource>?> _completeBundle(
    _RoleAssetBundleKey key,
  ) async {
    final rows = await storage.db.query(
      _roleAssetStageTable,
      where: 'assistantId = ? and assistantUpdatedAt = ?',
      whereArgs: [key.assistantId, key.assistantUpdatedAt],
      orderBy: 'assetIndex asc, chunkIndex asc',
    );
    if (rows.isEmpty) return null;
    final assetCount = _asInt(rows.first['assetCount']);
    if (assetCount <= 0 || assetCount > AssistantRoleCardAssetStore.maxAssets) {
      return null;
    }
    final resources = <AssistantRoleCardResource>[];
    var totalBytes = 0;
    for (var assetIndex = 0; assetIndex < assetCount; assetIndex++) {
      final assetRows =
          rows.where((row) => _asInt(row['assetIndex']) == assetIndex).toList();
      if (assetRows.isEmpty) {
        return null;
      }
      final totalChunks = _asInt(assetRows.first['totalChunks']);
      if (totalChunks <= 0 || assetRows.length != totalChunks) {
        return null;
      }
      for (var chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        final row = assetRows[chunkIndex];
        if (_asInt(row['chunkIndex']) != chunkIndex ||
            _asInt(row['totalChunks']) != totalChunks ||
            _asInt(row['assetCount']) != assetCount ||
            row['metadata'] != assetRows.first['metadata']) {
          return null;
        }
      }
      try {
        final metadata = jsonDecode(assetRows.first['metadata'] as String);
        if (metadata is! Map) {
          return null;
        }
        final bytes = <int>[];
        for (final row in assetRows) {
          final chunk = base64Decode(row['data'] as String);
          if (chunk.isEmpty || chunk.length > _roleAssetChunkBytes) {
            return null;
          }
          bytes.addAll(chunk);
        }
        if (bytes.length > AssistantRoleCardAssetStore.maxAssetBytes ||
            bytes.length != _asInt(metadata['size'])) {
          return null;
        }
        totalBytes += bytes.length;
        if (totalBytes > AssistantRoleCardAssetStore.maxTotalBytes) {
          return null;
        }
        final resource = AssistantRoleCardResource.fromJson(
          Map<String, dynamic>.from(metadata),
        );
        resources.add(AssistantRoleCardResource(
          type: resource.type,
          uri: resource.uri,
          name: resource.name,
          ext: resource.ext,
          archivePath: resource.archivePath,
          mimeType: resource.mimeType,
          size: bytes.length,
          bytes: Uint8List.fromList(bytes),
          includeInCard: resource.includeInCard,
        ));
      } catch (_) {
        return null;
      }
    }
    return resources;
  }

  Future<void> _deleteStagedAssets(int assistantId) => storage.db.delete(
        _roleAssetStageTable,
        where: 'assistantId = ?',
        whereArgs: [assistantId],
      );

  Future<void> _deleteOtherStagedAssetVersions(
    int assistantId,
    int assistantUpdatedAt,
  ) =>
      storage.db.delete(
        _roleAssetStageTable,
        where: 'assistantId = ? and assistantUpdatedAt != ?',
        whereArgs: [assistantId, assistantUpdatedAt],
      );

  Future<Set<_RoleAssetBundleKey>> _stagedBundleKeys() async {
    final rows = await storage.db.rawQuery(
      'select distinct assistantId, assistantUpdatedAt '
      'from $_roleAssetStageTable',
    );
    return {
      for (final row in rows)
        if (_asInt(row['assistantId']) > 0 &&
            _asInt(row['assistantUpdatedAt']) >= 0)
          _RoleAssetBundleKey(
            _asInt(row['assistantId']),
            _asInt(row['assistantUpdatedAt']),
          ),
    };
  }

  Future<bool> _canStageAssetChunk(
    Transaction txn,
    _RoleAssetChunk chunk,
  ) async {
    final rows = await txn.query(
      _roleAssetStageTable,
      columns: const ['assetIndex', 'metadata'],
      where: 'assistantId = ? and assistantUpdatedAt = ?',
      whereArgs: [chunk.assistantId, chunk.assistantUpdatedAt],
    );
    final sizes = <int, int>{};
    for (final row in rows) {
      try {
        final metadata = jsonDecode(row['metadata'] as String);
        if (metadata is! Map) return false;
        sizes[_asInt(row['assetIndex'])] = _asInt(metadata['size']);
      } catch (_) {
        return false;
      }
    }
    sizes[chunk.assetIndex] = chunk.declaredSize;
    return sizes.values.fold<int>(0, (sum, size) => sum + size) <=
        AssistantRoleCardAssetStore.maxTotalBytes;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? -1;
  }

  static _SyncEntitySpec? _specFor(String entity) {
    for (final spec in _specs) {
      if (spec.entity == entity) return spec;
    }
    return null;
  }

  Future<void> _ensureTables() async {
    await DbMigration.run(storage.db);
    await AssistantDao.create(storage);
    await StoryRoomDao.create(storage);
    await StoryArtifactDao.create(storage);
    await StoryTemplateTranslationTaskDao.create(storage);
    await SyncTombstoneStore.ensure(storage.db);
    await storage.db.execute(
      'create table if not exists $_roleAssetStageTable ('
      'assistantId integer not null, assistantUpdatedAt integer not null, '
      'assetIndex integer not null, chunkIndex integer not null, '
      'totalChunks integer not null, assetCount integer not null, '
      'metadata text not null, data text not null, '
      'primary key(assistantId, assistantUpdatedAt, assetIndex, chunkIndex))',
    );
  }

  static bool _samePayload(
    Map<String, Object?> current,
    Map<String, dynamic> incoming,
    List<String> idColumns, {
    bool ignoreRoleCardAssets = false,
  }) {
    final normalizedCurrent = Map<String, Object?>.from(current);
    for (final key in idColumns) {
      normalizedCurrent[key] = incoming[key] ?? normalizedCurrent[key];
    }
    if (ignoreRoleCardAssets) {
      normalizedCurrent['roleCardAssets'] = incoming['roleCardAssets'];
    }
    return jsonEncode(_sorted(normalizedCurrent)) ==
        jsonEncode(_sorted(incoming));
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((e) => e.toString()).toList()..sort();
      return {
        for (final key in keys) key: _sorted(value[key]),
      };
    }
    if (value is Iterable) return value.map(_sorted).toList();
    return value;
  }
}

class _RoleAssetApplyResult {
  final List<SyncChange> accepted;
  final List<SyncChange> rejectedStale;

  const _RoleAssetApplyResult(this.accepted, this.rejectedStale);
}

class _RoleAssetBundleKey {
  final int assistantId;
  final int assistantUpdatedAt;

  const _RoleAssetBundleKey(this.assistantId, this.assistantUpdatedAt);

  @override
  bool operator ==(Object other) =>
      other is _RoleAssetBundleKey &&
      other.assistantId == assistantId &&
      other.assistantUpdatedAt == assistantUpdatedAt;

  @override
  int get hashCode => Object.hash(assistantId, assistantUpdatedAt);
}

class _RoleAssetChunk {
  final SyncChange change;
  final int assistantId;
  final int assetIndex;
  final int chunkIndex;
  final int totalChunks;
  final int assetCount;
  final int assistantUpdatedAt;
  final int declaredSize;
  final Map<String, dynamic> metadata;
  final String base64;

  const _RoleAssetChunk({
    required this.change,
    required this.assistantId,
    required this.assetIndex,
    required this.chunkIndex,
    required this.totalChunks,
    required this.assetCount,
    required this.assistantUpdatedAt,
    required this.declaredSize,
    required this.metadata,
    required this.base64,
  });

  _RoleAssetBundleKey get bundleKey =>
      _RoleAssetBundleKey(assistantId, assistantUpdatedAt);

  Map<String, Object?> toRow() => {
        'assistantId': assistantId,
        'assistantUpdatedAt': assistantUpdatedAt,
        'assetIndex': assetIndex,
        'chunkIndex': chunkIndex,
        'totalChunks': totalChunks,
        'assetCount': assetCount,
        'metadata': jsonEncode(LocalSyncService._sorted(metadata)),
        'data': base64,
      };

  static _RoleAssetChunk? tryParse(SyncChange change) {
    if (change.op != SyncOp.upsert) {
      return null;
    }
    final payload = change.payload;
    final assistantId = LocalSyncService._asInt(payload['assistantId']);
    final assetIndex = LocalSyncService._asInt(payload['assetIndex']);
    final chunkIndex = LocalSyncService._asInt(payload['chunkIndex']);
    final totalChunks = LocalSyncService._asInt(payload['totalChunks']);
    final assetCount = LocalSyncService._asInt(payload['assetCount']);
    final assistantUpdatedAt =
        LocalSyncService._asInt(payload['assistantUpdatedAt']);
    const maxChunks = (AssistantRoleCardAssetStore.maxAssetBytes +
            LocalSyncService._roleAssetChunkBytes -
            1) ~/
        LocalSyncService._roleAssetChunkBytes;
    if (assistantId <= 0 ||
        assetIndex < 0 ||
        assetIndex >= AssistantRoleCardAssetStore.maxAssets ||
        chunkIndex < 0 ||
        totalChunks <= 0 ||
        totalChunks > maxChunks ||
        chunkIndex >= totalChunks ||
        assetCount <= 0 ||
        assetCount > AssistantRoleCardAssetStore.maxAssets ||
        assetIndex >= assetCount ||
        assistantUpdatedAt != change.updatedAt ||
        change.id != '$assistantId:$assetIndex:$chunkIndex') {
      return null;
    }
    final metadata = payload['metadata'];
    final data = payload['base64'];
    if (metadata is! Map ||
        data is! String ||
        data.length > ((LocalSyncService._roleAssetChunkBytes + 2) ~/ 3) * 4) {
      return null;
    }
    final declaredSize = LocalSyncService._asInt(metadata['size']);
    if (declaredSize <= 0 ||
        declaredSize > AssistantRoleCardAssetStore.maxAssetBytes ||
        jsonEncode(metadata).length > 16 * 1024) {
      return null;
    }
    try {
      final bytes = base64Decode(data);
      if (bytes.isEmpty ||
          bytes.length > LocalSyncService._roleAssetChunkBytes) {
        return null;
      }
    } catch (_) {
      return null;
    }
    return _RoleAssetChunk(
      change: change,
      assistantId: assistantId,
      assetIndex: assetIndex,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      assetCount: assetCount,
      assistantUpdatedAt: assistantUpdatedAt,
      declaredSize: declaredSize,
      metadata: Map<String, dynamic>.from(metadata),
      base64: data,
    );
  }
}

class _SyncEntitySpec {
  final String entity;
  final String table;
  final List<String> idColumns;
  final String? timestampColumn;

  const _SyncEntitySpec({
    required this.entity,
    required this.table,
    required this.idColumns,
    this.timestampColumn,
  });

  String get whereClause => idColumns.map((c) => '$c = ?').join(' and ');

  List<Object?> whereArgs(String id) {
    final parts = id.split(':');
    return [
      for (var i = 0; i < idColumns.length; i++)
        int.tryParse(i < parts.length ? parts[i] : '') ??
            (i < parts.length ? parts[i] : ''),
    ];
  }

  SyncChange changeFromRow(Map<String, Object?> row) {
    return SyncChange(
      entity: entity,
      id: idOf(row),
      op: SyncOp.upsert,
      updatedAt: updatedAtOf(row),
      payload: Map<String, dynamic>.from(row),
    );
  }

  String idOf(Map<String, Object?> row) =>
      idColumns.map((c) => '${row[c]}').join(':');

  int updatedAtOf(Map<String, Object?> row) {
    if (timestampColumn == null) return 0;
    final raw = row[timestampColumn];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }
}
