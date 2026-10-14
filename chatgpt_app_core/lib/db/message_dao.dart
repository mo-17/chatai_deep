import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/domain/interactive_card.dart';
import 'package:chatgpt_app_core/chat/application/chat_block_store.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';

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

enum ChecklistWriteStatus { saved, stale, notFound, failed }

class ChecklistWriteResult {
  final ChecklistWriteStatus status;
  final ChecklistLocalState? state;
  const ChecklistWriteResult(this.status, [this.state]);
}

/// 请求历史的有限候选集，与聊天列表的分页展示相互独立。
class MessageContextCandidates {
  final List<MessageModel> messages;
  final List<Map<String, Object?>> rawRows;
  final bool hasEarlierMessages;
  final int storedBytes;
  final bool exceededStoredByteBudget;

  const MessageContextCandidates({
    required this.messages,
    this.rawRows = const [],
    required this.hasEarlierMessages,
    required this.storedBytes,
    required this.exceededStoredByteBudget,
  });
}

/// UI 的已加载范围独立于模型候选预算，使用行游标避免新增/删除造成 offset 漂移。
class MessageDisplayWindow {
  final List<Map<String, Object?>> rows;
  final bool hasEarlierMessages;
  final int? oldestRowId;
  const MessageDisplayWindow(
      this.rows, this.hasEarlierMessages, this.oldestRowId);
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
        'memorySourceId': 'text',
      },
    );
    return MessageDao._(storage, cid: cid);
  }

  @override
  Future<int> deleteMessage(int id) =>
      ConversationExecutionRegistry.instance.maintainStorage(
          storage.db,
          () => storage.db.delete(tableName,
              where: 'id = ? and cid = ?', whereArgs: [id, cid]),
          cid: cid,
          reason: '对话消息正在删除，请求已停止');

  /// 删除到事务结束期间封住本 cid 新票据；其它会话继续执行。
  Future<int> deleteMessageByCreatedAt(int createdAt) =>
      ConversationExecutionRegistry.instance.maintainStorage(
          storage.db,
          () => storage.db.delete(tableName,
              where: 'cid = ? and createdAt = ?', whereArgs: [cid, createdAt]),
          cid: cid,
          reason: '对话消息正在删除，请求已停止');

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

  Future<MessageDisplayWindow> loadDisplayWindow(
      {int? beforeId, int? oldestLoadedId, int pageSize = 15}) async {
    if (pageSize <= 0 || (beforeId != null && oldestLoadedId != null)) {
      throw ArgumentError('历史窗口参数无效');
    }
    return storage.db.transaction((tx) async {
      final rows = await tx.query(tableName,
          where:
              'cid=?${beforeId != null ? ' and id<?' : oldestLoadedId != null ? ' and id>=?' : ''}',
          whereArgs: [
            cid,
            if (beforeId != null) beforeId,
            if (oldestLoadedId != null) oldestLoadedId
          ],
          orderBy: 'id desc',
          limit: oldestLoadedId == null ? pageSize : null);
      final boundary =
          rows.isEmpty ? (oldestLoadedId ?? beforeId) : rows.last['id'] as int;
      final earlier = boundary == null
          ? const <Map<String, Object?>>[]
          : await tx.query(tableName,
              columns: const ['id'],
              where: 'cid=? and id<?',
              whereArgs: [cid, boundary],
              limit: 1);
      return MessageDisplayWindow(
          List.unmodifiable(
              rows.reversed.map((r) => Map<String, Object?>.unmodifiable(r))),
          earlier.isNotEmpty,
          boundary);
    });
  }

  /// 先在 SQLite 内测量正文/图片/块的字节数，避免一次反序列化海量 Base64。
  /// 候选按连续的最新范围加载，触及边界时尽量从 user 开始保留完整轮次。
  /// 最新完整 user 轮即使独自超出字节预算仍保留，之后不再累积更早轮次。
  Future<MessageContextCandidates> loadContextCandidates({
    int maxMessages = 1000,
    bool includeStoredBlocks = false,
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
        columns: includeStoredBlocks
            ? null
            : const [
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
        rawRows: includeStoredBlocks
            ? List.unmodifiable(
                rows.map((r) => Map<String, Object?>.unmodifiable(r)))
            : const [],
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
    data['memorySourceId'] = generateUuidV4();
    storage.db.insert(tableName, data);
  }

  /// 保存一条带块列表的消息（assistant 块化消息用）。
  /// [blocksJson] 为 `MessageBlock.encodeList(...)` 的结果。返回新行 id。
  Future<int> saveMessageWithBlocks(MessageModel model, {String? blocksJson}) {
    final data = model.toJson();
    data['cid'] = cid;
    data['memorySourceId'] = generateUuidV4();
    if (blocksJson != null && blocksJson.isNotEmpty) {
      data['blocks'] = blocksJson;
    }
    return storage.db.insert(tableName, data);
  }

  /// 只合并一张卡的本地状态；重新验证落盘原文，不复活已删除的消息。
  /// 原始 JSON 的其它块和未知字段必须完整保留。
  Future<ChecklistWriteResult> setChecklistItemChecked({
    required int createdAt,
    required String blockId,
    required String expectedContent,
    required String cardKey,
    required String itemId,
    required bool checked,
    required int expectedRowId,
  }) async {
    try {
      return await storage.db.transaction((txn) async {
        final metadata = await txn.rawQuery(
            'select id, ownerType, length(cast(blocks as blob)) as blockBytes '
            'from $tableName where cid = ? and createdAt = ?',
            [cid, createdAt]);
        if (metadata.isEmpty) {
          return const ChecklistWriteResult(ChecklistWriteStatus.notFound);
        }
        if (metadata.length != 1 ||
            metadata.single['id'] != expectedRowId ||
            metadata.single['ownerType'] != OwnerType.receiver.toString() ||
            metadata.single['blockBytes'] is! int ||
            (metadata.single['blockBytes'] as int) > 8 * 1024 * 1024) {
          return const ChecklistWriteResult(ChecklistWriteStatus.stale);
        }
        final id = metadata.single['id'];
        final rows = await txn.query(tableName,
            columns: ['blocks'],
            where: 'id = ? and cid = ?',
            whereArgs: [id, cid]);
        final original = rows.single['blocks'] as String;
        final raw = jsonDecode(original);
        if (raw is! List) {
          return const ChecklistWriteResult(ChecklistWriteStatus.stale);
        }
        final targets =
            raw.whereType<Map>().where((b) => b['id'] == blockId).toList();
        if (targets.length != 1 ||
            raw.whereType<Map>().any((b) =>
                b['type'] == 'error' ||
                const ['pending', 'processing', 'streaming', 'paused', 'error']
                    .contains(b['status']))) {
          return const ChecklistWriteResult(ChecklistWriteStatus.stale);
        }
        final target = targets.single;
        if (target['type'] != 'mainText' ||
            target['status'] != 'success' ||
            target['content'] != expectedContent ||
            target['messageId'] != chatMessageKey(createdAt)) {
          return const ChecklistWriteResult(ChecklistWriteStatus.stale);
        }
        // 整条消息共享四张卡额度，避免分块绕过预算。
        if (!InteractiveCardParser.fitsMessageBudget(raw
            .whereType<Map>()
            .where((b) => b['type'] == 'mainText' && b['content'] is String)
            .map((b) => b['content'] as String))) {
          return const ChecklistWriteResult(ChecklistWriteStatus.stale);
        }
        var remaining = InteractiveCardParser.maxCards;
        CardProjection? candidate;
        for (final block in raw.whereType<Map>()) {
          if (block['type'] != 'mainText' || block['content'] is! String) {
            continue;
          }
          final projections = InteractiveCardParser.parse(
                  block['content'] as String,
                  cardLimit: remaining)
              .whereType<CardProjection>()
              .toList();
          remaining -= projections.length;
          if (identical(block, target)) {
            candidate = projections.where((p) => p.key == cardKey).firstOrNull;
          }
        }
        final card = candidate?.card;
        if (card is! ChecklistCard || !card.items.any((i) => i.id == itemId)) {
          return const ChecklistWriteResult(ChecklistWriteStatus.stale);
        }
        final states =
            decodeLocalCardStates(target['localCardStates'], expectedContent);
        final ids = {...?states[cardKey]?.checkedItemIds};
        checked ? ids.add(itemId) : ids.remove(itemId);
        final state = ChecklistLocalState(ids);
        // 只替换目标字段，绝不通过容错块解码器重编码整条消息。
        final previous = target['localCardStates'];
        target['localCardStates'] = {
          if (previous is Map) ...previous,
          cardKey: state.toJson(),
        };
        final count = await txn.update(tableName, {'blocks': jsonEncode(raw)},
            where: 'id = ? and cid = ? and createdAt = ? and blocks = ?',
            whereArgs: [id, cid, createdAt, original]);
        return count == 1
            ? ChecklistWriteResult(ChecklistWriteStatus.saved, state)
            : const ChecklistWriteResult(ChecklistWriteStatus.stale);
      });
    } catch (_) {
      return const ChecklistWriteResult(ChecklistWriteStatus.failed);
    }
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
