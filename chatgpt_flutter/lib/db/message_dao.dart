import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_flutter/db/hi_db_manager.dart';
import 'package:chatgpt_flutter/db/table_name.dart';

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

///https://github.com/tekartik/sqflite/blob/master/sqflite/doc/sql.md
///IMessage的的具体实现
class MessageDao implements IMessage, ITable {
  final HiDBManager storage;

  ///会话id
  final int cid;
  @override
  String tableName = '';

//  字段	类型	备注
//  id	integer	主键、自增
//  content	text	消息内容
//  createdAt	integer	消息创建时间
//  ownerName	text	发送者昵称
//  ownerType	text	发送者类型（receiver, sender）
//  avatar	text	发送者头像
  MessageDao(this.storage, {required this.cid})
      : tableName = tableNameByCid(cid) {
    storage.db.execute(
        'create table if not exists $tableName (id integer primary key autoincrement, content	text'
        ', createdAt	integer, ownerName	text, ownerType	text, avatar	text)');
  }

  ///获取带cid的表名称
  static String tableNameByCid(int cid) {
    return 'tb_$cid';
  }

  @override
  Future<int> deleteMessage(int id) {
    return storage.db.delete(tableName, where: 'id=$id');
  }

  @override
  Future<List<MessageModel>> getAllMessage() async {
    var results =
        await storage.db.rawQuery('select * from $tableName order by id asc');

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => MessageModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<int> getMessageCount() async {
    var result =
        await storage.db.query(tableName, columns: ['COUNT(*) as cnt']);
    return result.first['cnt'] as int;
  }

  @override
  Future<List<MessageModel>> getMessages(
      {int pageIndex = 1, int pageSize = 15}) async {
    var offset = (pageIndex - 1) * pageSize;
    var results = await storage.db.rawQuery(
        'select * from $tableName order by id desc limit $pageSize offset $offset');

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => MessageModel.fromJson(item)).toList();

    ///反转列表以适应分页查询
    return List.from(list.reversed);
  }

  @override
  void saveMessage(MessageModel model) {
    storage.db.insert(tableName, model.toJson());
  }

  @override
  void update(MessageModel model) {
    storage.db.update(tableName, model.toJson(),
        where: 'id = ?', whereArgs: [model.id]);
  }
}
