import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_tavern_preset_transfer.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection_transfer.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/db_migration.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:sqflite/sqflite.dart';

/// 本地同步服务：把 SQLite 里的核心业务表转换成可上传的增量变更，
/// 并把服务端下发的变更按 Last-Write-Wins 应用回本机。
///
/// 网络层由 [CloudSyncClient] 负责；这里保持纯 SQLite 合并逻辑，便于离线测试。
class LocalSyncService {
  static const assistantRoleAssetChunkEntity = 'assistant_role_asset_chunk';
  static const maxPersonaAvatarBytes = 2 * 1024 * 1024;
  static const _roleAssetChunkBytes = 192 * 1024;
  static const _personaAvatarFallback = '🙂';
  static const _roleAssetStageTable = 'tb_sync_assistant_role_asset_chunk';
  static const _storyMessageDeleteTrigger =
      'tb_sync_story_message_delete_to_node_key';
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
      entity: 'story_persona',
      table: 'tb_story_persona',
      idColumns: ['personaKey'],
      timestampColumn: 'updatedAt',
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
      idColumns: ['nodeKey'],
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
      entity: 'story_template',
      table: 'tb_story_template',
      idColumns: ['id'],
      timestampColumn: 'updatedAt',
    ),
  ];

  final HiDBManager storage;
  final String accountHash;
  final RoleCardAssetDirectoryResolver? roleCardAssetDirectoryResolver;

  LocalSyncService(
    this.storage, {
    String? accountHash,
    this.roleCardAssetDirectoryResolver,
  }) : accountHash = AccountResourceScope.currentAccountHash(accountHash);

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
        } else if (spec.entity == 'story_persona') {
          changes.add(await _personaChangeFromRow(row));
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
    final incoming = remoteChanges
        .map(_normalizeStoryChange)
        .map(_validateSelectionChange)
        .toList(growable: false);
    await _ensureTables();
    final accepted = <SyncChange>[];
    final rejectedStale = <SyncChange>[];
    final conflicts = <String>[];
    final deletedAssistantIds = <int>{};
    final upsertedAssistantIds = <int>{};
    final assistantUpsertVersions = <int, int>{};
    final affectedStoryRoomIds = <int>{};
    final assistantIdsWithChunks = {
      for (final change in incoming)
        if (change.entity == assistantRoleAssetChunkEntity)
          _asInt(change.payload['assistantId']),
    }..removeWhere((id) => id <= 0);

    await storage.db.transaction((txn) async {
      for (final remote in incoming) {
        if (remote.entity == assistantRoleAssetChunkEntity) continue;
        if (remote.entity == 'story_persona' && remote.id.trim().isEmpty) {
          rejectedStale.add(remote);
          continue;
        }
        final spec = _specFor(remote.entity);
        if (spec == null) {
          rejectedStale.add(remote);
          continue;
        }
        final currentRows = await txn.query(
          spec.table,
          where: _whereClauseFor(remote, spec),
          whereArgs: _whereArgsFor(remote, spec),
          limit: 1,
        );
        final current = currentRows.isEmpty ? null : currentRows.first;
        _collectAffectedStoryRoomIds(
          remote,
          current,
          affectedStoryRoomIds,
        );
        final currentUpdatedAt =
            current == null ? -1 : spec.updatedAtOf(current);
        if (currentUpdatedAt > remote.updatedAt) {
          rejectedStale.add(remote);
          continue;
        }
        final payload = _payloadForApply(remote);
        if (remote.op == SyncOp.upsert &&
            BackendSelectionTransfer.entities.contains(remote.entity) &&
            current != null &&
            current['backendSelection'] != null &&
            payload['backendSelection'] == null) {
          // 缺字段和显式 NULL 都是旧客户端未声明；不能清掉现代 pair/follow。
          payload.remove('backendSelection');
        }
        final comparedPayload = Map<String, dynamic>.from(payload);
        if (BackendSelectionTransfer.entities.contains(remote.entity) &&
            current != null &&
            !comparedPayload.containsKey('backendSelection')) {
          comparedPayload['backendSelection'] = current['backendSelection'];
        }
        if (currentUpdatedAt == remote.updatedAt &&
            current != null &&
            !_samePayload(
              current,
              comparedPayload,
              spec.idColumns,
              ignoreRoleCardAssets: remote.entity == 'assistant',
              ignorePersonaAvatar: remote.entity == 'story_persona',
              ignoredColumns:
                  remote.entity == 'story_message' ? const {'id'} : const {},
            )) {
          conflicts.add(remote.key);
          continue;
        }
        if (remote.op == SyncOp.delete) {
          await txn.delete(
            spec.table,
            where: _whereClauseFor(remote, spec),
            whereArgs: _whereArgsFor(remote, spec),
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
        if (remote.entity == 'story_message' && current != null) {
          final nodeKey = '${current['nodeKey'] ?? ''}';
          if (nodeKey.isNotEmpty) {
            await SyncTombstoneStore.remove(
              txn,
              entity: remote.entity,
              id: nodeKey,
            );
          }
        }
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
      await _reconcileStoryRooms(txn, affectedStoryRoomIds);
    });

    for (final id in deletedAssistantIds) {
      await AssistantRoleCardAssetStore.delete(
        assistantId: id,
        directoryResolver: roleCardAssetDirectoryResolver,
        accountHash: accountHash,
      );
      await _deleteStagedAssets(id);
    }
    // Persona 头像也是历史消息的身份快照资源。删除 Persona 只移除可选身份，
    // 不删除头像文件，否则旧消息会在同步后丢失当时的发言者头像。
    await _restorePersonaAvatars(accepted);
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
        accountHash: accountHash,
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

  Future<SyncChange> _personaChangeFromRow(
    Map<String, Object?> row,
  ) async {
    final persona = _specs
        .firstWhere((spec) => spec.entity == 'story_persona')
        .changeFromRow(row);
    final payload = Map<String, dynamic>.from(persona.payload)..remove('id');
    if (payload['avatarType'] != AvatarAssetService.imageType) {
      return SyncChange(
        entity: persona.entity,
        id: persona.id,
        op: persona.op,
        updatedAt: persona.updatedAt,
        payload: payload,
      );
    }

    // 图片路径是设备本地状态。即使读取失败，也绝不能把绝对路径带出设备。
    payload['avatarType'] = 'emoji';
    payload['avatarValue'] = _personaAvatarFallback;
    final path = row['avatarValue']?.toString() ?? '';
    try {
      final file = File(path);
      if (path.isEmpty || !await file.exists()) {
        return SyncChange(
          entity: persona.entity,
          id: persona.id,
          op: persona.op,
          updatedAt: persona.updatedAt,
          payload: payload,
        );
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > maxPersonaAvatarBytes) {
        return SyncChange(
          entity: persona.entity,
          id: persona.id,
          op: persona.op,
          updatedAt: persona.updatedAt,
          payload: payload,
        );
      }
      payload
        ..['avatarType'] = AvatarAssetService.imageType
        ..['avatarValue'] = ''
        ..['avatarAsset'] = {
          'base64': base64Encode(bytes),
          'extension': _safeAvatarExtension(path),
        };
    } catch (_) {
      // 保留文本 Persona，并回落 emoji；同步失败不会泄露路径或中断其它实体。
    }
    return SyncChange(
      entity: persona.entity,
      id: persona.id,
      op: persona.op,
      updatedAt: persona.updatedAt,
      payload: payload,
    );
  }

  Future<void> _restorePersonaAvatars(Iterable<SyncChange> changes) async {
    for (final change in changes) {
      if (change.entity != 'story_persona' || change.op != SyncOp.upsert) {
        continue;
      }
      final asset = _PersonaAvatarAsset.tryParse(change);
      if (asset == null) continue;
      final current = await storage.db.query(
        'tb_story_persona',
        columns: const ['updatedAt'],
        where: 'personaKey = ?',
        whereArgs: [asset.personaKey],
        limit: 1,
      );
      if (current.isEmpty ||
          _asInt(current.single['updatedAt']) != change.updatedAt) {
        continue;
      }
      String? path;
      try {
        path = await AvatarAssetService.savePersonaAvatarBytes(
          bytes: asset.bytes,
          personaKey: asset.personaKey,
          extension: asset.extension,
        );
        final updated = await storage.db.update(
          'tb_story_persona',
          {
            'avatarType': AvatarAssetService.imageType,
            'avatarValue': path,
          },
          where: 'personaKey = ? and updatedAt = ?',
          whereArgs: [asset.personaKey, change.updatedAt],
        );
        if (updated == 0) {
          await AvatarAssetService.deletePersonaAvatar(path);
        }
      } catch (_) {
        // 主记录已经是 emoji 兜底；图片失败不能影响 Persona 文本同步。
        if (path != null) await AvatarAssetService.deletePersonaAvatar(path);
      }
    }
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
        accountHash: accountHash,
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
    if (remote.entity == 'story_message' && remote.op == SyncOp.upsert) {
      // id 是接收设备的自增主键，不能跨设备写入；nodeKey 才是同步 identity。
      payload.remove('id');
    }
    if (remote.entity == 'story_persona' && remote.op == SyncOp.upsert) {
      // id 是设备本地自增主键，personaKey 才是跨设备 identity。
      payload
        ..remove('id')
        ..remove('avatarAsset');
      // 图片字节由 _restorePersonaAvatars 写入本机 chat_avatar；主表先用
      // emoji 兜底，以免远端路径或异常 base64 进入 SQLite。
      if (payload['avatarType'] == AvatarAssetService.imageType ||
          _looksLikeAbsolutePath(payload['avatarValue'])) {
        payload['avatarType'] = 'emoji';
        payload['avatarValue'] = _personaAvatarFallback;
      }
    }
    if (remote.entity == 'assistant' && remote.op == SyncOp.upsert) {
      // 远端 payload 不能携带可访问的本机绝对路径。
      payload['roleCardAssets'] = '[]';
    }
    return payload;
  }

  static SyncChange _validateSelectionChange(SyncChange change) {
    if (change.op != SyncOp.upsert ||
        !BackendSelectionTransfer.entities.contains(change.entity)) {
      return change;
    }
    return SyncChange(
        entity: change.entity,
        id: change.id,
        op: change.op,
        updatedAt: change.updatedAt,
        payload: BackendSelectionTransfer.row(change.payload));
  }

  static SyncChange _normalizeStoryChange(SyncChange change) {
    if (change.entity == 'story_persona' && change.op == SyncOp.upsert) {
      final payload = Map<String, dynamic>.from(change.payload);
      final personaKey = '${payload['personaKey'] ?? change.id}'.trim();
      if (personaKey.isNotEmpty) payload['personaKey'] = personaKey;
      return SyncChange(
        entity: change.entity,
        id: personaKey,
        op: change.op,
        updatedAt: change.updatedAt,
        payload: payload,
      );
    }
    if (change.entity == 'story_room' && change.op == SyncOp.upsert) {
      final payload = Map<String, dynamic>.from(change.payload);
      payload['promptConfigJson'] = '${payload['promptConfigJson'] ?? ''}';
      payload['quickRepliesJson'] = '${payload['quickRepliesJson'] ?? ''}';
      payload['regexScriptsJson'] = '${payload['regexScriptsJson'] ?? ''}';
      payload['tavernPresetJson'] =
          StoryTavernPresetTransfer.normalizeRoomBundle(
        payload['tavernPresetJson'],
      );
      payload['temperature'] =
          StoryTavernPresetTransfer.safeTemperature(payload['temperature']);
      payload['topP'] = StoryTavernPresetTransfer.safeTopP(payload['topP']);
      payload['maxOutputTokens'] =
          StoryTavernPresetTransfer.safeMaxTokens(payload['maxOutputTokens']);
      payload['personaKey'] = payload['personaKey']?.toString();
      return SyncChange(
        entity: change.entity,
        id: change.id,
        op: change.op,
        updatedAt: change.updatedAt,
        payload: payload,
      );
    }
    if (change.entity == 'story_participant' && change.op == SyncOp.upsert) {
      final payload = Map<String, dynamic>.from(change.payload);
      final roomId = _asInt(payload['roomId']);
      final rawKey = '${payload['participantKey'] ?? ''}'.trim();
      payload['participantKey'] = rawKey.isNotEmpty
          ? rawKey
          : 'legacy-participant-$roomId-${change.id}';
      payload['stateSummary'] = '${payload['stateSummary'] ?? ''}';
      payload['topP'] = StoryTavernPresetTransfer.safeTopP(payload['topP']);
      return SyncChange(
        entity: change.entity,
        id: change.id,
        op: change.op,
        updatedAt: change.updatedAt,
        payload: payload,
      );
    }
    if (change.entity != 'story_message' || change.op != SyncOp.upsert) {
      return change;
    }
    final payload = Map<String, dynamic>.from(change.payload);
    payload['roleStatesAfter'] = '${payload['roleStatesAfter'] ?? '{}'}';
    payload['speakerPersonaKey'] = payload['speakerPersonaKey']?.toString();
    final rawNodeKey = payload['nodeKey'];
    if (rawNodeKey is String && rawNodeKey.trim().isNotEmpty) {
      return SyncChange(
        entity: change.entity,
        id: rawNodeKey.trim(),
        op: change.op,
        updatedAt: change.updatedAt,
        payload: payload,
      );
    }

    // 兼容首版同步产生的整数 story_message upsert：迁移后的本地库会
    // 使用同样的 legacy key 接住它，但之后仍按 nodeKey 参与同步。
    final roomId = _asInt(payload['roomId']);
    final legacyId = int.tryParse(change.id);
    if (roomId > 0 && legacyId != null && legacyId > 0) {
      final nodeKey = 'legacy-$roomId-$legacyId';
      payload['nodeKey'] = nodeKey;
      return SyncChange(
        entity: change.entity,
        id: nodeKey,
        op: change.op,
        updatedAt: change.updatedAt,
        payload: payload,
      );
    }
    payload['nodeKey'] = change.id;
    return SyncChange(
      entity: change.entity,
      id: change.id,
      op: change.op,
      updatedAt: change.updatedAt,
      payload: payload,
    );
  }

  static String _whereClauseFor(SyncChange change, _SyncEntitySpec spec) {
    if (_isLegacyStoryMessageDelete(change)) return 'id = ?';
    return spec.whereClause;
  }

  static List<Object?> _whereArgsFor(
    SyncChange change,
    _SyncEntitySpec spec,
  ) {
    if (_isLegacyStoryMessageDelete(change)) {
      return [int.parse(change.id)];
    }
    return spec.whereArgs(change.id);
  }

  static bool _isLegacyStoryMessageDelete(SyncChange change) =>
      change.entity == 'story_message' &&
      change.op == SyncOp.delete &&
      int.tryParse(change.id) != null;

  static void _collectAffectedStoryRoomIds(
    SyncChange change,
    Map<String, Object?>? current,
    Set<int> roomIds,
  ) {
    if (change.entity == 'story_room') {
      final roomId = int.tryParse(change.id);
      if (roomId != null && roomId > 0) roomIds.add(roomId);
      return;
    }
    if (change.entity != 'story_message') return;
    final incomingRoomId = _asInt(change.payload['roomId']);
    if (incomingRoomId > 0) roomIds.add(incomingRoomId);
    final currentRoomId = _asInt(current?['roomId']);
    if (currentRoomId > 0) roomIds.add(currentRoomId);
  }

  static Future<void> _reconcileStoryRooms(
    DatabaseExecutor db,
    Set<int> roomIds,
  ) async {
    for (final roomId in roomIds) {
      final rooms = await db.query(
        'tb_story_room',
        where: 'id = ?',
        whereArgs: [roomId],
        limit: 1,
      );
      if (rooms.isEmpty) continue;
      final rows = await db.query(
        'tb_story_message',
        where: 'roomId = ?',
        whereArgs: [roomId],
      );
      if (rows.isEmpty) {
        await db.update(
          'tb_story_room',
          {'activeMessageKey': null, 'worldBookState': ''},
          where: 'id = ?',
          whereArgs: [roomId],
        );
        continue;
      }

      final messages = rows.map(Map<String, Object?>.from).toList();
      messages.sort((a, b) {
        final byCreated = _asInt(b['createdAt']).compareTo(
          _asInt(a['createdAt']),
        );
        if (byCreated != 0) return byCreated;
        final byUpdated = _asInt(b['updatedAt']).compareTo(
          _asInt(a['updatedAt']),
        );
        if (byUpdated != 0) return byUpdated;
        return '${b['nodeKey']}'.compareTo('${a['nodeKey']}');
      });
      final activeKey = rooms.single['activeMessageKey'] as String?;
      final active = messages.where(
        (message) => message['nodeKey'] == activeKey,
      );
      final selected = active.isEmpty ? messages.first : active.first;
      await db.update(
        'tb_story_room',
        {
          'activeMessageKey': selected['nodeKey'],
          'worldBookState': selected['contextStateAfter'] as String? ?? '',
        },
        where: 'id = ?',
        whereArgs: [roomId],
      );
    }
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
          accountHash: accountHash,
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

  static String _safeAvatarExtension(String path) {
    final match = RegExp(r'\.([A-Za-z0-9]{1,8})$').firstMatch(path);
    return match == null ? '.png' : '.${match.group(1)!.toLowerCase()}';
  }

  static bool _looksLikeAbsolutePath(Object? value) {
    final path = value?.toString().trim() ?? '';
    return path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
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
    await StoryPersonaDao.create(storage);
    await StoryRoomDao.create(storage);
    await StoryArtifactDao.create(storage);
    await StoryTemplateDao.create(storage);
    await SyncTombstoneStore.ensure(storage.db);
    await storage.db.execute(
      'create table if not exists $_roleAssetStageTable ('
      'assistantId integer not null, assistantUpdatedAt integer not null, '
      'assetIndex integer not null, chunkIndex integer not null, '
      'totalChunks integer not null, assetCount integer not null, '
      'metadata text not null, data text not null, '
      'primary key(assistantId, assistantUpdatedAt, assetIndex, chunkIndex))',
    );
    await storage.db.execute(
      'create trigger if not exists $_storyMessageDeleteTrigger '
      'after delete on tb_story_message begin '
      'delete from ${SyncTombstoneStore.tableName} '
      "where entity = 'story_message' and entityId = old.nodeKey; "
      'insert into ${SyncTombstoneStore.tableName} '
      "(entity, entityId, updatedAt) values ('story_message', old.nodeKey, "
      "coalesce((select updatedAt from ${SyncTombstoneStore.tableName} "
      "where entity = 'story_message' and entityId = cast(old.id as text)), "
      "cast((julianday('now') - 2440587.5) * 86400000 as integer))); "
      'delete from ${SyncTombstoneStore.tableName} '
      "where entity = 'story_message' and entityId = cast(old.id as text); "
      'end',
    );
  }

  static bool _samePayload(
    Map<String, Object?> current,
    Map<String, dynamic> incoming,
    List<String> idColumns, {
    bool ignoreRoleCardAssets = false,
    bool ignorePersonaAvatar = false,
    Set<String> ignoredColumns = const {},
  }) {
    final normalizedCurrent = Map<String, Object?>.from(current);
    for (final key in idColumns) {
      normalizedCurrent[key] = incoming[key] ?? normalizedCurrent[key];
    }
    if (ignoreRoleCardAssets) {
      normalizedCurrent['roleCardAssets'] = incoming['roleCardAssets'];
    }
    if (ignorePersonaAvatar) {
      normalizedCurrent['avatarType'] = incoming['avatarType'];
      normalizedCurrent['avatarValue'] = incoming['avatarValue'];
    }
    for (final key in ignoredColumns) {
      normalizedCurrent.remove(key);
      incoming.remove(key);
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

class _PersonaAvatarAsset {
  final String personaKey;
  final Uint8List bytes;
  final String extension;

  const _PersonaAvatarAsset({
    required this.personaKey,
    required this.bytes,
    required this.extension,
  });

  static _PersonaAvatarAsset? tryParse(SyncChange change) {
    final payload = change.payload;
    final personaKey = '${payload['personaKey'] ?? ''}'.trim();
    final asset = payload['avatarAsset'];
    if (personaKey.isEmpty || change.id != personaKey || asset is! Map) {
      return null;
    }
    final base64 = asset['base64'];
    final extension = asset['extension'];
    if (base64 is! String ||
        base64.isEmpty ||
        base64.length >
            ((LocalSyncService.maxPersonaAvatarBytes + 2) ~/ 3) * 4 ||
        extension is! String ||
        !RegExp(r'^\.[A-Za-z0-9]{1,8}$').hasMatch(extension)) {
      return null;
    }
    try {
      final bytes = base64Decode(base64);
      if (bytes.isEmpty ||
          bytes.length > LocalSyncService.maxPersonaAvatarBytes) {
        return null;
      }
      return _PersonaAvatarAsset(
        personaKey: personaKey,
        bytes: Uint8List.fromList(bytes),
        extension: extension.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
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
    if (idColumns.length == 1) return [id];
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
      payload: BackendSelectionTransfer.entities.contains(entity)
          ? BackendSelectionTransfer.row(row)
          : Map<String, dynamic>.from(row),
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
