import 'dart:async';
import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/table_name.dart';
import 'package:chatgpt_app_core/util/app_events.dart';
import 'package:chatgpt_app_core/util/uuid_v4.dart';
import 'package:sqflite/sqflite.dart';

class CloudSourceSnapshot {
  final String bindingId, task;
  final CloudLocalSource source;
  final List<CloudTextSnapshot> inputs;
  const CloudSourceSnapshot(
      this.bindingId, this.task, this.source, this.inputs);
}

class CloudLocalReceipt {
  final String origin, key, payloadHash, bindingId, status;
  final int ownerId;
  final String? taskId, publicationId;
  final CloudLocalSource source;
  const CloudLocalReceipt(
      this.origin,
      this.ownerId,
      this.key,
      this.payloadHash,
      this.bindingId,
      this.status,
      this.source,
      this.taskId,
      this.publicationId);
  factory CloudLocalReceipt.fromRow(Map<String, Object?> r) =>
      CloudLocalReceipt(
          r['origin'] as String,
          r['ownerId'] as int,
          r['idempotencyKey'] as String,
          r['payloadHash'] as String,
          r['bindingId'] as String,
          r['status'] as String,
          CloudLocalSource.fromJson(jsonDecode(r['sourceJson'] as String)),
          r['taskId'] as String?,
          r['publicationId'] as String?);
}

class CloudSubmissionRegistration {
  final CloudLocalReceipt receipt;
  final bool shouldSend;
  const CloudSubmissionRegistration(this.receipt, this.shouldSend);
}

class CloudPublicationReceipt {
  final int messageId;
  final bool deleted;
  const CloudPublicationReceipt(this.messageId, this.deleted);
}

/// 纯本机 sidecar；不加入备份/同步/游客迁移，也不伪造本机 Agent 完成状态。
class CloudWorkflowDao implements ITable {
  final HiDBManager storage;
  final String accountHash;
  final void Function()? verifySession;
  @override
  String tableName = 'tb_cloud_receipts';
  CloudWorkflowDao._(this.storage, this.accountHash, this.verifySession);
  CloudWorkflowDao withSession(void Function() guard) =>
      CloudWorkflowDao._(storage, accountHash, () {
        verifySession?.call();
        guard();
      });
  static Future<CloudWorkflowDao> create(HiDBManager storage,
      {required String accountHash, void Function()? verifySession}) async {
    verifySession?.call();
    await ConversationListDao.create(storage);
    verifySession?.call();
    await MessageDao.create(storage, cid: 1);
    verifySession?.call();
    await AgentWorkspaceDao.create(storage, cid: 1);
    verifySession?.call();
    await storage.db.transaction((tx) async {
      await tx.execute('''CREATE TABLE IF NOT EXISTS tb_cloud_sources(
        bindingId TEXT PRIMARY KEY,cid INTEGER NOT NULL,conversationRowId INTEGER NOT NULL,
        sourceRowId INTEGER NOT NULL,messageUuid TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1,
        valid INTEGER NOT NULL DEFAULT 1,sourceHash TEXT NOT NULL,sourceRowHash TEXT NOT NULL,
        conversationHash TEXT NOT NULL)''');
      await tx.execute('''CREATE TABLE IF NOT EXISTS tb_cloud_input_bindings(
        bindingId TEXT NOT NULL,fileId INTEGER NOT NULL,revision INTEGER NOT NULL,contentHash TEXT NOT NULL,
        PRIMARY KEY(bindingId,fileId))''');
      await tx.execute('''CREATE TABLE IF NOT EXISTS tb_cloud_receipts(
        origin TEXT NOT NULL,ownerId INTEGER NOT NULL,idempotencyKey TEXT NOT NULL,payloadHash TEXT NOT NULL,
        bindingId TEXT NOT NULL,sourceJson TEXT NOT NULL,status TEXT NOT NULL,
        taskId TEXT,publicationId TEXT,serverRevision INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(origin,ownerId,idempotencyKey))''');
      await tx.execute('''CREATE TABLE IF NOT EXISTS tb_cloud_publications(
        origin TEXT NOT NULL,ownerId INTEGER NOT NULL,taskId TEXT NOT NULL,publicationId TEXT NOT NULL,
        resultId TEXT NOT NULL,resultVersion INTEGER NOT NULL,contentHash TEXT NOT NULL,messageId INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(origin,ownerId,taskId,publicationId))''');
      await tx.execute('''CREATE TABLE IF NOT EXISTS tb_cloud_stop_intents(
        origin TEXT NOT NULL,ownerId INTEGER NOT NULL,taskId TEXT NOT NULL,operationId TEXT NOT NULL,
        expectedRevision INTEGER NOT NULL,status TEXT NOT NULL,
        PRIMARY KEY(origin,ownerId,taskId))''');
      // 触发器只改已登记的cloud sidecar。ABA或非当前页面写入也会留下单调证据。
      for (final op in ['INSERT', 'UPDATE', 'DELETE']) {
        final cid = op == 'DELETE' ? 'OLD.cid' : 'NEW.cid';
        final extra = op == 'UPDATE' ? ' OR cid=OLD.cid' : '';
        await tx.execute(
            '''CREATE TRIGGER IF NOT EXISTS cloud_message_${op.toLowerCase()}
          AFTER $op ON tb_messages BEGIN UPDATE tb_cloud_sources
          SET valid=0,revision=revision+1 WHERE cid=$cid$extra; END''');
        await tx.execute(
            '''CREATE TRIGGER IF NOT EXISTS cloud_conversation_${op.toLowerCase()}
          AFTER $op ON tb_conversation_list BEGIN UPDATE tb_cloud_sources
          SET valid=0,revision=revision+1 WHERE cid=$cid$extra; END''');
      }
      await tx.execute('''CREATE TRIGGER IF NOT EXISTS cloud_publication_delete
        AFTER DELETE ON tb_messages BEGIN UPDATE tb_cloud_publications SET deleted=1 WHERE messageId=OLD.id; END''');
      for (final op in ['UPDATE', 'DELETE']) {
        await tx.execute(
            '''CREATE TRIGGER IF NOT EXISTS cloud_input_${op.toLowerCase()}
          AFTER $op ON tb_agent_workspace_files BEGIN UPDATE tb_cloud_sources SET valid=0,revision=revision+1
          WHERE bindingId IN (SELECT bindingId FROM tb_cloud_input_bindings WHERE fileId=OLD.id); END''');
        await tx.execute(
            '''CREATE TRIGGER IF NOT EXISTS cloud_input_content_${op.toLowerCase()}
          AFTER $op ON tb_agent_workspace_revisions BEGIN UPDATE tb_cloud_sources SET valid=0,revision=revision+1
          WHERE bindingId IN (SELECT bindingId FROM tb_cloud_input_bindings WHERE fileId=OLD.fileId AND revision=OLD.revision); END''');
      }
    });
    verifySession?.call();
    return CloudWorkflowDao._(storage, accountHash, verifySession);
  }

