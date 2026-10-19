import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/schema_guard.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/usage_record.dart';
import 'package:sqflite/sqflite.dart';

abstract class IConversationGeneration {
  Future<ConversationGenerationRecord?> read(String id);
  Future<void> recoverInterrupted(ConversationGenerationScope scope);
}

/// 普通生成的派生 journal；恢复/迁移不赋予执行授权。
class ConversationGenerationDao implements IConversationGeneration, ITable {
  final HiDBManager storage;
  @override
  String tableName = 'tb_conversation_generation';
  ConversationGenerationDao._(this.storage);
  static Future<ConversationGenerationDao> create(HiDBManager storage) async {
    await MessageDao.create(storage, cid: 0);
    await UsageDao.create(storage);
    await storage.db
        .execute('''create table if not exists tb_conversation_generation (
      runId text primary key, cid integer not null, conversationRowId integer not null,
      assistantId integer, sourceId text not null, sourceHash text not null,
      sourceRowHash text, userRowId integer, receiverId text not null unique,
      receiverAt integer not null, receiverRowId integer, usageRowId integer,
      revision integer not null, state text not null, reason text not null default '',
      attempts integer not null default 0, finalHash text, updatedAt integer not null,
      retryReplyRowId integer, retryReplyHash text, retryReplyRemoved integer not null default 0)''');
    // OHOS 的 SQLite 异常只返回通用错误码，不能靠英文错误消息判断列已存在。
    await SchemaGuard.ensureColumns(storage.db,
        table: 'tb_conversation_generation',
        columns: const {
          'retryReplyRowId': 'integer',
          'retryReplyHash': 'text',
          'retryReplyRemoved': 'integer not null default 0',
        });
    await storage.db
        .execute('create index if not exists conversation_generation_cid_idx '
            'on tb_conversation_generation(cid, updatedAt desc)');
    await storage.db.execute(
        "create unique index if not exists conversation_generation_active_idx "
        "on tb_conversation_generation(cid) where state in "
        "('preparing','generating','awaitingConfirmation','persisting','persistenceFailed')");
    return ConversationGenerationDao._(storage);
  }

  @override
  Future<ConversationGenerationRecord?> read(String id) async {
    final rows =
        await storage.db.query(tableName, where: 'runId=?', whereArgs: [id]);
    return rows.isEmpty
        ? null
        : ConversationGenerationRecord.fromRow(rows.single);
  }

  Future<void> _validate(Transaction tx, ConversationGenerationScope scope,
      Map<String, Object?> row) async {
    scope.verify();
    final conversations = await tx.query('tb_conversation_list',
        columns: ['id', 'assistantId'],
        where: 'cid=?',
        whereArgs: [row['cid']]);
    if (conversations.length != 1 ||
        conversations.single['id'] != row['conversationRowId'] ||
        conversations.single['assistantId'] != row['assistantId']) {
      throw const ConversationGenerationStale('原会话已删除或助手绑定已变化');
    }
    if (row['userRowId'] != null) {
      final users = await tx.query('tb_messages',
          where: 'id=? and cid=?', whereArgs: [row['userRowId'], row['cid']]);
      if (users.length != 1 ||
          users.single['ownerType'] != OwnerType.sender.toString() ||
          users.single['memorySourceId'] != row['sourceId'] ||
          generationSourceRowHash(users.single) != row['sourceRowHash']) {
        throw const ConversationGenerationStale('原提问或附件已变化');
      }
    }
    scope.verify();
  }

  Future<T> _transaction<T>(ConversationGenerationScope scope,
          Future<T> Function(Transaction) action,
          {void Function()? onCommitted}) =>
      scope.stable(() async {
        final result = await storage.db.transaction((tx) async {
          scope.verify();
          final result = await action(tx);
          scope.verify();
          return result;
        });
        onCommitted?.call();
        return result;
      });
  Future<Map<String, Object?>> _current(Transaction tx,
      ConversationGenerationScope scope, ConversationGenerationRecord expected,
      {bool terminal = false}) async {
    final rows = await tx
        .query(tableName, where: 'runId=?', whereArgs: [expected.runId]);
    if (rows.length != 1) {
      throw const ConversationGenerationStale('生成记录已被清理');
    }
    final row = rows.single;
    await _validate(tx, scope, row);
    if (row['revision'] != expected.revision ||
        (!terminal && ConversationGenerationRecord.fromRow(row).terminal)) {
      throw const ConversationGenerationStale('生成已终结或版本已变化');
    }
    return row;
  }

