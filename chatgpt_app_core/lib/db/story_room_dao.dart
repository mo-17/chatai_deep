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
        ', publicContext text, worldBookState text, modelProviderId text, modelId text'
        ', temperature real, maxOutputTokens integer'
        ', createdAt integer, updatedAt integer)');
    await _ensureRoomColumns(storage);
    await storage.db.execute(
        'create table if not exists tb_story_participant (id integer primary key autoincrement'
        ', roomId integer not null, assistantId integer, role text, name text'
        ', prompt text, avatarType text, avatarValue text'
        ', voiceStyle text, modelProviderId text, modelId text'
        ', temperature real, maxOutputTokens integer'
        ', sortOrder integer, enabled integer, createdAt integer, updatedAt integer)');
    await _ensureParticipantColumns(storage);
    await storage.db.execute(
        'create index if not exists tb_story_participant_room_idx on tb_story_participant(roomId, sortOrder)');
    await storage.db.execute(
        'create table if not exists tb_story_message (id integer primary key autoincrement'
        ', roomId integer not null, speakerId integer, speakerRole text'
        ', speakerName text, speakerAvatarType text, speakerAvatarValue text'
        ', speakerVoiceStyle text, content text, imagePaths text, imageSources text'
        ', citationUrls text, filePaths text'
        ', attachmentContext text, createdAt integer, updatedAt integer)');
    await _ensureMessageColumns(storage);
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
    ]) {
      try {
        await storage.db
            .execute('alter table tb_story_participant add column $column');
      } catch (_) {
        // 已存在列时忽略，保持旧库可升级。
      }
    }
  }

  static Future<void> _ensureMessageColumns(HiDBManager storage) async {
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
        columns: ['id'],
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
          id: row['id']!,
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

  Future<int> saveMessage(StoryMessageModel model) async {
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    if ((model.speakerVoiceStyle == null ||
            model.speakerVoiceStyle!.trim().isEmpty) &&
        model.speakerId != null) {
      final participants = await storage.db.query(
        participantTable,
        columns: ['voiceStyle'],
        where: 'id = ?',
        whereArgs: [model.speakerId],
      );
      if (participants.isNotEmpty) {
        model.speakerVoiceStyle = participants.first['voiceStyle'] as String?;
      }
    }
    final data = model.toJson()..remove('id');
    final id = await storage.db.insert(messageTable, data);
    model.id = id;
    await storage.db.update(
      tableName,
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [model.roomId],
    );
    return id;
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

  Future<void> updateMessage(StoryMessageModel model) async {
    final id = model.id;
    if (id == null) throw ArgumentError('更新消息需要 id');
    model.updatedAt = DateTime.now().millisecondsSinceEpoch;
    final data = model.toJson()..remove('id');
    await storage.db.update(
      messageTable,
      data,
      where: 'id = ?',
      whereArgs: [id],
    );
    await storage.db.update(
      tableName,
      {'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [model.roomId],
    );
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
}