  void _check(AgentWorkflowScope scope) {
    scope.verify();
    verifySession?.call();
    if (scope.accountHash != accountHash) {
      throw StateError('云任务账号已变化');
    }
  }

  Future<T> _transaction<T>(
          AgentWorkflowScope scope, Future<T> Function(Transaction) action) =>
      scope.stable(() async {
        _check(scope);
        return storage.db.transaction((tx) async {
          _check(scope);
          final r = await action(tx);
          _check(scope);
          return r;
        });
      });

  Future<CloudSourceSnapshot> capture(AgentWorkflowScope scope,
          {required int cid,
          required int messageId,
          List<int> inputIds = const []}) =>
      _transaction(scope, (tx) async {
        if (inputIds.length > 4 || inputIds.toSet().length != inputIds.length) {
          throw const FormatException('最多选择4份文本快照');
        }
        final conversations = await tx
            .query('tb_conversation_list', where: 'cid=?', whereArgs: [cid]);
        _check(scope);
        final messages = await tx.query('tb_messages',
            where: 'id=? AND cid=? AND ownerType=?',
            whereArgs: [messageId, cid, OwnerType.sender.toString()]);
        _check(scope);
        if (conversations.length != 1 || messages.length != 1) {
          throw StateError('原对话或本人输入已删除');
        }
        var row = messages.single;
        // 老数据只在真实原行事务内补UUID，不能用新行补签旧快照。
        if (row['memorySourceId'] == null || row['memorySourceId'] == '') {
          final id = generateUuidV4();
          await tx.update('tb_messages', {'memorySourceId': id},
              where: 'id=? AND cid=?', whereArgs: [messageId, cid]);
          _check(scope);
          row = (await tx
                  .query('tb_messages', where: 'id=?', whereArgs: [messageId]))
              .single;
          _check(scope);
        }
        final uuid = cloudUuid(row['memorySourceId']);
        final duplicates = await tx.query('tb_messages',
            columns: ['id'], where: 'memorySourceId=?', whereArgs: [uuid]);
        _check(scope);
        if (duplicates.length != 1) {
          throw StateError('来源UUID不唯一');
        }
        final task = cloudText(row['content'], 12000);
        final key = generateUuidV4();
        final versions = await tx.rawQuery(
            'SELECT max(revision) AS n FROM tb_cloud_sources WHERE messageUuid=?',
            [uuid]);
        _check(scope);
        final revision = (versions.single['n'] as int? ?? 0) + 1;
        final inputs = <CloudTextSnapshot>[];
        final bindings = <Map<String, Object?>>[];
        for (final id in inputIds) {
          final files = await tx.query(AgentWorkspaceDao.filesTable,
              where: 'id=? AND cid=?', whereArgs: [id, cid]);
          _check(scope);
          if (files.length != 1) {
            throw StateError('选中的输入已删除');
          }
          final file = files.single;
          final revisions = await tx.query(AgentWorkspaceDao.revisionsTable,
              where: 'fileId=? AND revision=?',
              whereArgs: [id, file['currentRevision']]);
          _check(scope);
          if (revisions.length != 1) {
            throw StateError('选中的输入版本已变化');
          }
          final text = cloudText(revisions.single['content'], 12000);
          final hash = cloudHash(text);
          if (file['contentHash'] != hash) {
            throw StateError('输入内容指纹不一致');
          }
          inputs.add(CloudTextSnapshot(cloudText(file['name'], 240), text));
          bindings.add({
            'bindingId': key,
            'fileId': id,
            'revision': file['currentRevision'],
            'contentHash': hash
          });
        }
        if (inputs.fold<int>(0, (n, v) => n + utf8.encode(v.text).length) >
            24000) {
          throw const FormatException('选中输入总量超过24KiB限制');
        }
        await tx.insert('tb_cloud_sources', {
          'bindingId': key,
          'cid': cid,
          'conversationRowId': conversations.single['id'],
          'sourceRowId': messageId,
          'messageUuid': uuid,
          'revision': revision,
          'sourceHash': cloudHash(task),
          'sourceRowHash': generationSourceRowHash(row),
          'conversationHash': generationSourceRowHash(conversations.single)
        });
        for (final b in bindings) {
          await tx.insert('tb_cloud_input_bindings', b);
          _check(scope);
        }
        return CloudSourceSnapshot(
            key,
            task,
            CloudLocalSource(cid, uuid, revision, cloudHash(task)),
            List.unmodifiable(inputs));
      });

