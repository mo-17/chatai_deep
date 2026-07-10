import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/sync/sync_tombstone_store.dart';

class StoryRoomDao implements ITable {
  final HiDBManager storage;

  @override
  String tableName = 'tb_story_room';

  static const participantTable = 'tb_story_participant';
  static const messageTable = 'tb_story_message';

  StoryRoomDao._(this.storage);

  static Future<StoryRoomDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists tb_story_room (id integer primary key autoincrement'
        ', title text, mode text, replyMode text, maxAutoReplies integer'
        ', publicContext text, worldBookState text'
        ', promptConfigJson text, quickRepliesJson text'
        ', modelProviderId text, modelId text'
        ', temperature real, maxOutputTokens integer'
        ', activeMessageKey text'
        ', createdAt integer, updatedAt integer)');
    await _ensureRoomColumns(storage);
    await storage.db.execute(
        'create table if not exists tb_story_participant (id integer primary key autoincrement'
        ', roomId integer not null, assistantId integer, role text, name text'
        ', prompt text, avatarType text, avatarValue text'
        ', voiceStyle text, modelProviderId text, modelId text'
        ', temperature real, maxOutputTokens integer'
        ', participantKey text not null, stateSummary text'
        ', sortOrder integer, enabled integer, createdAt integer, updatedAt integer)');
    await _ensureParticipantColumns(storage);
    await storage.db.execute(
        'create index if not exists tb_story_participant_room_idx on tb_story_participant(roomId, sortOrder)');
    await storage.db.execute(
        'create unique index if not exists tb_story_participant_room_key_uq on tb_story_participant(roomId, participantKey)');
    await storage.db.execute(
        'create table if not exists tb_story_message (id integer primary key autoincrement'
        ', roomId integer not null, speakerId integer, speakerRole text'
        ', speakerName text, speakerAvatarType text, speakerAvatarValue text'
        ', speakerVoiceStyle text, content text, imagePaths text, imageSources text'
        ', citationUrls text, filePaths text'
        ', attachmentContext text, nodeKey text not null, parentNodeKey text'
        ', candidateGroupKey text, contextStateAfter text, roleStatesAfter text'
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
      'modelProviderId text',
      'modelId text',
      'temperature real',
      'maxOutputTokens integer',
      'worldBookState text',
      'promptConfigJson text',
      'quickRepliesJson text',
      'activeMessageKey text',
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

  Future<int> saveRoom(StoryRoomModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final data = model.toJson()..remove('id');
    if (model.id == null) {
      final id = await storage.db.insert(tableName, data);
      model.id = id;
      return id;
    }
    await storage.db
        .update(tableName, data, where: 'id = ?', whereArgs: [model.id]);
    return model.id!;
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

  Future<int> saveMessage(StoryMessageModel model) {
    return storage.db.transaction((txn) async {
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
      await txn.update(
        tableName,
        {'activeMessageKey': model.nodeKey, 'updatedAt': now},
        where: 'id = ?',
        whereArgs: [model.roomId],
      );
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

  Future<bool> activateMessage(int roomId, String nodeKey) async {
    return storage.db.transaction((txn) async {
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
