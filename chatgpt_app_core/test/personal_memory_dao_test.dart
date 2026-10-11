import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/personal_memory_rules.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late PersonalMemoryDao dao;
  late MessageDao messages;
  late ConversationListDao conversations;
  late PersonalMemoryTestAccount auth;
  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false)));
  Future<void> enable({bool suggestions = false}) async {
    final p = await dao.preferences();
    await dao.setPreferences(
        revision: p.revision, enabled: true, suggestionsEnabled: suggestions);
  }

  Future<void> seedTurn(String input) async {
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, content: input, createdAt: 10));
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.receiver, content: '合成完成回复', createdAt: 11));
  }

  setUp(() async {
    sqfliteFfiInit();
    auth = PersonalMemoryTestAccount('a')..install();
    storage = await newDb();
    conversations = await ConversationListDao.create(storage);
    await conversations
        .saveConversation(ConversationModel(cid: 1, icon: '', title: '合成一'));
    await conversations
        .saveConversation(ConversationModel(cid: 2, icon: '', title: '合成二'));
    messages = await MessageDao.create(storage, cid: 1);
    dao = await PersonalMemoryDao.create(storage, accountHash: 'a');
  });
  tearDown(() async {
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  test('新增空个人表不共享旧助手记忆，开关默认关闭，重开保留', () async {
    expect((await dao.preferences()).enabled, isFalse);
    expect((await dao.preferences()).suggestionsEnabled, isFalse);
    await dao.save('回答请简短');
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        isEmpty);
    await enable();
    final reopened = await PersonalMemoryDao.create(storage, accountHash: 'a');
    expect((await reopened.preferences()).enabled, isTrue);
    expect((await reopened.list()).single.content, '回答请简短');
  });
  test('同账号两cid生效，悬挂助手/任务排除，不绑定UI缓存', () async {
    final m = await dao.save('偏好简短解释');
    await enable();
    for (final cid in [1, 2]) {
      expect(
          await dao.requestContext(
              cid: cid, assistantId: null, taskMode: false),
          contains(m.content));
    }
    expect(await dao.requestContext(cid: 1, assistantId: 999, taskMode: false),
        isEmpty);
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: true),
        isEmpty);
    await storage.db
        .update('tb_conversation_list', {'assistantId': 999}, where: 'cid=2');
    expect(await dao.requestContext(cid: 2, assistantId: null, taskMode: false),
        isEmpty);
    await dao.setStatus(m, PersonalMemoryStatus.archived);
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        isEmpty);
    final current = (await dao.list()).single;
    await dao.setStatus(current, PersonalMemoryStatus.active);
    await dao.delete((await dao.list()).single);
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        isEmpty);
  });
  test('账号/游客隔离且旧账号异步lease不能写新账号', () async {
    await dao.save('账号 A 偏好');
    final other = await newDb();
    try {
      auth.account = 'guest';
      final guest = await PersonalMemoryDao.create(other, accountHash: 'guest');
      expect(await guest.list(), isEmpty);
      await guest.save('游客偏好');
      await expectLater(
          dao.save('过期写入'), throwsA(isA<LoginAccountChangedException>()));
      auth.account = 'a';
      expect((await dao.list()).single.content, '账号 A 偏好');
      auth.account = 'b';
      await expectLater(
          guest.list(), throwsA(isA<LoginAccountChangedException>()));
    } finally {
      await other.db.close();
    }
  });
  test('事务去重、revision比较与删除后编辑不能复活', () async {
    final results = await Future.wait([dao.save('我喜欢简洁'), dao.save(' 我喜欢\n简洁 ')]
        .map((f) => f.then<Object>((v) => v, onError: (Object e) => e)));
    expect(results.whereType<PersonalMemory>().length, 1);
    expect(results.whereType<PersonalMemoryConflict>().length, 1);
    final first = (await dao.list()).single;
    final second = await dao.save('我喜欢具体例子', existing: first);
    expect(second.memoryId, first.memoryId);
    expect(second.revision, first.revision + 1);
    await expectLater(dao.save('旧正文', existing: first),
        throwsA(isA<PersonalMemoryConflict>()));
    await dao.delete(second);
    await expectLater(dao.save('复活', existing: second),
        throwsA(isA<PersonalMemoryConflict>()));
    expect(await dao.list(), isEmpty);
    expect(
        (await storage.db.query('tb_personal_memory_tombstone'))
            .single['memoryId'],
        first.memoryId);
  });
  test('Unicode单条400、8条总2000、JSON数据隔离与总数200分页边界', () async {
    await expectLater(
        dao.save('😀' * 401), throwsA(isA<PersonalMemoryConflict>()));
    for (var i = 0; i < 10; i++) {
      await dao.save('$i${'字' * 399}');
    }
    await enable();
    final context =
        await dao.requestContext(cid: 1, assistantId: null, taskMode: false);
    final facts =
        jsonDecode(context.substring(context.lastIndexOf('\n') + 1)) as List;
    expect(facts.length, 5);
    expect(facts.join().runes.length, 2000);
    final sample = (await dao.list()).first.toJson();
    final batch = storage.db.batch();
    for (var i = 10; i < 200; i++) {
      batch.insert('tb_personal_memory', {
        ...sample,
        'memoryId': 'synthetic-$i',
        'content': '合成$i',
        'normalizedKey': PersonalMemory.keyFor('合成$i')
      });
    }
    await batch.commit(noResult: true);
    expect((await dao.list(page: 0)).length, 50);
    expect((await dao.list(page: 3)).length, 50);
    expect(await dao.list(page: 4), isEmpty);
    await expectLater(
        dao.save('超过总条目'), throwsA(isA<PersonalMemoryConflict>()));
  });
  test('来源UUID/指纹不关联同号新行，删除/正文修改立即停用', () async {
    await seedTurn('我偏好具体例子');
    final source = (await dao.sourceForMessage(1, 10))!;
    final m = await dao.save('我偏好具体例子', source: source);
    await enable();
    await messages.deleteMessageByCreatedAt(10);
    expect((await dao.list()).single.status, PersonalMemoryStatus.archived);
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, content: '我偏好具体例子', createdAt: 10));
    await expectLater(
        dao.setStatus((await dao.list()).single, PersonalMemoryStatus.active),
        throwsA(isA<PersonalMemoryConflict>()));
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        isEmpty);
    await dao.delete((await dao.list()).single);
    final fresh = (await dao.sourceForMessage(1, 10))!;
    expect(fresh.messageId, isNot(source.messageId));
    await dao.save('新来源', source: fresh);
    await storage.db.update('tb_messages', {'content': '正文变化'},
        where: 'cid=1 and createdAt=10');
    expect((await dao.list()).single.invalidReason, contains('来源已删除'));
    expect(m.sourceFingerprint, PersonalMemory.fingerprint('我偏好具体例子'));
  });
  test('来源会话删除会停用，纯手动保留', () async {
    await seedTurn('我喜欢短回答');
    await dao.save('消息记忆', source: (await dao.sourceForMessage(1, 10))!);
    await dao.save('纯手动');
    await conversations.deleteConversation(ConversationModel(cid: 1, icon: ''));
    final rows = await dao.list();
    expect(rows.singleWhere((m) => m.content == '消息记忆').status,
        PersonalMemoryStatus.archived);
    expect(rows.singleWhere((m) => m.content == '纯手动').status,
        PersonalMemoryStatus.active);
  });
  test('post-persist候选、epoch失效、pending不注入、journal拒绝重启复活', () async {
    await enable(suggestions: true);
    final turn = (await dao.beginTurn(
        cid: 1,
        assistantId: null,
        taskMode: false,
        rawInput: '我希望回答举例说明',
        startedAt: DateTime.now().millisecondsSinceEpoch))!;
    await dao.suggestAfterPersist(turn, userCreatedAt: 10, replyCreatedAt: 11);
    expect(await dao.list(), isEmpty);
    await seedTurn(turn.rawInput);
    await dao.suggestAfterPersist(turn, userCreatedAt: 10, replyCreatedAt: 11);
    final pending = (await dao.list()).single;
    expect(pending.status, PersonalMemoryStatus.pending);
    expect(await dao.requestContext(cid: 1, assistantId: null, taskMode: false),
        isEmpty);
    await dao.setStatus(pending, PersonalMemoryStatus.rejected);
    final reopen = await PersonalMemoryDao.create(storage, accountHash: 'a');
    await reopen.suggestAfterPersist(turn,
        userCreatedAt: 10, replyCreatedAt: 11);
    expect((await reopen.list()).length, 1);
    await reopen.delete((await reopen.list()).single);
    await reopen.suggestAfterPersist(turn,
        userCreatedAt: 10, replyCreatedAt: 11);
    expect(await reopen.list(), isEmpty);
    await enable(suggestions: true);
    await dao.suggestAfterPersist(turn, userCreatedAt: 10, replyCreatedAt: 11);
    expect(await dao.list(), isEmpty);
  });
  test('候选来源删除/授权反复切换不能确认；凭证与保守规则拒绝敏感引用', () async {
    for (final input in [
      '我是皇帝',
      '我的生日是2000年',
      '请记住密码123456',
      '我喜欢“某人说的内容”',
      '我喜欢政治讨论',
      '我偏好住址记录',
      '我喜欢 a@example.com',
      '我喜欢健康建议',
      '我喜欢\n代码'
    ]) {
      expect(PersonalMemoryRules.suggest(input), isNull, reason: input);
    }
    expect(PersonalMemoryRules.suggest('我希望回答简短清楚'), isNotNull);
    await expectLater(
        dao.save('api_key=合成凭证'), throwsA(isA<PersonalMemoryConflict>()));
    await enable(suggestions: true);
    final turn = (await dao.beginTurn(
        cid: 1,
        assistantId: null,
        taskMode: false,
        rawInput: '我希望回答简短清楚',
        startedAt: DateTime.now().millisecondsSinceEpoch))!;
    await seedTurn(turn.rawInput);
    await dao.suggestAfterPersist(turn, userCreatedAt: 10, replyCreatedAt: 11);
    final candidate = (await dao.list()).single;
    await messages.deleteMessageByCreatedAt(10);
    await expectLater(dao.setStatus(candidate, PersonalMemoryStatus.active),
        throwsA(isA<PersonalMemoryConflict>()));
    expect(
        await dao.beginTurn(
            cid: 1,
            assistantId: 999,
            taskMode: false,
            rawInput: '我喜欢例子',
            startedAt: 0),
        isNull);
  });
  test('封闭回答偏好白名单不自动保存任意个人或敏感事实', () {
    for (final input in [
      '我喜欢佛教',
      '我喜欢和同性谈恋爱',
      '我偏好支持某具体政党',
      '我希望回答简短清楚然后保存我的疾病',
      '他说我希望回答简短',
      '我希望回答“详细”',
      '我希望回答使用中文 api-key=abc',
      '回答时请用中文 cookie=value',
      '我希望回答简短\n我喜欢秘密',
      '我的学习目标是学数学',
      '我喜欢具体例子',
      '我希望回答token abc',
      '我希望回答bearer abc',
      '我希望回答private_key abc'
    ]) {
      expect(PersonalMemoryRules.suggest(input), isNull, reason: input);
    }
    for (final input in [
      '我希望回答简短清楚',
      '我希望你回答详细',
      '以后回答请用中文。',
      '回答时请举例说明',
      '我希望回答分点说明'
    ]) {
      expect(PersonalMemoryRules.suggest(input), input, reason: input);
    }
  });
  test('候选删除或编辑后原文hash跨新来源/cid/重开继续抑制；手动新增允许', () async {
    await enable(suggestions: true);
    Future<void> suggest(int cid, int at, String text) async {
      final turn = (await dao.beginTurn(
          cid: cid,
          assistantId: null,
          taskMode: false,
          rawInput: text,
          startedAt: DateTime.now().millisecondsSinceEpoch))!;
      final messageDao = await MessageDao.create(storage, cid: cid);
      await messageDao.saveMessageWithBlocks(MessageModel(
          ownerType: OwnerType.sender, content: text, createdAt: at));
      await messageDao.saveMessageWithBlocks(MessageModel(
          ownerType: OwnerType.receiver, content: '合成完成', createdAt: at + 1));
      await dao.suggestAfterPersist(turn,
          userCreatedAt: at, replyCreatedAt: at + 1);
      await dao.suggestAfterPersist(turn,
          userCreatedAt: at, replyCreatedAt: at + 1);
    }

    const original = '我希望回答简短清楚';
    await suggest(1, 100, original);
    await dao.delete((await dao.list()).single);
    dao = await PersonalMemoryDao.create(storage, accountHash: 'a');
    await suggest(2, 200, original);
    expect(await dao.list(), isEmpty);
    final manual = await dao.save(original);
    expect(manual.confirmedByUser, isTrue);
    await dao.delete(manual);
    const editedOriginal = '我希望回答详细';
    await suggest(1, 300, editedOriginal);
    final candidate = (await dao.list()).single;
    await dao.save('手动编辑后的回答偏好', existing: candidate, confirmCandidate: true);
    dao = await PersonalMemoryDao.create(storage, accountHash: 'a');
    await suggest(2, 400, editedOriginal);
    expect((await dao.list()).single.content, '手动编辑后的回答偏好');
    final suppressed = await storage.db.query('tb_personal_memory_suppression');
    expect(suppressed, hasLength(2));
    expect(
        suppressed.every((r) =>
            RegExp(r'^[0-9a-f]{64}$').hasMatch(r['normalizedKey'] as String)),
        isTrue);
  });
  test('事务失败不乐观更新，设置旧revision被拒绝', () async {
    final before = await dao.preferences();
    await enable();
    await expectLater(
        dao.setPreferences(
            revision: before.revision,
            enabled: false,
            suggestionsEnabled: false),
        throwsA(isA<PersonalMemoryConflict>()));
    await storage.db.execute(
        "create trigger fail_personal before insert on tb_personal_memory begin select raise(abort,'fixture failure'); end");
    await expectLater(dao.save('失败写入'), throwsA(isA<DatabaseException>()));
    expect(await dao.list(), isEmpty);
    expect((await dao.preferences()).enabled, isTrue);
  });
}