  Future<void> _verifySource(Transaction tx, AgentWorkflowScope scope,
      String bindingId, CloudLocalSource source) async {
    _check(scope);
    final bindings = await tx.query('tb_cloud_sources',
        where: 'bindingId=?', whereArgs: [bindingId]);
    _check(scope);
    if (bindings.length != 1) {
      throw StateError('原来源已变化，未保存到对话');
    }
    final b = bindings.single;
    if (b['valid'] != 1 ||
        b['revision'] != source.revision ||
        b['cid'] != source.cid ||
        b['messageUuid'] != source.messageId ||
        b['sourceHash'] != source.contentHash) {
      throw StateError('原来源已变化，未保存到对话');
    }
    final rows = await tx.query('tb_messages',
        where: 'id=? AND cid=? AND memorySourceId=? AND ownerType=?',
        whereArgs: [
          b['sourceRowId'],
          source.cid,
          source.messageId,
          OwnerType.sender.toString()
        ]);
    _check(scope);
    final conv = await tx.query('tb_conversation_list',
        where: 'id=? AND cid=?',
        whereArgs: [b['conversationRowId'], source.cid]);
    _check(scope);
    if (rows.length != 1 ||
        conv.length != 1 ||
        generationSourceRowHash(rows.single) != b['sourceRowHash'] ||
        generationSourceRowHash(conv.single) != b['conversationHash']) {
      throw StateError('原来源已变化，未保存到对话');
    }
    final inputs = await tx.query('tb_cloud_input_bindings',
        where: 'bindingId=?', whereArgs: [bindingId]);
    _check(scope);
    for (final input in inputs) {
      final files = await tx.query(AgentWorkspaceDao.filesTable,
          where: 'id=? AND cid=? AND currentRevision=? AND contentHash=?',
          whereArgs: [
            input['fileId'],
            source.cid,
            input['revision'],
            input['contentHash']
          ]);
      _check(scope);
      final revisions = await tx.query(AgentWorkspaceDao.revisionsTable,
          where: 'fileId=? AND revision=?',
          whereArgs: [input['fileId'], input['revision']]);
      _check(scope);
      if (files.length != 1 ||
          revisions.length != 1 ||
          cloudHash(revisions.single['content'] as String) !=
              input['contentHash']) {
        throw StateError('选中输入版本已变化');
      }
    }
  }