  Future<ConversationGenerationRecord> _update(Transaction tx,
      Map<String, Object?> row, Map<String, Object?> changes) async {
    final revision = row['revision'] as int;
    final next = <String, Object?>{
      ...changes,
      'revision': revision + 1,
      'updatedAt': DateTime.now().millisecondsSinceEpoch
    };
    final affected = await tx.update(tableName, next,
        where: 'runId=? and revision=?', whereArgs: [row['runId'], revision]);
    if (affected != 1) {
      throw const ConversationGenerationStale();
    }
    return ConversationGenerationRecord.fromRow({...row, ...next});
  }

  Future<ConversationGenerationRecord> begin(
    ConversationGenerationScope scope, {
    required String runId,
    required int cid,
    required int? conversationRowId,
    Map<String, Object?>? newConversation,
    required int? assistantId,
    required String sourceId,
    required String sourceHash,
    required String receiverId,
    required int receiverAt,
    int? existingUserRowId,
    String? existingSourceRowHash,
    int? retryReplyRowId,
    String? retryReplyHash,
    ConversationGenerationRecord? abandonedRun,
  }) =>
      _transaction(scope, (tx) async {
        var boundConversationId = conversationRowId;
        if (boundConversationId == null) {
          if (newConversation == null ||
              newConversation['id'] != null ||
              newConversation['cid'] != cid ||
              newConversation['assistantId'] != assistantId ||
              existingUserRowId != null ||
              (await tx.query('tb_conversation_list',
                      columns: ['id'], where: 'cid=?', whereArgs: [cid]))
                  .isNotEmpty ||
              (await tx.query('tb_messages',
                      columns: ['id'],
                      where: 'cid=?',
                      whereArgs: [cid],
                      limit: 1))
                  .isNotEmpty) {
            throw const ConversationGenerationStale('新会话标识已占用，请重新建立会话');
          }
          final data = Map<String, Object?>.from(newConversation)..remove('id');
          boundConversationId = await tx.insert('tb_conversation_list', data);
        }
        final row = <String, Object?>{
          'runId': runId,
          'cid': cid,
          'conversationRowId': boundConversationId,
          'assistantId': assistantId,
          'sourceId': sourceId,
          'sourceHash': sourceHash,
          'receiverId': receiverId,
          'receiverAt': receiverAt,
          'revision': 0,
          'state': 'preparing',
          'attempts': 0,
          'updatedAt': DateTime.now().millisecondsSinceEpoch
        };
        if (existingUserRowId != null) {
          final users = await tx.query('tb_messages',
              where: 'id=? and cid=?', whereArgs: [existingUserRowId, cid]);
          if (existingSourceRowHash == null ||
              users.length != 1 ||
              (users.single['memorySourceId'] != null &&
                  users.single['memorySourceId'] != sourceId) ||
              generationSourceRowHash(users.single) != existingSourceRowHash ||
              generationContentHash(users.single['content'] as String? ?? '') !=
                  sourceHash) {
            throw const ConversationGenerationStale('重试来源已变化');
          }
          if (users.single['ownerType'] != OwnerType.sender.toString()) {
            throw const ConversationGenerationStale('重试仅适用于原本人消息');
          }
          if (users.single['memorySourceId'] == null) {
            await tx.update('tb_messages', {'memorySourceId': sourceId},
                where: 'id=? and cid=?', whereArgs: [existingUserRowId, cid]);
          }
          final boundUser = (await tx.query('tb_messages',
                  where: 'id=? and cid=?', whereArgs: [existingUserRowId, cid]))
              .single;
          row['userRowId'] = existingUserRowId;
          row['sourceRowHash'] = generationSourceRowHash(boundUser);
        }
        if (retryReplyRowId != null) {
          if (existingUserRowId == null || retryReplyHash == null) {
            throw const ConversationGenerationStale('重生成回复身份缺失');
          }
          final replies = await tx.query('tb_messages',
              where: 'id=? and cid=?', whereArgs: [retryReplyRowId, cid]);
          if (replies.length != 1 ||
              replies.single['ownerType'] != OwnerType.receiver.toString() ||
              generationSourceRowHash(replies.single) != retryReplyHash) {
            throw const ConversationGenerationStale('原回复已变化，未开始重生成');
          }
          row['retryReplyRowId'] = retryReplyRowId;
          row['retryReplyHash'] = retryReplyHash;
        }
        await _validate(tx, scope, row);
        if (abandonedRun != null) {
          // 只由服务明确退役的原运行提供；当前身份只收尾 journal，绝不写旧回复。
          if (abandonedRun.cid != cid ||
              abandonedRun.conversationRowId != boundConversationId) {
            throw const ConversationRetirementStale();
          }
          final affected = await tx.update(
              tableName,
              {
                'state': 'interrupted',
                'reason': '旧执行身份已撤销，未保存结果未重放',
                'revision': abandonedRun.revision + 1,
              },
              where: 'runId=? and cid=? and revision=? and conversationRowId=? '
                  'and sourceId=? and receiverId=? and state not in (\'complete\',\'interrupted\',\'failed\')',
              whereArgs: [
                abandonedRun.runId,
                cid,
                abandonedRun.revision,
                abandonedRun.conversationRowId,
                abandonedRun.sourceId,
                abandonedRun.receiverId
              ]);
          if (affected != 1) throw const ConversationRetirementStale();
        }
        await tx.insert(tableName, row); // 不能 replace 旧 run 或其它运行。
        return ConversationGenerationRecord.fromRow(row);
      });

