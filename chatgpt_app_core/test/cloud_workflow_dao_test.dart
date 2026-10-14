import 'dart:async';
import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/cloud_workflow_fixture.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager db;
  late CloudWorkflowDao dao;
  late int userId;
  late PersonalMemoryTestAccount auth;
  AgentWorkflowScope scope() => AgentWorkflowScope(accountHash: 'a');
  Future<(CloudLocalReceipt, CloudFixtureResult)> accepted(
      {List<int> files = const []}) async {
    final s =
        await dao.capture(scope(), cid: 1, messageId: userId, inputIds: files);
    final p = cloudFixturePayload(s);
    final cloud = CloudFixtureResult(p);
    final r = await dao.recordSubmission(scope(),
        origin: cloudFixtureOrigin, ownerId: 7, snapshot: s, payload: p);
    expect(r.shouldSend, true);
    return (
      await dao.bindReceipt(
          scope(), r.receipt, CloudServerReceipt.fromJson(cloud.receipt())),
      cloud
    );
  }

  setUp(() async {
    auth = PersonalMemoryTestAccount('a')..install();
    sqfliteFfiInit();
    db = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(db)).saveConversation(
        ConversationModel(
            cid: 1,
            title: '保留标题',
            icon: '合成',
            stickTime: 99,
            modelId: 'local-fixed',
            assistantId: 23));
    userId = await (await MessageDao.create(db, cid: 1)).saveMessageWithBlocks(
        MessageModel(
            content: '本次确认任务',
            ownerType: OwnerType.sender,
            createdAt: 123,
            ownerName: '本人'));
    dao = await CloudWorkflowDao.create(db, accountHash: 'a');
  });
  tearDown(() async {
    expect(ConversationExecutionRegistry.instance.lookup('a', 1), null);
    await db.db.close();
    LoginSdkConfig.reset();
  });
  test('来源单调revision/输入白名单与receipt-before-POST，重复意图不得重新发送', () async {
    final source = await dao.capture(scope(), cid: 1, messageId: userId);
    final again = await dao.capture(scope(), cid: 1, messageId: userId);
    expect(again.source.revision, greaterThan(source.source.revision));
    final p = cloudFixturePayload(source);
    final first = await dao.recordSubmission(scope(),
        origin: cloudFixtureOrigin, ownerId: 7, snapshot: source, payload: p);
    final second = await dao.recordSubmission(scope(),
        origin: cloudFixtureOrigin, ownerId: 7, snapshot: source, payload: p);
    expect(first.shouldSend, true);
    expect(second.shouldSend, false);
    expect((await db.db.query(dao.tableName)).single['status'],
        'submission_unknown');
    final text = jsonEncode(await db.db.query(dao.tableName));
    expect(text, isNot(contains('Bearer')));
    expect(text, isNot(contains('本次确认任务')));
    expect(await dao.receipts(scope(), cloudFixtureOrigin, 8), isEmpty);
  });
  test('真实消息成果追加/重建DAO/双点击幂等，摘要只改摘要字段', () async {
    final (r, c) = await accepted();
    final before = (await db.db.query('tb_conversation_list')).single;
    final saved = await Future.wait([
      dao.publish(scope(), r, c.parsedDetail, c.parsedResult),
      dao.publish(scope(), r, c.parsedDetail, c.parsedResult)
    ]);
    expect(saved[0].messageId, saved[1].messageId);
    final reopened = await CloudWorkflowDao.create(db, accountHash: 'a');
    expect(
        (await reopened.publish(scope(), r, c.parsedDetail, c.parsedResult))
            .messageId,
        saved[0].messageId);
    expect(await db.db.query('tb_messages'), hasLength(2));
    expect(await db.db.query('tb_cloud_publications'), hasLength(1));
    final after = (await db.db.query('tb_conversation_list')).single;
    expect(after['messageCount'], 2);
    expect(after['lastMessage'], '合成云成果');
    for (final key in before.keys.where(
        (k) => !['messageCount', 'lastMessage', 'updateAt'].contains(k))) {
      expect(after[key], before[key], reason: key);
    }
  });
  test('已发布消息删除保留墓碑，刷新/重开不复活', () async {
    final (r, c) = await accepted();
    final saved = await dao.publish(scope(), r, c.parsedDetail, c.parsedResult);
    await (await MessageDao.create(db, cid: 1)).deleteMessageByCreatedAt(
        (await db.db.query('tb_messages',
                where: 'id=?', whereArgs: [saved.messageId]))
            .single['createdAt'] as int);
    expect(
        (await dao.publish(scope(), r, c.parsedDetail, c.parsedResult)).deleted,
        true);
    expect(await db.db.query('tb_messages'), hasLength(1));
  });
  for (final mutation in [
    'content-back',
    'blocks-back',
    'source-recreate',
    'conversation-recreate',
    'later-turn',
    'assistant-back',
    'clear'
  ]) {
    test('真实SQLite $mutation 永久失效，不用cid/正文猜测新来源', () async {
      final (r, c) = await accepted();
      final row =
          (await db.db.query('tb_messages', where: 'id=?', whereArgs: [userId]))
              .single;
      final conv = (await db.db.query('tb_conversation_list')).single;
      switch (mutation) {
        case 'content-back':
          await db.db.update('tb_messages', {'content': '改变'},
              where: 'id=?', whereArgs: [userId]);
          await db.db.update('tb_messages', {'content': row['content']},
              where: 'id=?', whereArgs: [userId]);
        case 'blocks-back':
          await db.db.update(
              'tb_messages', {'blocks': '[]', 'images': '["新附件"]'},
              where: 'id=?', whereArgs: [userId]);
          await db.db.update(
              'tb_messages', {'blocks': row['blocks'], 'images': row['images']},
              where: 'id=?', whereArgs: [userId]);
        case 'source-recreate':
          await db.db.delete('tb_messages', where: 'id=?', whereArgs: [userId]);
          await db.db.insert('tb_messages', row);
        case 'conversation-recreate':
          await db.db.delete('tb_conversation_list');
          await db.db.insert('tb_conversation_list', conv);
        case 'later-turn':
          await db.db.insert('tb_messages', {
            'cid': 1,
            'content': '后续轮次',
            'ownerType': OwnerType.sender.toString(),
            'createdAt': 124
          });
        case 'assistant-back':
          await db.db.update('tb_conversation_list', {'assistantId': 55});
          await db.db.update(
              'tb_conversation_list', {'assistantId': conv['assistantId']});
        case 'clear':
          await db.db.delete('tb_messages', where: 'cid=?', whereArgs: [1]);
      }
      await expectLater(dao.publish(scope(), r, c.parsedDetail, c.parsedResult),
          throwsStateError);
      expect(await db.db.query('tb_cloud_publications'), isEmpty);
      expect(
          await db.db.query('tb_messages',
              where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]),
          isEmpty);
    });
  }
  test('workspace原版本改回也永久失效；其他cid输入不受影响', () async {
    final file = await (await AgentWorkspaceDao.create(db, cid: 1)).saveInput(
        name: 'input.txt',
        sourceKey: 'synthetic',
        contentHash: cloudHash('选定文本'),
        content: '选定文本',
        pageTexts: [],
        sizeBytes: 12);
    final (r, c) = await accepted(files: [file.id]);
    await db.db.update(AgentWorkspaceDao.revisionsTable, {'content': '改变'},
        where: 'fileId=?', whereArgs: [file.id]);
    await db.db.update(AgentWorkspaceDao.revisionsTable, {'content': '选定文本'},
        where: 'fileId=?', whereArgs: [file.id]);
    await expectLater(dao.publish(scope(), r, c.parsedDetail, c.parsedResult),
        throwsStateError);
  });
  test('finalResult/写作版本/hash/owner/pub不符拒绝；旧v1不推断写回', () async {
    final (r, c) = await accepted();
    final invalid = c.detail();
    final v1 = cloudFixturePayload(
            await dao.capture(scope(), cid: 1, messageId: userId))
        .toJson()
      ..['version'] = 1;
    v1['source'] = {
      'cid': 1,
      'messageId': r.source.messageId,
      'contentHash': r.source.contentHash
    };
    (invalid['parent'] as Map)['payload'] = v1;
    (invalid['parent'] as Map)['payload_hash'] = cloudHash(cloudCanonical(v1));
    await expectLater(
        dao.publish(
            scope(), r, CloudTaskDetail.fromJson(invalid), c.parsedResult),
        throwsStateError);
    final wrong = c.detail();
    (wrong['steps'] as List)[1]['result_version'] = 2;
    await expectLater(
        Future.sync(() => dao.publish(
            scope(), r, CloudTaskDetail.fromJson(wrong), c.parsedResult)),
        throwsFormatException);
    final bad = c.result()..['content'] = '篡改';
    expect(() => CloudWritingResult.fromJson(bad), throwsFormatException);
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
  });
  test('本机执行占用拒绝云发布，不抢停原run', () async {
    final (r, c) = await accepted();
    var stops = 0;
    final registry = ConversationExecutionRegistry.instance;
    final ticket = registry.claim(
        account: 'a',
        cid: 1,
        owner: Object(),
        kind: ConversationExecutionKind.ordinary,
        storageKey: db.db,
        stop: (_) async {
          stops++;
        });
    await expectLater(dao.publish(scope(), r, c.parsedDetail, c.parsedResult),
        throwsStateError);
    expect(stops, 0);
    expect(registry.owns(ticket), true);
    registry.release(ticket);
  });
  test('真实trigger阻止摘要写入时reply+publication全回滚，重试仅保存一次', () async {
    final (r, c) = await accepted();
    await db.db.execute(
        "CREATE TRIGGER fail_cloud_summary BEFORE UPDATE ON tb_conversation_list BEGIN SELECT RAISE(ABORT,'synthetic failure'); END");
    await expectLater(dao.publish(scope(), r, c.parsedDetail, c.parsedResult),
        throwsA(isA<DatabaseException>()));
    expect(await db.db.query('tb_messages'), hasLength(1));
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
    await db.db.execute('DROP TRIGGER fail_cloud_summary');
    await dao.publish(scope(), r, c.parsedDetail, c.parsedResult);
    expect(await db.db.query('tb_messages'), hasLength(2));
  });
  test('实际Login A→B→A与同账号重登旧scope不能写入', () async {
    final (r, c) = await accepted();
    final old = scope();
    auth.account = 'b';
    await LoginDao.saveAuthToken('synthetic-b', extras: {'accountHash': 'b'});
    auth.account = 'a';
    await LoginDao.saveAuthToken('synthetic-a', extras: {'accountHash': 'a'});
    await expectLater(
        Future.sync(() => dao.publish(old, r, c.parsedDetail, c.parsedResult)),
        throwsA(anything));
    final same = scope();
    await LoginDao.saveAuthToken('synthetic-a', extras: {'accountHash': 'a'});
    await expectLater(
        Future.sync(() => dao.publish(same, r, c.parsedDetail, c.parsedResult)),
        throwsA(anything));
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
  });
  test('最后许可等待期间改源后拒绝，无半ledger/旧scope补签', () async {
    final (r, c) = await accepted();
    final entered = Completer<void>(), release = Completer<void>();
    final holder = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          entered.complete();
          await release.future;
        });
    await entered.future;
    final saving = dao.publish(scope(), r, c.parsedDetail, c.parsedResult);
    final checked = expectLater(saving, throwsStateError);
    await db.db.update('tb_messages', {'content': '许可等待中新正文'},
        where: 'id=?', whereArgs: [userId]);
    release.complete();
    await holder;
    await checked;
    expect(await db.db.query('tb_cloud_publications'), isEmpty);
  });
}