  Future<void> verifySource(
          AgentWorkflowScope scope, CloudSourceSnapshot source) =>
      _transaction(scope,
          (tx) => _verifySource(tx, scope, source.bindingId, source.source));
  Future<CloudSubmissionRegistration> recordSubmission(AgentWorkflowScope scope,
          {required String origin,
          required int ownerId,
          required CloudSourceSnapshot snapshot,
          required CloudConfirmedPayload payload}) =>
      _transaction(scope, (tx) async {
        cloudInt(ownerId);
        if (payload.encoded.isEmpty ||
            cloudCanonical(payload.source.toJson()) !=
                cloudCanonical(snapshot.source.toJson()) ||
            payload.toJson()['task'] != snapshot.task ||
            cloudCanonical(payload.toJson()['inputs']) !=
                cloudCanonical(
                    snapshot.inputs.map((x) => x.toJson()).toList())) {
          throw StateError('确认内容与捕获来源不一致');
        }
        final old = await tx.query(tableName,
            where: 'origin=? AND ownerId=? AND idempotencyKey=?',
            whereArgs: [origin, ownerId, payload.key]);
        _check(scope);
        if (old.isNotEmpty) {
          if (old.single['payloadHash'] != payload.digest ||
              old.single['bindingId'] != snapshot.bindingId) {
            throw StateError('相同提交身份不能更换内容');
          }
          return CloudSubmissionRegistration(
              CloudLocalReceipt.fromRow(old.single), false);
        }
        await _verifySource(tx, scope, snapshot.bindingId, payload.source);
        final row = {
          'origin': origin,
          'ownerId': ownerId,
          'idempotencyKey': payload.key,
          'payloadHash': payload.digest,
          'bindingId': snapshot.bindingId,
          'sourceJson': cloudCanonical(payload.source.toJson()),
          'status': 'submission_unknown'
        };
        // 先持久化未知状态再POST；崩溃/超时只能查询，同key也不自动重发。
        await tx.insert(tableName, row);
        _check(scope);
        return CloudSubmissionRegistration(
            CloudLocalReceipt.fromRow(
                {...row, 'taskId': null, 'publicationId': null}),
            true);
      });
  Future<List<CloudLocalReceipt>> receipts(
          AgentWorkflowScope scope, String origin, int ownerId) =>
      _transaction(scope, (tx) async {
        final rows = await tx.query(tableName,
            where: 'origin=? AND ownerId=?',
            whereArgs: [origin, ownerId],
            orderBy: 'rowid DESC',
            limit: 100);
        _check(scope);
        return rows.map(CloudLocalReceipt.fromRow).toList();
      });
  Future<CloudLocalReceipt> bindReceipt(AgentWorkflowScope scope,
          CloudLocalReceipt expected, CloudServerReceipt server) =>
      _transaction(scope, (tx) async {
        if (server.ownerId != expected.ownerId ||
            server.payloadHash != expected.payloadHash ||
            cloudCanonical(server.source) !=
                cloudCanonical(expected.source.toJson())) {
          throw StateError('云回执身份或来源不匹配');
        }
        final rows = await tx.query(tableName,
            where: 'origin=? AND ownerId=? AND idempotencyKey=?',
            whereArgs: [expected.origin, expected.ownerId, expected.key]);
        _check(scope);
        if (rows.length != 1 ||
            rows.single['payloadHash'] != expected.payloadHash ||
            rows.single['bindingId'] != expected.bindingId ||
            (rows.single['taskId'] != null &&
                rows.single['taskId'] != server.taskId) ||
            (rows.single['publicationId'] != null &&
                rows.single['publicationId'] != server.publicationId)) {
          throw StateError('提交回执已变化');
        }
        if ((rows.single['serverRevision'] as int) > server.revision) {
          return CloudLocalReceipt.fromRow(rows.single);
        }
        await tx.update(
            tableName,
            {
              'status': 'accepted',
              'taskId': server.taskId,
              'publicationId': server.publicationId,
              'serverRevision': server.revision
            },
            where: 'origin=? AND ownerId=? AND idempotencyKey=?',
            whereArgs: [expected.origin, expected.ownerId, expected.key]);
        _check(scope);
        return CloudLocalReceipt.fromRow({
          ...rows.single,
          'status': 'accepted',
          'taskId': server.taskId,
          'publicationId': server.publicationId,
          'serverRevision': server.revision
        });
      });