  Future<ConversationGenerationRecord> acceptUser(
      ConversationGenerationScope scope,
      ConversationGenerationRecord expected,
      MessageModel user,
      {String? blocksJson,
      void Function()? onCommitted,
      void Function(Map<String, Object?> row)? onSourceCommitted}) {
    Map<String, Object?>? source;
    return _transaction(scope, (tx) async {
      final row = await _current(tx, scope, expected);
      if (row['userRowId'] != null) {
        source = Map.unmodifiable((await tx.query('tb_messages',
                where: 'id=? and cid=?',
                whereArgs: [row['userRowId'], row['cid']]))
            .single);
      }
      if (row['userRowId'] != null) {
        if (row['retryReplyRowId'] != null && row['retryReplyRemoved'] != 1) {
          final replies = await tx.query('tb_messages',
              where: 'id=? and cid=?',
              whereArgs: [row['retryReplyRowId'], row['cid']]);
          if (replies.length != 1 ||
              generationSourceRowHash(replies.single) !=
                  row['retryReplyHash']) {
            throw const ConversationGenerationStale('附件准备期间原回复已变化，已保留原消息');
          }
          await tx.delete('tb_messages',
              where: 'id=? and cid=?',
              whereArgs: [row['retryReplyRowId'], row['cid']]);
          // 原回复与索引摘要同事务变化；停止/重启不会留下一条不存在的回复。
          final count = (await tx.rawQuery(
                  'select count(*) as n from tb_messages where cid=?',
                  [row['cid']]))
              .single['n'];
          final remaining = await tx.query('tb_messages',
              columns: ['content'],
              where: 'cid=?',
              whereArgs: [row['cid']],
              orderBy: 'createdAt desc, id desc',
              limit: 1);
          final content = remaining.isEmpty
              ? ''
              : (remaining.single['content'] as String? ?? '');
          final changed = await tx.update(
              'tb_conversation_list',
              {
                'messageCount': count,
                'lastMessage': remaining.isNotEmpty && content.trim().isEmpty
                    ? '附件消息'
                    : content
              },
              where: 'id=? and cid=?',
              whereArgs: [row['conversationRowId'], row['cid']]);
          if (changed != 1) throw const ConversationGenerationStale();
          return _update(tx, row, {'retryReplyRemoved': 1});
        }
        return ConversationGenerationRecord.fromRow(row);
      }
      if (user.ownerType != OwnerType.sender ||
          generationContentHash(user.content) != row['sourceHash']) {
        throw const ConversationGenerationStale();
      }
      final conflicts = await tx.query('tb_messages',
          columns: ['id'],
          where: 'cid=? and createdAt=?',
          whereArgs: [row['cid'], user.createdAt]);
      if (conflicts.isNotEmpty) {
        throw const ConversationGenerationStale('消息时间身份已被占用');
      }
      final data = <String, Object?>{
        ...user.toJson(),
        'cid': row['cid'],
        'memorySourceId': row['sourceId'],
        if (blocksJson != null) 'blocks': blocksJson
      };
      data.remove('id');
      final id = await tx.insert('tb_messages', data);
      final saved = (await tx.query('tb_messages',
              where: 'id=? and cid=?', whereArgs: [id, row['cid']]))
          .single;
      source = Map.unmodifiable(saved);
      final counts = await tx.rawQuery(
          'select count(*) as n from tb_messages where cid=?', [row['cid']]);
      final summary = user.content.trim().isEmpty ? '附件消息' : user.content;
      await tx.rawUpdate(
          "update tb_conversation_list set title=case when title is null or trim(title)='' then ? else title end, "
          'messageCount=?, lastMessage=case when coalesce(updateAt,0)<=? then ? else lastMessage end, '
          'updateAt=max(coalesce(updateAt,0),?) where id=? and cid=?',
          [
            summary,
            counts.single['n'],
            user.createdAt,
            summary,
            user.createdAt,
            row['conversationRowId'],
            row['cid']
          ]);
      return _update(tx, row, {
        'userRowId': id,
        'sourceRowHash': generationSourceRowHash(saved),
        'state': 'generating'
      });
    }, onCommitted: () {
      onCommitted?.call();
      if (source != null) onSourceCommitted?.call(source!);
    });
  }

