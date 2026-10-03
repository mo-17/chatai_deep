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

/// 请求历史的有限候选集，与聊天列表的分页展示相互独立。
class MessageContextCandidates {
  final List<MessageModel> messages;
  final bool hasEarlierMessages;
  final int storedBytes;
  final bool exceededStoredByteBudget;

  const MessageContextCandidates({
    required this.messages,
    required this.hasEarlierMessages,
    required this.storedBytes,
    required this.exceededStoredByteBudget,
  });
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
    final results = await storage.db.query(tableName,
        where: 'cid = ?', whereArgs: [cid], orderBy: 'id asc');
    final list = results.map((item) => MessageModel.fromJson(item)).toList();
    return list;
  }

  @override
  Future<int> getMessageCount() async {
    final result = await storage.db.query(tableName,
        columns: ['COUNT(*) as cnt'], where: 'cid = ?', whereArgs: [cid]);
    return result.first['cnt'] as int;
  }

  @override
  Future<List<MessageModel>> getMessages(
      {int pageIndex = 1, int pageSize = 15}) async {
    final offset = (pageIndex - 1) * pageSize;
    final results = await storage.db.query(tableName,
        where: 'cid = ?',
        whereArgs: [cid],
        orderBy: 'id desc',
        limit: pageSize,
        offset: offset);

    ///将查询结果转成Dart Model以方便使用
    final list = results.map((item) => MessageModel.fromJson(item)).toList();

    ///反转列表以适应分页查询
    return List.from(list.reversed);
  }

  /// 先在 SQLite 内测量正文/图片/块的字节数，避免一次反序列化海量 Base64。
  /// 候选按连续的最新范围加载，触及边界时尽量从 user 开始保留完整轮次。
  /// 最新完整 user 轮即使独自超出字节预算仍保留，之后不再累积更早轮次。
  Future<MessageContextCandidates> loadContextCandidates({
    int maxMessages = 1000,
    int maxStoredBytes = 8 * 1024 * 1024,
  }) async {
    if (maxMessages <= 0 || maxMessages > 10000) {
      throw ArgumentError.value(maxMessages, 'maxMessages', '必须为 1 到 10000');
    }
    if (maxStoredBytes <= 0) {
      throw ArgumentError.value(maxStoredBytes, 'maxStoredBytes', '必须大于 0');
    }
    return storage.db.transaction((txn) async {
      final selected = <Map<String, Object?>>[];
      final pendingTurn = <Map<String, Object?>>[];
      int? beforeId;
      var storedBytes = 0;
      var pendingBytes = 0;
      var latestUserFound = false;
      var hasEarlier = false;
      var stop = false;
      while (!stop) {
        final metadata = await txn.rawQuery(
          'select id, ownerType, '
          'coalesce(length(cast(content as blob)), 0) + '
          'coalesce(length(cast(images as blob)), 0) + '
          'coalesce(length(cast(blocks as blob)), 0) + '
          'coalesce(length(cast(ownerName as blob)), 0) + '
          'coalesce(length(cast(avatar as blob)), 0) as storedBytes '
          'from $tableName where cid = ? '
          '${beforeId == null ? '' : 'and id < ? '}order by id desc limit 64',
          [cid, if (beforeId != null) beforeId],
        );
        if (metadata.isEmpty) break;
        for (final row in metadata) {
          final rowBytes = row['storedBytes'] as int;
          final isUser = row['ownerType'] != OwnerType.receiver.toString();
          if (selected.length + pendingTurn.length >= maxMessages) {
            hasEarlier = true;
            stop = true;
            break;
          }
          beforeId = row['id'] as int;
          if (!latestUserFound) {
            // 最近图片通常存于 user，不能只因最后 assistant 较小就漏掉原图。
            // 没有 user 的异常旧记录仍按字节预算停止，避免无限累积 assistant。
            if (selected.isNotEmpty &&
                !isUser &&
                storedBytes + rowBytes > maxStoredBytes) {
              hasEarlier = true;
              stop = true;
              break;
            }
            selected.add(row);
            storedBytes += rowBytes;
            latestUserFound = isUser;
          } else {
            if (storedBytes + pendingBytes + rowBytes > maxStoredBytes) {
              hasEarlier = true;
              stop = true;
              break;
            }
            pendingTurn.add(row);
            pendingBytes += rowBytes;
            if (isUser) {
              selected.addAll(pendingTurn);
              storedBytes += pendingBytes;
              pendingTurn.clear();
              pendingBytes = 0;
            }
          }
        }
        if (metadata.length < 64) break;
      }
      // 已到数据库起点的 assistant-only 旧前缀原样保留；限额处半轮整体省略。
      if (!hasEarlier && pendingTurn.isNotEmpty) {
        selected.addAll(pendingTurn);
        storedBytes += pendingBytes;
      }
      if (selected.isEmpty) {
        return const MessageContextCandidates(
          messages: [],
          hasEarlierMessages: false,
          storedBytes: 0,
          exceededStoredByteBudget: false,
        );
      }
      final rows = await txn.query(
        tableName,
        // blocks 由 getBlocksByCreatedAt 恢复，这里不重复跨进程传输。
        columns: const [
          'id',
          'cid',
          'content',
          'createdAt',
          'ownerName',
          'ownerType',
          'avatar',
          'images',
        ],
        where: 'cid = ? and id >= ? and id <= ?',
        whereArgs: [cid, selected.last['id'], selected.first['id']],
        orderBy: 'id asc',
      );
      return MessageContextCandidates(
        messages: List.unmodifiable(rows.map(MessageModel.fromJson)),
        hasEarlierMessages: hasEarlier,
        storedBytes: storedBytes,
        exceededStoredByteBudget: storedBytes > maxStoredBytes,
      );
    });
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
    final map = <String, String>{};
    // Android 旧 SQLite 的绑定参数上限可能为 999，候选历史批量恢复要分段。
    for (var start = 0; start < ids.length; start += 400) {
      final batch = ids.skip(start).take(400).toList();
      final placeholders = List.filled(batch.length, '?').join(',');
      final rows = await storage.db.query(
        tableName,
        columns: ['createdAt', 'blocks'],
        where: 'cid = ? and createdAt in ($placeholders)',
        whereArgs: [cid, ...batch],
      );
      for (final r in rows) {
        final blocks = r['blocks'] as String?;
        final createdAt = r['createdAt'] as int?;
        if (blocks != null && blocks.isNotEmpty && createdAt != null) {
          map[chatMessageKey(createdAt)] = blocks;
        }
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