  static final _publications = Expando<
      Map<String, ({String digest, Future<CloudPublicationReceipt> future})>>();
  Future<CloudPublicationReceipt> publish(
      AgentWorkflowScope scope,
      CloudLocalReceipt receipt,
      CloudTaskDetail detail,
      CloudWritingResult result) {
    _check(scope);
    if (cloudHash(cloudText(result.content, 48000)) != result.contentHash ||
        result.content.runes.length > 12000) {
      throw const FormatException('云成果正文指纹或长度无效');
    }
    result.verifyFinal(detail);
    final key = cloudCanonical(
        [receipt.origin, receipt.ownerId, detail.taskId, result.publicationId]);
    final digest = cloudHash(cloudCanonical([
      receipt.key,
      receipt.bindingId,
      receipt.payloadHash,
      result.resultId,
      result.version,
      result.contentHash
    ]));
    final pending = _publications[storage.db] ??= {};
    final old = pending[key];
    if (old != null) {
      if (old.digest != digest) {
        throw StateError('同一成果身份不能更换内容');
      }
      return old.future.then((saved) {
        _check(scope);
        return saved;
      });
    }
    late Future<CloudPublicationReceipt> future;
    future = () async {
      try {
        return await _publish(scope, receipt, detail, result);
      } finally {
        if (identical(pending[key]?.future, future)) {
          pending.remove(key);
        }
      }
    }();
    pending[key] = (digest: digest, future: future);
    return future;
  }

