import 'dart:convert';

import 'package:chatgpt_flutter/db/hi_db_manager.dart';
import 'package:chatgpt_flutter/db/message_dao.dart';
import 'package:chatgpt_flutter/db/table_name.dart';
import 'package:chatgpt_flutter/model/conversation_model.dart';
import 'package:flutter/cupertino.dart';
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

  ///构造方法中，进行数据表的检查和创建
  ConversationListDao(this.storage) {
    // id	integer	主键、自增
    // cid	integer	会话id
    // title	text	会话标题
    // icon	text	会话图标
    // updateAt	integer	会话更新时间
    // messageCount	integer	消息数
    // lastMessage	text	最后一条消息
    // stickTime	integer	置顶的时间，millisecondsSinceEpoch，0表示不置顶
    //创建表
    storage.db.execute(
        'create table if not exists $tableName (id integer primary key autoincrement'
        ', cid integer, title	text, icon	text, updateAt	integer'
        ', messageCount	integer, lastMessage	text, stickTime	integer);');
    //创建唯一索引，以便能够使用title作为唯一键来更新数据
    storage.db.execute(
        'create unique index if not exists ${tableName}_cid_idx on $tableName (cid);');
  }

  @override
  String tableName = 'tb_conversation_list';

  @override
  void deleteConversation(ConversationModel model) {
    //删除聊天列表记录
    if (model.id == null) {
      storage.db.delete(tableName, where: 'cid=${model.cid}');
    } else {
      storage.db.delete(tableName, where: 'id=${model.id}');
    }

    ///删除对应聊天记录，这里删除表之后，如果对话框页面消息回来了，会出现插入数据的时候找不到表Error（no such table）输出（属于预期内）
    storage.db.execute(
        'drop table if exists ${MessageDao.tableNameByCid(model.cid)}');
  }

  @override
  Future<List<ConversationModel>> getConversationList(
      {int pageIndex = 1, int pageSize = 20}) async {
    var offset = (pageIndex - 1) * pageSize;
    var results = await storage.db.rawQuery(
        'select * from $tableName where cast(stickTime as integer) <=0 '
        'order by updateAt desc limit $pageSize offset $offset');

    ///将查询结果转成Dart Model以方便使用
    var list = results.map((item) => ConversationModel.fromJson(item)).toList();
    debugPrint('count:${list.length}');
    debugPrint(jsonEncode(list));
    return list;
  }

  @override
  Future<int?> saveConversation(ConversationModel model) async {
    await storage.db.insert(tableName, model.toJson(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    var result = await storage.db.query(tableName, where: 'cid = ${model.cid}');
    var resultModel = ConversationModel.fromJson(result.first);
    //解决新建的会话没有id的问题
    if (resultModel.id != null) {
      model.id = resultModel.id;
    }
    return resultModel.id;
  }

  @override
  Future<List<ConversationModel>> getStickConversationList() async {
    ///SQL 使用比较时最好将数据转成和比较的相同的类型，以适配NULL和空字符串
    var results = await storage.db.rawQuery(
        'select * from $tableName where cast(stickTime as integer) > 0 '
        'order by stickTime desc;');

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
