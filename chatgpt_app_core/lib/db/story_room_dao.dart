import 'dart:convert';
import 'dart:math' as math;
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';
import 'package:sqflite/sqflite.dart';

final class _TavernImportInsertResult {
  final int roomId;
  final int? personaId;
  final List<int> participantIds;
  final List<int> messageIds;
  final List<int?> messageSpeakerIds;
  final String? activeMessageKey;
  final int roomCreatedAt;
  final int now;

  const _TavernImportInsertResult({
    required this.roomId,
    required this.personaId,
    required this.participantIds,
    required this.messageIds,
    required this.messageSpeakerIds,
    required this.activeMessageKey,
    required this.roomCreatedAt,
    required this.now,
  });
}

class StoryRoomDao implements ITable {
  final HiDBManager storage;

  static const roomTable = 'tb_story_room';

  @override
  String tableName = roomTable;

  static const participantTable = 'tb_story_participant';
  static const messageTable = 'tb_story_message';

  StoryRoomDao._(this.storage);

  static Future<StoryRoomDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_story_room (id integer primary key autoincrement'
        ', title text, mode text, replyMode text, maxAutoReplies integer'
        ", speakerStrategy text default '${StorySpeakerStrategy.smart}'"
        ', avoidRepeatSpeaker integer default 1'
        ', maxAutoTotalTokens integer default ${StoryRoomSchedulingLimits.defaultMaxAutoTotalTokens}'
        ', publicContext text, worldBookState text, roleCardContextJson text'
        ', promptConfigJson text, quickRepliesJson text, regexScriptsJson text, tavernPresetJson text, personaKey text'
        ', webSearchEnabled integer, modelProviderId text, modelId text, backendSelection text'
        ', temperature real, topP real, maxOutputTokens integer'
        ', activeMessageKey text'
        ', tavernChatMetadataJson text'
        ', createdAt integer, updatedAt integer)');
    await _ensureRoomColumns(storage);
    await SchemaGuard.ensureColumns(storage.db,
        table: roomTable, columns: const {'backendSelection': 'text'});
    await storage.db.execute(
        'create table if not exists tb_story_participant (id integer primary key autoincrement'
        ', roomId integer not null, assistantId integer, role text, name text'
        ', prompt text, avatarType text, avatarValue text'
        ', voiceStyle text, modelProviderId text, modelId text, backendSelection text'
        ', temperature real, topP real, maxOutputTokens integer'
        ', participantKey text not null, stateSummary text'
        ', sortOrder integer, enabled integer, createdAt integer, updatedAt integer)');
    await _ensureParticipantColumns(storage);
    await SchemaGuard.ensureColumns(storage.db,
        table: participantTable, columns: const {'backendSelection': 'text'});
    await storage.db.execute(
        'create index if not exists tb_story_participant_room_idx on tb_story_participant(roomId, sortOrder)');
    await storage.db.execute(
        'create unique index if not exists tb_story_participant_room_key_uq on tb_story_participant(roomId, participantKey)');
    await storage.db.execute(
        'create table if not exists tb_story_message (id integer primary key autoincrement'
        ', roomId integer not null, speakerId integer, speakerRole text'
        ', speakerName text, speakerAvatarType text, speakerAvatarValue text'
        ', speakerVoiceStyle text, speakerPersonaKey text, content text, imagePaths text, imageSources text'
        ', citationUrls text, filePaths text'
        ', attachmentContext text, nodeKey text not null, parentNodeKey text'
        ', candidateGroupKey text, contextStateAfter text, roleStatesAfter text'
        ', tavernExtraJson text, tavernSwipeInfoJson text'
        ', createdAt integer, updatedAt integer)');
    final addedBranchColumns = await _ensureMessageColumns(storage);
    try {
      await storage.db
          .execute('alter table tb_story_message add column updatedAt integer');
    } catch (_) {
      // 已存在 updatedAt 列时忽略，保持旧库可升级。
    }
    await storage.db.execute(
        'update tb_story_message set updatedAt = createdAt where updatedAt is null');
    await storage.db.execute(
        'create index if not exists tb_story_message_room_idx on tb_story_message(roomId, id asc)');
    await storage.db.execute(
        'create unique index if not exists tb_story_message_node_key_uq on tb_story_message(nodeKey)');
    await storage.db.execute(
        'create index if not exists tb_story_message_parent_node_idx on tb_story_message(roomId, parentNodeKey)');
    await storage.db.execute(
        'create index if not exists tb_story_message_candidate_group_idx on tb_story_message(roomId, candidateGroupKey)');
    if (addedBranchColumns) {
      await _migrateLegacyMessageBranches(storage);
    }
    await SyncTombstoneStore.ensure(storage.db);
    return StoryRoomDao._(storage);
  }

  static Future<void> _ensureRoomColumns(HiDBManager storage) async {
    try {
      await storage.db.execute(
          "alter table tb_story_room add column mode text default '${StoryRoomMode.creation}'");
    } catch (_) {
      // 已存在 mode 列时忽略，保持旧库可升级。
    }
    try {
      await storage.db.execute(
          "alter table tb_story_room add column replyMode text default '${StoryReplyMode.autoSingle}'");
    } catch (_) {
      // 已存在 replyMode 列时忽略，保持旧库可升级。
    }
    try {
      await storage.db.execute(
          'alter table tb_story_room add column maxAutoReplies integer default 1');
    } catch (_) {
      // 已存在 maxAutoReplies 列时忽略，保持旧库可升级。
    }
    for (final column in const [
      "speakerStrategy text default '${StorySpeakerStrategy.smart}'",
      'avoidRepeatSpeaker integer default 1',
      'maxAutoTotalTokens integer default ${StoryRoomSchedulingLimits.defaultMaxAutoTotalTokens}',
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_room add column $column');
      } catch (_) {
        // 已存在调度配置列时忽略，保持旧库可升级。
      }
    }
    for (final column in const [
      'modelProviderId text',
      'modelId text',
      'temperature real',
      'topP real',
      'maxOutputTokens integer',
      'worldBookState text',
      'roleCardContextJson text',
      // 不设默认值：旧房间继续跟随全局，不把当时的值固定为覆盖。
      'webSearchEnabled integer',
      'promptConfigJson text',
      'quickRepliesJson text',
      'regexScriptsJson text',
      'tavernPresetJson text',
      'personaKey text',
      'activeMessageKey text',
      'tavernChatMetadataJson text',
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_room add column $column');
      } catch (_) {
        // 已存在模型参数列时忽略，保持旧库可升级。
      }
    }
  }

  static Future<void> _ensureParticipantColumns(HiDBManager storage) async {
    for (final column in const [
      'voiceStyle text',
      'modelProviderId text',
      'modelId text',
      'temperature real',
      'topP real',
      'maxOutputTokens integer',
      'participantKey text',
      'stateSummary text',
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_participant add column $column');
      } catch (_) {
        // 已存在列时忽略，保持旧库可升级。
      }
    }
    await storage.db.execute(
      "update tb_story_participant set participantKey = 'legacy-participant-' || roomId || '-' || id "
      "where participantKey is null or trim(participantKey) = ''",
    );
  }

  static Future<bool> _ensureMessageColumns(HiDBManager storage) async {
    var addedBranchColumns = false;
    for (final column in const [
      'speakerVoiceStyle text',
      'imagePaths text',
      'imageSources text',
      'citationUrls text',
      'filePaths text',
      'attachmentContext text',
      'speakerPersonaKey text',
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_message add column $column');
      } catch (_) {
        // 已存在列时忽略，保持旧库可升级。
      }
    }
    try {
      await storage.db
          .execute('alter table tb_story_message add column nodeKey text');
      addedBranchColumns = true;
    } catch (_) {
      // 已存在 nodeKey 列时不回填，避免破坏已有分支根。
    }
    try {
      await storage.db.execute(
          'alter table tb_story_message add column parentNodeKey text');
      addedBranchColumns = true;
    } catch (_) {
      // 已存在 parentNodeKey 列时忽略，保持旧库可升级。
    }
    for (final column in const [
      'candidateGroupKey text',
      'contextStateAfter text',
      'roleStatesAfter text',
      'tavernExtraJson text',
      'tavernSwipeInfoJson text',
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_message add column $column');
      } catch (_) {
        // 已存在分支列时忽略，保持旧库可升级。
      }
    }
    return addedBranchColumns;
  }

  /// 仅在首次引入节点键时把旧线性消息迁移成稳定键父链。
  static Future<void> _migrateLegacyMessageBranches(HiDBManager storage) async {
    await storage.db.transaction((txn) async {
      final rooms = await txn.query('tb_story_room', columns: ['id']);
      for (final room in rooms) {
        final roomId = room['id'] as int;
        final messages = await txn.query(
          messageTable,
          columns: ['id'],
          where: 'roomId = ?',
          whereArgs: [roomId],
          orderBy: 'id asc',
        );
        String? parentNodeKey;
        for (final message in messages) {
          final id = message['id'] as int;
          final nodeKey = 'legacy-$roomId-$id';
          await txn.update(
            messageTable,
            {
              'nodeKey': nodeKey,
              'parentNodeKey': parentNodeKey,
              'candidateGroupKey': nodeKey,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          parentNodeKey = nodeKey;
        }
        await txn.update(
          'tb_story_room',
          {'activeMessageKey': parentNodeKey},
          where: 'id = ?',
          whereArgs: [roomId],
        );
      }
    });
  }

  Future<StoryBackendSelectionSnapshot> roomBackendSnapshot(
          StoryRoomModel model,
          {required void Function() validate}) =>
      _backendSnapshot(roomTable, model.toJson(), validate);
  Future<StoryBackendSelectionSnapshot> participantBackendSnapshot(
          StoryParticipantModel model,
          {required void Function() validate}) =>
      _backendSnapshot(participantTable, model.toJson(), validate);
  Future<StoryBackendSelectionSnapshot> _backendSnapshot(String table,
      Map<String, dynamic> model, void Function() validate) async {
    validate();
    final expected = StoryBackendSelectionSnapshot._(table, model);
    final rows = await storage.db
        .query(table, where: expected.where, whereArgs: expected.args);
    validate();
    if (rows.length != 1 ||
        expected.declaration !=
            StoryBackendSelectionSnapshot._declaration(rows.single)) {
      throw const StoryBackendSelectionStale();
    }
    return expected._withRow(rows.single);
  }

  Future<StoryRoomModel> saveRoomBackendChecked(StoryRoomModel model,
          BackendSelection? selection, StoryBackendSelectionSnapshot expected,
          {required void Function() validate,
          Map<String, Object?> fields = const {}}) async =>
      StoryRoomModel.fromJson(await _saveBackend(
          roomTable, model.toJson(), selection, expected, validate, fields));
  Future<StoryParticipantModel> saveParticipantBackendChecked(
          StoryParticipantModel model,
          BackendSelection? selection,
          StoryBackendSelectionSnapshot expected,
          {required void Function() validate,
          Map<String, Object?> fields = const {}}) async =>
      StoryParticipantModel.fromJson(await _saveBackend(participantTable,
          model.toJson(), selection, expected, validate, fields));
  Future<Map<String, Object?>> _saveBackend(
      String table,
      Map<String, dynamic> model,
      BackendSelection? selection,
      StoryBackendSelectionSnapshot expected,
      void Function() validate,
      Map<String, Object?> fields) async {
    if (selection != null && !selection.isValid) {
      throw const FormatException('后端选择格式无效');
    }
    final allowed = table == roomTable
        ? const {'temperature', 'topP', 'maxOutputTokens'}
        : const {
            'name',
            'prompt',
            'voiceStyle',
            'temperature',
            'topP',
            'maxOutputTokens'
          };
    if (fields.keys.any((k) => !allowed.contains(k))) {
      throw const FormatException('设置字段无效');
    }
    for (final entry in fields.entries) {
      final value = entry.value;
      if (entry.key == 'temperature' || entry.key == 'topP') {
        if (value != null &&
            (value is! num ||
                !value.isFinite ||
                value < 0 ||
                value > (entry.key == 'topP' ? 1 : 2))) {
          throw const FormatException('生成参数无效');
        }
      } else if (entry.key == 'maxOutputTokens') {
        if (value != null && (value is! int || value < 0)) {
          throw const FormatException('生成参数无效');
        }
      } else if (value is! String ||
          (entry.key == 'name' && value.trim().isEmpty)) {
        throw const FormatException('角色资料无效');
      }
    }
    // 未编辑selection只更新明确字段，原NULL/follow/pair/未知原文都不被覆盖。
    final patch = Map<String, Object?>.of(fields);
    if (selection != null) patch['backendSelection'] = selection.toSqlValue();
    return storage.db.transaction((txn) async {
      validate();
      if (table != expected.table || !expected.matchesModel(model)) {
        throw const StoryBackendSelectionStale();
      }
      final rows = await txn.query(table,
          where: expected.where, whereArgs: expected.args);
      validate();
      if (rows.length != 1 || !expected.matchesRow(rows.single)) {
        throw const StoryBackendSelectionStale();
      }
      final timestamp = math.max(DateTime.now().millisecondsSinceEpoch,
          (rows.single['updatedAt'] as int? ?? 0) + 1);
      final changed = await txn.update(
          table, {...patch, 'updatedAt': timestamp},
          where: expected.where, whereArgs: expected.args);
      validate();
      if (changed != 1) throw const StoryBackendSelectionStale();
      final saved = await txn.query(table,
          where: expected.where, whereArgs: expected.args);
      validate();
      return saved.single;
    });
  }

  Future<void> updateRoomGeneratedContext(
      int roomId, String context, String cards,
      {void Function()? validate}) async {
    await storage.db.transaction((txn) async {
      validate?.call();
      await txn.update(
          roomTable,
          {
            'publicContext': context,
            'roleCardContextJson': cards,
            'updatedAt': DateTime.now().millisecondsSinceEpoch
          },
          where: 'id=?',
          whereArgs: [roomId]);
      validate?.call();
    });
  }

  Future<void> updateGeneratedWorldState(int roomId, String state,
      {required void Function() validate}) async {
    await storage.db.transaction((txn) async {
      validate();
      await txn.update(roomTable, {'worldBookState': state},
          where: 'id=?', whereArgs: [roomId]);
      validate();
    });
  }

  Future<int> saveRoom(StoryRoomModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final data = model.toJson()..remove('id');
    if (model.id == null) {
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      return id;
    }
    BackendSelection.preserveLegacyUpdate(data);
    await storage.db
        .update(tableName, data, where: 'id = ?', whereArgs: [model.id]);
    return model.id!;
  }

  /// 只更新搜索偏好，避免开关覆盖并发保存的房间内容或模型参数。
  Future<int> updateWebSearchOverride(int roomId, bool? enabled) {
    return storage.db.update(
      tableName,
      {
        'webSearchEnabled': enabled == null ? null : (enabled ? 1 : 0),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [roomId],
    );
  }

  /// 将已验证的 Tavern 导入计划作为一组数据落库；任一写入失败都会回滚。
  Future<int> saveTavernImport({
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required List<StoryMessageModel> messages,
    StoryPersonaModel? persona,
  }) async {
    final inserted = await storage.db.transaction(
      (txn) => _insertTavernImport(
        txn,
        room: room,
        participants: participants,
        messages: messages,
        persona: persona,
        now: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _applyTavernImportResult(
      inserted,
      room: room,
      participants: participants,
      messages: messages,
      persona: persona,
    );
    return inserted.roomId;
  }

  /// 在调用方已有的事务中插入完整 Tavern 房间图。
  ///
  /// 该方法不创建嵌套事务，也不会在外层事务提交前修改传入对象。
  static Future<int> insertTavernImport(
    DatabaseExecutor executor, {
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required List<StoryMessageModel> messages,
    StoryPersonaModel? persona,
    required int now,
  }) async {
    final inserted = await _insertTavernImport(
      executor,
      room: room,
      participants: participants,
      messages: messages,
      persona: persona,
      now: now,
    );
    return inserted.roomId;
  }

  static Future<_TavernImportInsertResult> _insertTavernImport(
    DatabaseExecutor executor, {
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required List<StoryMessageModel> messages,
    required StoryPersonaModel? persona,
    required int now,
  }) async {
    int? personaId;
    if (persona != null) {
      final personaData = Map<String, dynamic>.from(persona.toJson())
        ..remove('id')
        ..['updatedAt'] = now;
      personaId = await executor.insert('tb_story_persona', personaData);
    }

    final roomCreatedAt = room.createdAt == 0 ? now : room.createdAt;
    final roomData = Map<String, dynamic>.from(room.toJson())
      ..remove('id')
      ..['mode'] = StoryRoomMode.tavern
      ..['createdAt'] = roomCreatedAt
      ..['updatedAt'] = now;
    final roomId = await executor.insert(roomTable, roomData);

    final participantIds = <int>[];
    final participantIdsByName = <String, int>{};
    for (final participant in participants) {
      final data = Map<String, dynamic>.from(participant.toJson())
        ..remove('id')
        ..['roomId'] = roomId
        ..['updatedAt'] = now;
      final id = await executor.insert(participantTable, data);
      participantIds.add(id);
      participantIdsByName.putIfAbsent(participant.name, () => id);
    }

    final messageIds = <int>[];
    final messageSpeakerIds = <int?>[];
    for (final message in messages) {
      final speakerId = !message.isUser && message.speakerId == null
          ? participantIdsByName[message.speakerName]
          : message.speakerId;
      final data = Map<String, dynamic>.from(message.toJson())
        ..remove('id')
        ..['roomId'] = roomId
        ..['speakerId'] = speakerId
        ..['updatedAt'] = now;
      final id = await executor.insert(messageTable, data);
      messageIds.add(id);
      messageSpeakerIds.add(speakerId);
    }

    final activeMessageKey = room.activeMessageKey ??
        (messages.isEmpty ? null : messages.last.nodeKey);
    await executor.update(
      roomTable,
      {'activeMessageKey': activeMessageKey, 'updatedAt': now},
      where: 'id = ?',
      whereArgs: [roomId],
    );
    return _TavernImportInsertResult(
      roomId: roomId,
      personaId: personaId,
      participantIds: participantIds,
      messageIds: messageIds,
      messageSpeakerIds: messageSpeakerIds,
      activeMessageKey: activeMessageKey,
      roomCreatedAt: roomCreatedAt,
      now: now,
    );
  }

  static void _applyTavernImportResult(
    _TavernImportInsertResult inserted, {
    required StoryRoomModel room,
    required List<StoryParticipantModel> participants,
    required List<StoryMessageModel> messages,
    required StoryPersonaModel? persona,
  }) {
    if (persona != null) {
      persona
        ..id = inserted.personaId
        ..updatedAt = inserted.now;
    }
    room
      ..id = inserted.roomId
      ..mode = StoryRoomMode.tavern
      ..createdAt = inserted.roomCreatedAt
      ..updatedAt = inserted.now
      ..activeMessageKey = inserted.activeMessageKey;
    for (var index = 0; index < participants.length; index++) {
      participants[index]
        ..id = inserted.participantIds[index]
        ..roomId = inserted.roomId
        ..updatedAt = inserted.now;
    }
    for (var index = 0; index < messages.length; index++) {
      messages[index]
        ..id = inserted.messageIds[index]
        ..roomId = inserted.roomId
        ..speakerId = inserted.messageSpeakerIds[index]
        ..updatedAt = inserted.now;
    }
  }

  Future<List<StoryRoomModel>> getRooms() async {
    final rows = await storage.db.query(
      tableName,
      orderBy: 'updatedAt desc, id desc',
    );
    return rows.map(StoryRoomModel.fromJson).toList();
  }

  Future<StoryRoomModel?> getRoom(int id) async {
    final rows =
        await storage.db.query(tableName, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return StoryRoomModel.fromJson(rows.first);
  }

  Future<void> deleteRoom(int id) async {
    await storage.db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final messageIds = await txn.query(
        messageTable,
        columns: ['nodeKey'],
        where: 'roomId = ?',
        whereArgs: [id],
      );
      final participantIds = await txn.query(
        participantTable,
        columns: ['id'],
        where: 'roomId = ?',
        whereArgs: [id],
      );
      for (final row in messageIds) {
        await SyncTombstoneStore.record(
          txn,
          entity: 'story_message',
          id: row['nodeKey']!,
          updatedAt: now,
        );
      }
      for (final row in participantIds) {
        await SyncTombstoneStore.record(
          txn,
          entity: 'story_participant',
          id: row['id']!,
          updatedAt: now,
        );
      }
      await SyncTombstoneStore.record(
        txn,
        entity: 'story_room',
        id: id,
        updatedAt: now,
      );
      await txn.delete(messageTable, where: 'roomId = ?', whereArgs: [id]);
      await txn.delete(participantTable, where: 'roomId = ?', whereArgs: [id]);
      await txn.delete(tableName, where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> saveParticipant(StoryParticipantModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (model.participantKey.trim().isEmpty) {
      model.participantKey = StoryParticipantModel.newParticipantKey();
    }
    final data = model.toJson()..remove('id');
    if (model.id == null) {
      final id = await storage.db.insert(participantTable, data);
      model.id = id;
      return id;
    }
    BackendSelection.preserveLegacyUpdate(data);
    await storage.db.update(
      participantTable,
      data,
      where: 'id = ?',
      whereArgs: [model.id],
    );
    return model.id!;
  }

  Future<List<StoryParticipantModel>> getParticipants(
    int roomId, {
    bool includeDisabled = false,
  }) async {
    final rows = await storage.db.query(
      participantTable,
      where: includeDisabled ? 'roomId = ?' : 'roomId = ? and enabled = 1',
      whereArgs: [roomId],
      orderBy: 'sortOrder asc, id asc',
    );
    return rows.map(StoryParticipantModel.fromJson).toList();
  }

  Future<void> deleteParticipant(int id) async {
    await SyncTombstoneStore.record(
      storage.db,
      entity: 'story_participant',
      id: id,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await storage.db.delete(participantTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> saveMessage(StoryMessageModel model,
      {void Function()? validate, bool activate = true}) {
    return storage.db.transaction((txn) async {
      validate?.call();
      final now = DateTime.now().millisecondsSinceEpoch;
      model.updatedAt = now;
      if (model.parentNodeKey == null) {
        final rooms = await txn.query(
          tableName,
          columns: ['activeMessageKey'],
          where: 'id = ?',
          whereArgs: [model.roomId],
        );
        if (rooms.isNotEmpty) {
          model.parentNodeKey = rooms.first['activeMessageKey'] as String?;
        }
      }
      if ((model.speakerVoiceStyle == null ||
              model.speakerVoiceStyle!.trim().isEmpty) &&
          model.speakerId != null) {
        final participants = await txn.query(
          participantTable,
          columns: ['voiceStyle'],
          where: 'id = ?',
          whereArgs: [model.speakerId],
        );
        if (participants.isNotEmpty) {
          model.speakerVoiceStyle = participants.first['voiceStyle'] as String?;
        }
      }
      if (model.nodeKey.trim().isEmpty) {
        model.nodeKey = StoryMessageModel.newNodeKey();
      }
      if (model.roleStatesAfter.trim().isEmpty) {
        final participants = await txn.query(
          participantTable,
          columns: ['participantKey', 'stateSummary'],
          where: 'roomId = ?',
          whereArgs: [model.roomId],
        );
        model.roleStatesAfter = StoryRoleStateCodec.encode({
          for (final participant in participants)
            if ((participant['participantKey'] as String? ?? '')
                    .trim()
                    .isNotEmpty &&
                (participant['stateSummary'] as String? ?? '')
                    .trim()
                    .isNotEmpty)
              (participant['participantKey'] as String).trim():
                  (participant['stateSummary'] as String).trim(),
        });
      } else {
        model.roleStatesAfter = StoryRoleStateCodec.encode(
            StoryRoleStateCodec.decode(model.roleStatesAfter));
      }
      final data = model.toJson()..remove('id');
      final id = await txn.insert(messageTable, data);
      model.id = id;
      if (model.candidateGroupKey == null) {
        model.candidateGroupKey = model.nodeKey;
        await txn.update(
          messageTable,
          {'candidateGroupKey': model.candidateGroupKey},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      // 原许可撤销后的已收文本可留作未完成记录，不切换活动上下文。
      if (activate) {
        await txn.update(
          tableName,
          {'activeMessageKey': model.nodeKey, 'updatedAt': now},
          where: 'id = ?',
          whereArgs: [model.roomId],
        );
      }
      validate?.call();
      return id;
    });
  }

  Future<List<StoryMessageModel>> getMessages(int roomId) async {
    final rows = await storage.db.query(
      messageTable,
      where: 'roomId = ?',
      whereArgs: [roomId],
      orderBy: 'id asc',
    );
    return rows.map(StoryMessageModel.fromJson).toList();
  }

  /// 从全量消息沿活动叶向上回溯；坏链只保留可安全到达的部分。
  static List<StoryMessageModel> activePath(
    Iterable<StoryMessageModel> messages,
    String? activeMessageKey,
  ) {
    if (activeMessageKey == null || activeMessageKey.isEmpty) return const [];
    final byNodeKey = <String, StoryMessageModel>{
      for (final message in messages)
        if (message.nodeKey.isNotEmpty) message.nodeKey: message,
    };
    final start = byNodeKey[activeMessageKey];
    if (start == null) return const [];
    var current = start;

    final reversePath = <StoryMessageModel>[];
    final visited = <String>{};
    while (true) {
      final nodeKey = current.nodeKey;
      if (!visited.add(nodeKey)) break;
      reversePath.add(current);
      final parentNodeKey = current.parentNodeKey;
      if (parentNodeKey == null || parentNodeKey.isEmpty) break;
      final parent = byNodeKey[parentNodeKey];
      if (parent == null || visited.contains(parentNodeKey)) break;
      current = parent;
    }
    return reversePath.reversed.toList(growable: false);
  }

  Future<List<StoryMessageModel>> getActiveMessages(int roomId) async {
    final room = await getRoom(roomId);
    if (room == null) return const [];
    return activePath(
      await getMessages(roomId),
      room.activeMessageKey,
    );
  }

  Future<bool> activateMessage(int roomId, String nodeKey,
      {void Function()? validate}) async {
    return storage.db.transaction((txn) async {
      validate?.call();
      final messages = await txn.query(
        messageTable,
        columns: ['contextStateAfter', 'roleStatesAfter'],
        where: 'roomId = ? and nodeKey = ?',
        whereArgs: [roomId, nodeKey],
        limit: 1,
      );
      if (messages.isEmpty) return false;
      final now = DateTime.now().millisecondsSinceEpoch;
      await _restoreParticipantStates(
        txn,
        roomId,
        messages.first['roleStatesAfter'],
        now,
      );
      await txn.update(
        tableName,
        {
          'activeMessageKey': nodeKey,
          'worldBookState':
              messages.first['contextStateAfter'] as String? ?? '',
          'updatedAt': now,
        },
        where: 'id = ?',
        whereArgs: [roomId],
      );
      validate?.call();
      return true;
    });
  }

  Future<bool> updateParticipantState(
    int roomId,
    String participantKey,
    String stateSummary,
  ) {
    final normalizedKey = participantKey.trim();
    if (normalizedKey.isEmpty) return Future.value(false);
    final normalizedState = stateSummary.trim();
    return storage.db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final updated = await txn.update(
        participantTable,
        {'stateSummary': normalizedState, 'updatedAt': now},
        where: 'roomId = ? and participantKey = ?',
        whereArgs: [roomId, normalizedKey],
      );
      if (updated == 0) return false;
      final rooms = await txn.query(
        tableName,
        columns: ['activeMessageKey'],
        where: 'id = ?',
        whereArgs: [roomId],
        limit: 1,
      );
      final activeMessageKey =
          rooms.isEmpty ? null : rooms.first['activeMessageKey'] as String?;
      if (activeMessageKey == null || activeMessageKey.isEmpty) return true;
      final messages = await txn.query(
        messageTable,
        columns: ['id', 'roleStatesAfter'],
        where: 'roomId = ? and nodeKey = ?',
        whereArgs: [roomId, activeMessageKey],
        limit: 1,
      );
      if (messages.isEmpty) return true;
      final states =
          StoryRoleStateCodec.decode(messages.first['roleStatesAfter']);
      if (normalizedState.isEmpty) {
        states.remove(normalizedKey);
      } else {
        states[normalizedKey] = normalizedState;
      }
      await txn.update(
        messageTable,
        {
          'roleStatesAfter': StoryRoleStateCodec.encode(states),
          'updatedAt': now,
        },
        where: 'id = ?',
        whereArgs: [messages.first['id']],
      );
      await txn.update(
        tableName,
        {'updatedAt': now},
        where: 'id = ?',
        whereArgs: [roomId],
      );
      return true;
    });
  }

  Future<List<StoryMessageModel>> getMessageVariants(
    int roomId,
    String candidateGroupKey,
  ) async {
    final rows = await storage.db.query(
      messageTable,
      where: 'roomId = ? and candidateGroupKey = ?',
      whereArgs: [roomId, candidateGroupKey],
      orderBy: 'id asc',
    );
    return rows.map(StoryMessageModel.fromJson).toList();
  }

  Future<void> deleteMessageSubtree(int roomId, String nodeKey) async {
    await storage.db.transaction((txn) async {
      final rows = await txn.query(
        messageTable,
        where: 'roomId = ?',
        whereArgs: [roomId],
        orderBy: 'id asc',
      );
      final messages = rows.map(StoryMessageModel.fromJson).toList();
      final root = messages.where((message) => message.nodeKey == nodeKey);
      if (root.isEmpty) return;

      final children = <String, List<String>>{};
      for (final message in messages) {
        final parentNodeKey = message.parentNodeKey;
        if (parentNodeKey != null && parentNodeKey.isNotEmpty) {
          (children[parentNodeKey] ??= []).add(message.nodeKey);
        }
      }
      final deletedNodeKeys = <String>{};
      final pending = <String>[nodeKey];
      while (pending.isNotEmpty) {
        final currentNodeKey = pending.removeLast();
        if (!deletedNodeKeys.add(currentNodeKey)) continue;
        pending.addAll(children[currentNodeKey] ?? const []);
      }

      final rootParentNodeKey = root.single.parentNodeKey;
      final nextActiveMessageKey = deletedNodeKeys.contains(rootParentNodeKey)
          ? null
          : rootParentNodeKey;
      final parent = messages.where(
        (message) => message.nodeKey == nextActiveMessageKey,
      );
      final nextWorldBookState =
          parent.isEmpty ? '' : parent.single.contextStateAfter;
      final nextRoleStatesAfter =
          parent.isEmpty ? '' : parent.single.roleStatesAfter;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final deletedNodeKey in deletedNodeKeys) {
        final message = messages.firstWhere(
          (item) => item.nodeKey == deletedNodeKey,
        );
        await SyncTombstoneStore.record(
          txn,
          entity: 'story_message',
          id: deletedNodeKey,
          updatedAt: now,
        );
        await txn
            .delete(messageTable, where: 'id = ?', whereArgs: [message.id]);
      }
      await _restoreParticipantStates(
        txn,
        roomId,
        nextRoleStatesAfter,
        now,
      );
      await txn.update(
        tableName,
        {
          'activeMessageKey': nextActiveMessageKey,
          'worldBookState': nextWorldBookState,
          'updatedAt': now,
        },
        where: 'id = ?',
        whereArgs: [roomId],
      );
    });
  }

  Future<void> updateMessage(StoryMessageModel model) async {
    final id = model.id;
    if (id == null) throw ArgumentError('更新消息需要 id');
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final data = model.toJson()..remove('id');
    await storage.db.transaction((txn) async {
      await txn.update(
        messageTable,
        data,
        where: 'id = ?',
        whereArgs: [id],
      );
      final rooms = await txn.query(
        tableName,
        columns: ['activeMessageKey'],
        where: 'id = ?',
        whereArgs: [model.roomId],
        limit: 1,
      );
      final room = rooms.isEmpty ? null : rooms.first;
      await txn.update(
        tableName,
        {
          'updatedAt': model.updatedAt,
          if (room?['activeMessageKey'] == model.nodeKey)
            'worldBookState': model.contextStateAfter,
        },
        where: 'id = ?',
        whereArgs: [model.roomId],
      );
    });
  }

  Future<void> deleteMessage(int id) async {
    await SyncTombstoneStore.record(
      storage.db,
      entity: 'story_message',
      id: id,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await storage.db.delete(messageTable, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> _restoreParticipantStates(
    dynamic txn,
    int roomId,
    Object? rawStates,
    int updatedAt,
  ) async {
    final states = StoryRoleStateCodec.decode(rawStates);
    final participants = await txn.query(
      participantTable,
      columns: ['id', 'participantKey'],
      where: 'roomId = ?',
      whereArgs: [roomId],
    );
    for (final participant in participants) {
      final participantKey = participant['participantKey'] as String? ?? '';
      await txn.update(
        participantTable,
        {
          'stateSummary': states[participantKey] ?? '',
          'updatedAt': updatedAt,
        },
        where: 'id = ?',
        whereArgs: [participant['id']],
      );
    }
  }
}

/// 身份由调用方原编辑scope验证；这里只给原行与房间归属CAS，不补签账号。
class StoryBackendSelectionSnapshot {
  final String table;
  final Map<String, dynamic> _model;
  final Map<String, Object?>? _row;
  StoryBackendSelectionSnapshot._(this.table, Map<String, dynamic> model,
      [Map<String, Object?>? row])
      : _model = Map.unmodifiable(model),
        _row = row == null ? null : Map.unmodifiable(row) {
    if (model['id'] is! int || (model['id'] as int) <= 0) {
      throw const StoryBackendSelectionStale();
    }
    if (table == StoryRoomDao.participantTable &&
        (model['roomId'] is! int ||
            model['participantKey'] is! String ||
            (model['participantKey'] as String).trim().isEmpty)) {
      throw const StoryBackendSelectionStale();
    }
  }
  StoryBackendSelectionSnapshot _withRow(Map<String, Object?> row) =>
      StoryBackendSelectionSnapshot._(table, _model, row);
  String get where => table == StoryRoomDao.participantTable
      ? 'id=? and roomId=? and participantKey=?'
      : 'id=?';
  List<Object?> get args => table == StoryRoomDao.participantTable
      ? [_model['id'], _model['roomId'], _model['participantKey']]
      : [_model['id']];
  String get declaration => _declaration(_model);
  bool matchesModel(Map<String, dynamic> model) =>
      _text(model) == _text(_model);
  bool matchesRow(Map<String, Object?> row) =>
      _row != null && _text(row) == _text(_row!);
  static String _declaration(Map<String, Object?> row) => jsonEncode([
        row['id'],
        row['roomId'],
        row['participantKey'],
        row['backendSelection'],
        row['modelProviderId'],
        row['modelId']
      ]);
  static String _text(Map<String, Object?> row) {
    final keys = row.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: row[key]});
  }
}

class StoryBackendSelectionStale implements Exception {
  const StoryBackendSelectionStale();
  @override
  String toString() => '原房间或角色已变化，请重新打开选择';
}