  /// 删除后的列表只同步摘要字段，不以页面旧对象覆盖标题/置顶/模型配置。
  Future<void> refreshSummary(
          ConversationGenerationScope scope, int cid, int rowId) =>
      _transaction(scope, (tx) async {
        final rows = await tx.query('tb_messages',
            columns: ['content'],
            where: 'cid=?',
            whereArgs: [cid],
            orderBy: 'createdAt desc, id desc',
            limit: 1);
        final content =
            rows.isEmpty ? '' : (rows.first['content'] as String? ?? '');
        final changed = await tx.update(
            'tb_conversation_list',
            {
              'messageCount': (await tx.rawQuery(
                      'select count(*) as n from tb_messages where cid=?',
                      [cid]))
                  .single['n'],
              'lastMessage':
                  rows.isNotEmpty && content.trim().isEmpty ? '附件消息' : content,
            },
            where: 'id=? and cid=?',
            whereArgs: [rowId, cid]);
        if (changed != 1) throw const ConversationGenerationStale();
      });

  Future<void> validateSavedSource(
      Transaction tx,
      ConversationGenerationScope scope,
      ConversationGenerationRecord expected) async {
    await _current(tx, scope, expected, terminal: true);
  }

  /// 工具的最后写点与原 journal/source 的 CAS 位于同一短事务。
  Future<T> commitTool<T>(
          ConversationGenerationScope scope,
          ConversationGenerationRecord expected,
          Future<T> Function(Transaction tx) action) =>
      _transaction(scope, (tx) async {
        await _current(tx, scope, expected);
        final value = await action(tx);
        await _current(tx, scope, expected);
        return value;
      });

  Future<ConversationGenerationRecord> stage(
          ConversationGenerationScope scope,
          ConversationGenerationRecord expected,
          ConversationGenerationStage stage,
          {String reason = ''}) =>
      _transaction(scope, (tx) async {
        final row = await _current(tx, scope, expected);
        return _update(tx, row, {'state': stage.name, 'reason': reason});
      });
  Future<ConversationGenerationRecord> reserveAttempt(
          ConversationGenerationScope scope,
          ConversationGenerationRecord expected) =>
      _transaction(scope, (tx) async {
        final row = await _current(tx, scope, expected);
        if (row['userRowId'] == null) {
          throw const ConversationGenerationStale('提问尚未保存');
        }
        return _update(tx, row,
            {'state': 'generating', 'attempts': (row['attempts'] as int) + 1});
      });

