import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';

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
        ', publicContext text, createdAt integer, updatedAt integer)');
    await _ensureRoomColumns(storage);
    await storage.db.execute(
        'create table if not exists tb_story_participant (id integer primary key autoincrement'
        ', roomId integer not null, assistantId integer, role text, name text'
        ', prompt text, avatarType text, avatarValue text'
        ', sortOrder integer, enabled integer, createdAt integer, updatedAt integer)');
    await storage.db.execute(
        'create index if not exists tb_story_participant_room_idx on tb_story_participant(roomId, sortOrder)');
    await storage.db.execute(
        'create table if not exists tb_story_message (id integer primary key autoincrement'
        ', roomId integer not null, speakerId integer, speakerRole text'
        ', speakerName text, speakerAvatarType text, speakerAvatarValue text'
        ', content text, createdAt integer)');
    await storage.db.execute(
        'create index if not exists tb_story_message_room_idx on tb_story_message(roomId, id asc)');
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

  Future<List<StoryParticipantModel>> getParticipants(int roomId) async {
    final rows = await storage.db.query(
      participantTable,
      where: 'roomId = ? and enabled = 1',
      whereArgs: [roomId],
      orderBy: 'sortOrder asc, id asc',
    );
    return rows.map(StoryParticipantModel.fromJson).toList();
  }

  Future<void> deleteParticipant(int id) async {
    await storage.db.delete(participantTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> saveMessage(StoryMessageModel model) async {
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
}
