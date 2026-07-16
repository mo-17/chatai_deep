import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
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
  static Future<MessageDao> create(HiDBManager storage,
      {required int cid}) async {
    await storage.db.execute(
        'create table if not exists tb_messages (id integer primary key autoincrement'
        ', cid integer not null, content text, createdAt integer'
        ', ownerName text, ownerType text, avatar text'
        ', images text, blocks text)');
    await storage.db.execute(
        'create index if not exists tb_messages_cid_id_idx on tb_messages(cid, id desc)');
    // 兼容旧表：缺少 images / blocks 时自动新增（块化消息系统）。
    // blocks 存一条消息的块列表 JSON；content 仍存「主文本」用于历史上下文与预览。
    await SchemaGuard.ensureColumns(
      storage.db,
      table: 'tb_messages',
      columns: const {
        'images': 'text',
        'blocks': 'text',
      },
    );
    return MessageDao._(storage, cid: cid);
  }

  @override
  Future<int> deleteMessage(int id) {
    return storage.db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  /// 按 createdAt 删除本会话内的一条消息。
  /// 本次会话内新发送/接收的消息，其内存模型还没有数据库自增 id（id 为 null），
  /// 无法走 [deleteMessage]；createdAt 在单个会话内唯一，用 cid + createdAt 定位即可。
  Future<int> deleteMessageByCreatedAt(int createdAt) {
    return storage.db.delete(tableName,
        where: 'cid = ? and createdAt = ?', whereArgs: [cid, createdAt]);
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
        columns: ['COUNT(*) as cnt'], where: 'cid = ?', whereArgs: [cid]);
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

  /// 保存一条带块列表的消息（assistant 块化消息用）。
  /// [blocksJson] 为 `MessageBlock.encodeList(...)` 的结果。返回新行 id。
  Future<int> saveMessageWithBlocks(MessageModel model, {String? blocksJson}) {
    final data = model.toJson();
    data['cid'] = cid;
    if (blocksJson != null && blocksJson.isNotEmpty) {
      data['blocks'] = blocksJson;
    }
    return storage.db.insert(tableName, data);
  }

  /// 按 createdAt 批量读取这些消息的块列表 JSON。
  /// 返回 `chatMessageKey(createdAt) -> blocksJson`，只含有块的消息。
  /// 用于历史会话恢复时给 [ChatBlockStore] 做 seed。
  Future<Map<String, String>> getBlocksByCreatedAt(
      Iterable<int> createdAts) async {
    final ids = createdAts.toList();
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await storage.db.query(
      tableName,
      columns: ['createdAt', 'blocks'],
      where: 'cid = ? and createdAt in ($placeholders)',
      whereArgs: [cid, ...ids],
    );
    final map = <String, String>{};
    for (final r in rows) {
      final blocks = r['blocks'] as String?;
      final createdAt = r['createdAt'] as int?;
      if (blocks != null && blocks.isNotEmpty && createdAt != null) {
        map[chatMessageKey(createdAt)] = blocks;
      }
    }
    return map;
  }

  @override
  void update(MessageModel model) {
    storage.db.update(tableName, model.toJson(),
        where: 'id = ?', whereArgs: [model.id]);
  }
}