  /// 回复、块、用量和终态一起提交；失败只重试这个事务，不重新请求模型。
  Future<ConversationGenerationRecord> saveReply(
          ConversationGenerationScope scope,
          ConversationGenerationRecord expected,
          {required String content,
          required String blocksJson,
          required ConversationGenerationStage state,
          String? ownerName,
          String? avatar,
          String reason = '',
          UsageRecord? usage}) =>
      _transaction(scope, (tx) async {
        final rows = await tx
            .query(tableName, where: 'runId=?', whereArgs: [expected.runId]);
        if (rows.length != 1) {
          throw const ConversationGenerationStale();
        }
        final row = rows.single;
        await _validate(tx, scope, row);
        final finalHash = generationContentHash(
            jsonEncode([content, blocksJson, usage?.toJson(), state.name]));
        final current = ConversationGenerationRecord.fromRow(row);
        if (current.terminal) {
          if (row['finalHash'] != finalHash) {
            throw const ConversationGenerationStale('不能覆盖已终结回复');
          }
          return current; // 重复 onDone/订阅/落盘重试不新增行或用量。
        }
        if (row['revision'] != expected.revision) {
          throw const ConversationGenerationStale();
        }
        if (row['userRowId'] == null) {
          if (state == ConversationGenerationStage.complete) {
            throw const ConversationGenerationStale();
          }
          return _update(tx, row,
              {'state': state.name, 'reason': reason, 'finalHash': finalHash});
        }
        final message = <String, Object?>{
          'cid': row['cid'],
          'createdAt': row['receiverAt'],
          'memorySourceId': row['receiverId'],
          'ownerType': OwnerType.receiver.toString(),
          'ownerName': ownerName,
          'avatar': avatar,
          'content': content,
          'blocks': blocksJson
        };
        var replyId = row['receiverRowId'] as int?;
        if (replyId == null) {
          final conflicts = await tx.query('tb_messages',
              columns: ['id'],
              where: 'cid=? and createdAt=?',
              whereArgs: [row['cid'], row['receiverAt']]);
          if (conflicts.isNotEmpty) {
            throw const ConversationGenerationStale('回复身份已被占用');
          }
          replyId = await tx.insert('tb_messages', message);
        } else {
          final updated = await tx.update(
              'tb_messages', {'content': content, 'blocks': blocksJson},
              where: 'id=? and cid=? and memorySourceId=? and ownerType=?',
              whereArgs: [
                replyId,
                row['cid'],
                row['receiverId'],
                OwnerType.receiver.toString()
              ]);
          if (updated != 1) {
            throw const ConversationGenerationStale('原回复已删除');
          }
        }
        var usageId = row['usageRowId'] as int?;
        if (usage != null &&
            usageId == null &&
            state != ConversationGenerationStage.generating) {
          if (usage.cid != row['cid']) {
            throw const ConversationGenerationStale();
          }
          final values = usage.toJson()..remove('id');
          usageId = await tx.insert('tb_usage', values);
        }
        final counts = await tx.rawQuery(
            'select count(*) as n from tb_messages where cid=?', [row['cid']]);
        // 不把旧 ConversationModel 的模型/头像/角色设置写回。
        await tx.rawUpdate(
            'update tb_conversation_list set messageCount=?, '
            'lastMessage=case when coalesce(updateAt,0)<=? then ? else lastMessage end, '
            'updateAt=max(coalesce(updateAt,0),?) where id=? and cid=?',
            [
              counts.single['n'],
              row['receiverAt'],
              content,
              row['receiverAt'],
              row['conversationRowId'],
              row['cid']
            ]);
        return _update(tx, row, {
          'state': state.name,
          'reason': reason,
          'receiverRowId': replyId,
          'usageRowId': usageId,
          if (state != ConversationGenerationStage.generating)
            'finalHash': finalHash
        });
      });

  /// 已确认来源失效时只关闭原 journal，不写消息、不创建行或认领新会话。
  Future<ConversationGenerationRecord> invalidate(
          ConversationGenerationScope scope,
          ConversationGenerationRecord expected) =>
      _transaction(scope, (tx) async {
        final rows = await tx.query(tableName,
            where:
                'runId=? and cid=? and revision=? and sourceId=? and receiverId=? '
                'and conversationRowId=?',
            whereArgs: [
              expected.runId,
              expected.cid,
              expected.revision,
              expected.sourceId,
              expected.receiverId,
              expected.conversationRowId
            ]);
        if (rows.length != 1) throw const ConversationRetirementStale();
        return _update(tx, rows.single, {
          'state': 'interrupted',
          'reason': '原来源已变化，旧结果未写回',
        });
      });

  /// 只能由应用冷启调用一次；重接页面不调用，不发出任何请求。
  @override
  Future<void> recoverInterrupted(ConversationGenerationScope scope) =>
      _transaction(scope, (tx) async {
        await tx.rawUpdate("update $tableName set state='interrupted', reason="
            "'进程已结束，结果可能不完整；未自动重新请求', revision=revision+1 "
            "where state not in ('complete','interrupted','failed')");
      });
}
