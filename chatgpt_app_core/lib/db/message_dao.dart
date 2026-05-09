import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/table_name.dart';

///消息表数据操作接口
abstract class IMessage {
  void saveMessage(MessageModel model);

  Future<int> deleteMessage(int id);

  void update(MessageModel model);

  Future<List<MessageModel>> getAllMessage();

  ///分页查询，pageIndex页码从1开始，pageSize每页显示的数据量
  Future<List<MessageModel>> getMessages(
      {int pageIndex = 1, int pageSize = 20});

  Future<int> getMessageCount();
}

///统一消息表 tb_messages，所有会话的消息存储在同一张表中，通过 cid 区分
class MessageDao implements IMessage, ITable {
  final HiDBManager storage;

  ///会话id
  final int cid;
  @override
  String tableName = 'tb_messages';

  MessageDao._(this.storage, {required this.cid});

  /// 静态工厂，确保表和索引创建完成后再返回实例
  static Future<MessageDao> create(HiDBManager storage, {required int cid}) async {
    await storage.db.execute(
        'create table if not exists tb_messages (id integer primary key autoincrement'
        ', cid integer not null, content text, createdAt integer'
        ', ownerName text, ownerType text, avatar text)');
    await storage.db.execute(
        'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
    return MessageDao._(storage, cid: cid);
  }

  @override
  Future<int> deleteMessage(int id) {
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<MessageModel>> getAllMessage() async {
    var results = await storage.db.query(tableName,
        where: 'cid = ?', whereArgs: [cid], orderBy: 'id asc');
    var list = results.map((item) => MessageModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<int> getMessageCount() async {
    var result = await storage.db.query(tableName,
        columns: ['COUNT(*) as cnt'],
        where: 'cid = ?',
        whereArgs: [cid]);
    return result.first['cnt'] as int;
  }

  @override
  Future<List<MessageModel>> getMessages(
      {int pageIndex = 1, int pageSize = 15}) async {
    var offset = (pageIndex - 1) * pageSize;
    var results = await storage.db.query(tableName,
        where: 'cid = ?',
        whereArgs: [cid],
        orderBy: 'id desc',
        limit: pageSize,
        offset: offset);

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => MessageModel.fromJson(item)).toList();

    ///反转列表以适应分页查询
    return List.from(list.reversed);
  }

  @override
  void saveMessage(MessageModel model) {
    final data = model.toJson();
    data['cid'] = cid;
    storage.db.insert(tableName, data);
  }

  @override
  void update(MessageModel model) {
    storage.db.update(tableName, model.toJson(),
        where: 'id = ?', whereArgs: [model.id]);
  }
}
