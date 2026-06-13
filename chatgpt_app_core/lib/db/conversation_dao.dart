import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:openai_flutter/utils/ai_logger.dart';
import 'package:sqflite/sqflite.dart';

///会话列表数据操作接口
abstract class IConversationList {
  ///保存会话并返回数据库记录的id
  Future<int?> saveConversation(ConversationModel model);

  void deleteConversation(ConversationModel model);

  ///分页查询，pageIndex页码从1开始，pageSize每页显示的数据量
  Future<List<ConversationModel>> getConversationList(
      {int pageIndex = 1, int pageSize = 20});

  ///置顶与取消置顶
  Future<int> updateStickTime(ConversationModel model, {bool isStick = false});

  ///查询置顶的会话
  Future<List<ConversationModel>> getStickConversationList();
}

class ConversationListDao implements IConversationList, ITable {
  final HiDBManager storage;

  ConversationListDao._(this.storage);

  static const _kTableName = 'tb_conversation_list';

  /// 静态工厂，确保表和索引创建完成后再返回实例
  static Future<ConversationListDao> create(HiDBManager storage) async {
    await storage.db.execute(
        'create table if not exists $_kTableName (id integer primary key autoincrement'
        ', cid integer, title	text, icon	text, updateAt	integer'
        ', messageCount	integer, lastMessage	text, stickTime	integer'
        ', assistantId	integer);');
    await storage.db.execute(
        'create unique index if not exists ${_kTableName}_cid_idx on $_kTableName (cid);');
    // 兼容旧表：无 assistantId 列时自动新增（阶段七 会话绑定助手）。
    try {
      await storage.db.execute(
          'alter table $_kTableName add column assistantId integer');
    } catch (_) {
      // 列已存在，忽略
    }
    //复合索引：置顶+更新时间排序优化
    await storage.db.execute(
        'create index if not exists ${_kTableName}_stick_update_idx on $_kTableName(stickTime, updateAt desc);');
    return ConversationListDao._(storage);
  }

  @override
  String tableName = 'tb_conversation_list';

  @override
  void deleteConversation(ConversationModel model) {
    if (model.id == null) {
      storage.db.delete(tableName, where: 'cid = ?', whereArgs: [model.cid]);
    } else {
      storage.db.delete(tableName, where: 'id = ?', whereArgs: [model.id]);
    }

    ///删除对应聊天记录（统一 tb_messages 表，按 cid 删除）
    storage.db.delete('tb_messages', where: 'cid = ?', whereArgs: [model.cid]);
  }

  @override
  Future<List<ConversationModel>> getConversationList(
      {int pageIndex = 1, int pageSize = 20}) async {
    var offset = (pageIndex - 1) * pageSize;
    var results = await storage.db.query(tableName,
        where: 'stickTime <= 0',
        orderBy: 'updateAt desc',
        limit: pageSize,
        offset: offset);

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => ConversationModel.fromJson(item)).toList();
    AILogger.log('conversation list count:${list.length}');
    return list;
  }

  @override
  Future<int?> saveConversation(ConversationModel model) async {
    final id = await storage.db.insert(tableName, model.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    model.id = id;
    return id;
  }

  @override
  Future<List<ConversationModel>> getStickConversationList() async {
    var results = await storage.db.query(tableName,
        where: 'stickTime > 0', orderBy: 'stickTime desc');

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => ConversationModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<int> updateStickTime(ConversationModel model, {bool isStick = false}) {
    if (isStick) {
      model.stickTime = DateTime.now().millisecondsSinceEpoch;
    } else {
      model.stickTime = 0;
    }
    //ConflictAlgorithm.ignore 当唯一键冲突时，仅更新没有冲突的字段
    return storage.db.update(tableName, model.toJson(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }
}