  Future<CloudPublicationReceipt> _publish(
      AgentWorkflowScope scope,
      CloudLocalReceipt receipt,
      CloudTaskDetail detail,
      CloudWritingResult result) async {
    _check(scope);
    result.verifyFinal(detail);
    if (detail.ownerId != receipt.ownerId ||
        detail.taskId != receipt.taskId ||
        receipt.publicationId != result.publicationId ||
        receipt.payloadHash != detail.parent['payload_hash']) {
      throw StateError('云成果身份不匹配');
    }
    final payload = cloudObject(detail.parent['payload']);
    if (payload['version'] != 2 ||
        cloudCanonical(payload['source']) !=
            cloudCanonical(receipt.source.toJson())) {
      throw StateError('该任务没有可信本地来源');
    }
    final registry = ConversationExecutionRegistry.instance;
    final cancelled = scope.fork();
    final settled = Completer<void>();
    Future<void> cancel(String _) async {
      cancelled.cancel();
      await settled.future;
    }

    // fork会重新捕获代次，故必须先核原scope且整个事务同时核两者，不能补签失效身份。
    final ticket = registry.claim(
        account: accountHash,
        cid: receipt.source.cid,
        owner: Object(),
        kind: ConversationExecutionKind.agent,
        storageKey: storage.db,
        stop: cancel,
        retire: cancel);
    void check() {
      _check(scope);
      cancelled.verify();
      if (!registry.owns(ticket)) {
        throw StateError('本地发布已撤销');
      }
    }

    try {
      final saved =
          await cancelled.stable(() => storage.db.transaction((tx) async {
                check();
                final args = [
                  receipt.origin,
                  receipt.ownerId,
                  detail.taskId,
                  result.publicationId
                ];
                final ledger = await tx.query('tb_cloud_publications',
                    where:
                        'origin=? AND ownerId=? AND taskId=? AND publicationId=?',
                    whereArgs: args);
                check();
                if (ledger.isNotEmpty) {
                  final old = ledger.single;
                  if (old['resultId'] != result.resultId ||
                      old['resultVersion'] != result.version ||
                      old['contentHash'] != result.contentHash) {
                    throw StateError('同一成果身份不能更换内容或版本');
                  }
                  return CloudPublicationReceipt(
                      old['messageId'] as int, old['deleted'] == 1);
                }
                final local = await tx.query(tableName,
                    where: 'origin=? AND ownerId=? AND idempotencyKey=?',
                    whereArgs: [receipt.origin, receipt.ownerId, receipt.key]);
                check();
                if (local.length != 1 ||
                    local.single['taskId'] != detail.taskId ||
                    local.single['publicationId'] != result.publicationId ||
                    local.single['bindingId'] != receipt.bindingId ||
                    local.single['payloadHash'] != receipt.payloadHash) {
                  throw StateError('本地云回执已变化');
                }
                await _verifySource(
                    tx, scope, receipt.bindingId, receipt.source);
                check();
                final latest = await tx.rawQuery(
                    'SELECT max(createdAt) AS n FROM tb_messages WHERE cid=?',
                    [receipt.source.cid]);
                check();
                final now = DateTime.now().millisecondsSinceEpoch;
                final time = (latest.single['n'] as int? ?? 0) >= now
                    ? (latest.single['n'] as int) + 1
                    : now;
                final uuid = generateUuidV4();
                final blocks = MessageBlock.encodeList([
                  MainTextBlock(
                      id: generateUuidV4(),
                      messageId: time.toString(),
                      createdAt: time,
                      status: MessageBlockStatus.success,
                      content: result.content)
                ]);
                final id = await tx.insert('tb_messages', {
                  'cid': receipt.source.cid,
                  'createdAt': time,
                  'memorySourceId': uuid,
                  'ownerType': OwnerType.receiver.toString(),
                  'ownerName': '云任务成果',
                  'content': result.content,
                  'blocks': blocks
                });
                check();
                await tx.insert('tb_cloud_publications', {
                  'origin': receipt.origin,
                  'ownerId': receipt.ownerId,
                  'taskId': detail.taskId,
                  'publicationId': result.publicationId,
                  'resultId': result.resultId,
                  'resultVersion': result.version,
                  'contentHash': result.contentHash,
                  'messageId': id
                });
                check();
                final count = await tx.rawQuery(
                    'SELECT count(*) AS n FROM tb_messages WHERE cid=?',
                    [receipt.source.cid]);
                check();
                final updated = await tx.update(
                    'tb_conversation_list',
                    {
                      'messageCount': count.single['n'],
                      'lastMessage': result.content,
                      'updateAt': time
                    },
                    where: 'cid=?',
                    whereArgs: [receipt.source.cid]);
                check();
                if (updated != 1) {
                  throw StateError('原对话已删除');
                }
                return CloudPublicationReceipt(id, false);
              }));
      check();
      AppEvents.notifyConversationsChanged();
      return saved;
    } finally {
      registry.release(ticket);
      settled.complete();
    }
  }

  Future<void> markStop(AgentWorkflowScope scope, String origin, int ownerId,
          String taskId, String operationId, String status) =>
      _transaction(scope, (tx) async {
        if (!const {'unknown', 'acknowledged', 'conflict'}.contains(status)) {
          throw StateError('停止状态无效');
        }
        await tx.update('tb_cloud_stop_intents', {'status': status},
            where: 'origin=? AND ownerId=? AND taskId=? AND operationId=?',
            whereArgs: [origin, ownerId, taskId, operationId]);
        _check(scope);
      });
  Future<Map<String, Object?>?> readStop(AgentWorkflowScope scope,
          String origin, int ownerId, String taskId) =>
      _transaction(scope, (tx) async {
        final rows = await tx.query('tb_cloud_stop_intents',
            where: 'origin=? AND ownerId=? AND taskId=?',
            whereArgs: [origin, ownerId, taskId]);
        _check(scope);
        return rows.isEmpty ? null : rows.single;
      });
  Future<Map<String, Object?>> stopIntent(AgentWorkflowScope scope,
          String origin, int ownerId, String taskId, int revision,
          {bool newIntent = false}) =>
      _transaction(scope, (tx) async {
        final args = [origin, ownerId, taskId];
        final rows = await tx.query('tb_cloud_stop_intents',
            where: 'origin=? AND ownerId=? AND taskId=?', whereArgs: args);
        _check(scope);
        if (rows.isNotEmpty && !newIntent) {
          return rows.single;
        }
        final row = {
          'origin': origin,
          'ownerId': ownerId,
          'taskId': cloudUuid(taskId),
          'operationId': generateUuidV4(),
          'expectedRevision': cloudInt(revision),
          'status': 'requested'
        };
        await tx.insert('tb_cloud_stop_intents', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
        _check(scope);
        return row;
      });
}
