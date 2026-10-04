import 'dart:convert';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_center_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late HiDBManager manager;
  late ConversationListDao conversations;
  late AgentTaskCenterService service;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    manager = HiDBManager.test(db);
    conversations = await ConversationListDao.create(manager);
    await MessageDao.create(manager, cid: 0);
    await AgentTaskDao.create(manager);
    service = await AgentTaskCenterService.create(manager);
  });
  tearDown(() => db.close());

  Future<ConversationModel> addConversation(int cid, {String? title}) async {
    final model = ConversationModel(cid: cid, title: title, icon: '🤖');
    await conversations.saveConversation(model);
    return model;
  }

  Future<void> addMessage(int cid, int at,
      {OwnerType owner = OwnerType.sender}) async {
    await db.insert('tb_messages', {
      'cid': cid,
      'content': '任务输入 $at',
      'createdAt': at,
      'ownerType': owner.toString(),
    });
  }

  Future<void> addTask(int cid,
      {int at = 101,
      int updatedAt = 1000,
      Map<String, dynamic> overrides = const {}}) async {
    await db.insert(
      'tb_agent_task_session',
      {
        'cid': cid,
        'snapshot': jsonEncode({
          'version': 1,
          'enabled': true,
          'prompt': '分析长文件并写出成果',
          'userCreatedAt': at,
          'status': 'paused',
          'todos': [
            {'content': '读取', 'status': 'completed'},
            {'content': '输出', 'status': 'in_progress'},
          ],
          'messages': [],
          ...overrides,
        }),
        'updatedAt': updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  test('old account without task tables reads empty without creating tables',
      () async {
    final oldDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(oldDb.close);
    final oldService =
        await AgentTaskCenterService.create(HiDBManager.test(oldDb));
    expect((await oldService.listTasks()).entries, isEmpty);
    expect(await oldService.conversationForTask(1), isNull);
    expect(await oldDb.rawQuery('select name from sqlite_master'), isEmpty);
  });

  test('same cid is isolated by account database and task keeps original model',
      () async {
    final model = await addConversation(7, title: '账号 A');
    model.assistantId = 23;
    model.modelProviderId = 'custom';
    model.modelId = 'reasoning-model';
    model.projectId = 5;
    model.toolIds = ['calculator'];
    model.webSearchEnabled = true;
    await conversations.saveConversation(model);
    await addMessage(7, 101);
    await addTask(7);

    final otherDb = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(otherDb.close);
    final otherManager = HiDBManager.test(otherDb);
    final otherConversations = await ConversationListDao.create(otherManager);
    await otherConversations
        .saveConversation(ConversationModel(cid: 7, title: '账号 B', icon: '🧑'));
    await AgentTaskDao.create(otherManager);
    await otherDb.insert('tb_agent_task_session', {
      'cid': 7,
      'snapshot': jsonEncode({
        'enabled': true,
        'prompt': '另一个账号的任务',
        'userCreatedAt': 202,
        'status': 'complete',
      }),
      'updatedAt': 2000,
    });
    final otherService = await AgentTaskCenterService.create(otherManager);
    expect((await service.listTasks()).entries.single.title, '账号 A');
    expect((await otherService.listTasks()).entries.single.title, '账号 B');
    final loaded = await service.conversationForTask(7, requireResumable: true);
    expect(loaded?.assistantId, 23);
    expect(loaded?.modelProviderId, 'custom');
    expect(loaded?.modelId, 'reasoning-model');
    expect(loaded?.projectId, 5);
    expect(loaded?.toolIds, ['calculator']);
    expect(loaded?.webSearchEnabled, isTrue);
  });

  test('titleless task stays visible but a mode toggle is not a task',
      () async {
    await addConversation(1);
    await addMessage(1, 101);
    await addTask(1);
    await addTask(2, overrides: {'prompt': '', 'userCreatedAt': null});
    await addTask(3, overrides: {'prompt': '尚未发送', 'userCreatedAt': null});
    final page = await service.listTasks();
    expect(page.entries, hasLength(1));
    expect(page.entries.single.title, '分析长文件并写出成果');
    expect(page.entries.single.canResume, isTrue);
    expect((await conversations.getConversationList()), isEmpty);
    expect((await service.conversationForTask(1))?.title, isNull);
  });

  test(
      'running is interrupted and lists todo progress without mutating snapshot',
      () async {
    await addConversation(1, title: '任务');
    await addMessage(1, 101);
    await addTask(1, overrides: {'status': 'running'});
    final before = await db.query('tb_agent_task_session');
    final entry = (await service.listTasks()).entries.single;
    expect(entry.status, 'paused');
    expect(entry.interrupted, isTrue);
    expect(entry.canResume, isTrue);
    expect(entry.pauseReason, '应用中断，可继续');
    expect(entry.completedTodos, 1);
    expect(entry.totalTodos, 2);
    expect(await db.query('tb_agent_task_session'), before);
  });

  test('disabled task and replaced user turn cannot be resumed', () async {
    await addConversation(1, title: '旧任务');
    await addMessage(1, 101);
    await addMessage(1, 102, owner: OwnerType.receiver);
    await addTask(1);
    expect((await service.listTasks()).entries.single.canResume, isTrue);
    await addMessage(1, 103);
    var entry = (await service.listTasks()).entries.single;
    expect(entry.canResume, isFalse);
    expect(entry.pauseReason, contains('新的用户输入'));
    expect(
        await service.conversationForTask(1, requireResumable: true), isNull);
    expect(await service.conversationForTask(1), isNotNull);
    await addTask(1, at: 103, overrides: {'enabled': false});
    entry = (await service.listTasks()).entries.single;
    expect(entry.canResume, isFalse);
    expect(entry.pauseReason, contains('关闭任务模式'));
    expect(
        await service.conversationForTask(1, requireResumable: true), isNull);
  });

  test('missing task message or conversation disables recovery', () async {
    await addConversation(1, title: '消息已删');
    await addTask(1);
    var entry = (await service.listTasks()).entries.single;
    expect(entry.hasConversation, isTrue);
    expect(entry.canResume, isFalse);
    expect(entry.pauseReason, contains('任务消息已被删除'));
    await db.delete('tb_conversation_list', where: 'cid = ?', whereArgs: [1]);
    entry = (await service.listTasks()).entries.single;
    expect(entry.hasConversation, isFalse);
    expect(entry.canResume, isFalse);
    expect(await service.conversationForTask(1), isNull);
  });

  test('conversation deletion clears only its own task from the center',
      () async {
    final first = await addConversation(1, title: '删除此任务');
    await addConversation(2, title: '保留此任务');
    await addMessage(1, 101);
    await addMessage(2, 101);
    await addTask(1);
    await addTask(2);
    await conversations.deleteConversation(first);
    expect((await service.listTasks()).entries.map((entry) => entry.cid), [2]);
    expect(await service.conversationForTask(1), isNull);
  });

  test('bad JSON is isolated and a filtered page advances its raw cursor',
      () async {
    await addConversation(1, title: '正常');
    await addMessage(1, 101);
    await addTask(1, updatedAt: 10);
    await db.insert('tb_agent_task_session',
        {'cid': 2, 'snapshot': '[{}]', 'updatedAt': 20});
    await db.insert('tb_agent_task_session',
        {'cid': 3, 'snapshot': '{broken json', 'updatedAt': 30});
    var page = await service.listTasks(limit: 1);
    expect(page.entries, isEmpty);
    expect(page.nextOffset, 1);
    page = await service.listTasks(offset: page.nextOffset!, limit: 1);
    expect(page.entries, isEmpty);
    expect(page.nextOffset, 2);
    page = await service.listTasks(offset: page.nextOffset!, limit: 1);
    expect(page.entries.single.cid, 1);
    expect(page.nextOffset, 3);
    expect((await service.listTasks(offset: 3, limit: 1)).nextOffset, isNull);
    expect((await service.listTasks()).entries.single.cid, 1);
  });

  test('unknown version or unusable protocol shows task but refuses resume',
      () async {
    await addConversation(1, title: '未来快照');
    await addMessage(1, 101);
    await addTask(1, overrides: {'version': 2});
    var entry = (await service.listTasks()).entries.single;
    expect(entry.canResume, isFalse);
    expect(entry.pauseReason, contains('快照格式无效'));
    await addTask(1, overrides: {
      'messages': [1, 'broken']
    });
    entry = (await service.listTasks()).entries.single;
    expect(entry.canResume, isFalse);
    expect(
        await service.conversationForTask(1, requireResumable: true), isNull);
  });

  test('latest snapshot replaces earlier task and preserves saved pause reason',
      () async {
    await addConversation(1, title: '任务');
    await addMessage(1, 101);
    await addTask(1, updatedAt: 100);
    await addMessage(1, 102);
    await addTask(1,
        at: 102,
        updatedAt: 200,
        overrides: {'pauseReason': '用户暂停', 'prompt': '新任务'});
    final entry = (await service.listTasks()).entries.single;
    expect(entry.userCreatedAt, 102);
    expect(entry.updatedAt, 200);
    expect(entry.preview, '新任务');
    expect(entry.pauseReason, '用户暂停');
    expect(entry.canResume, isTrue);
    expect(await db.query('tb_agent_task_session'), hasLength(1));
  });

  test('wrong typed fields do not promise a resumable snapshot', () async {
    await addConversation(1, title: '格式损坏');
    await addMessage(1, 101);
    final invalid = <Map<String, dynamic>>[
      {'nextRound': '1'},
      {'generation': false},
      {'executingToolId': 8},
      {'pauseReason': []},
      {'needsContinuation': 'true'},
      {
        'todos': [
          {'content': '状态损坏', 'status': 1}
        ]
      },
      {
        'messages': [
          {'role': 'assistant', 'content': 5}
        ]
      },
      {
        'messages': [
          {
            'role': 'assistant',
            'tool_calls': [
              {'id': 'call', 'function': 'broken'}
            ]
          }
        ]
      },
    ];
    for (final bad in invalid) {
      await addTask(1, overrides: bad);
      final entry = (await service.listTasks()).entries.single;
      expect(entry.canResume, isFalse, reason: '$bad');
      expect(
          await service.conversationForTask(1, requireResumable: true), isNull,
          reason: '$bad');
    }
  });

  test(
      'backup insertion order does not make an earlier message the latest turn',
      () async {
    await addConversation(1, title: '恢复备份');
    await addMessage(1, 101);
    await addTask(1);
    await addMessage(1, 100);
    expect((await service.listTasks()).entries.single.canResume, isTrue);
    expect(await service.conversationForTask(1, requireResumable: true),
        isNotNull);
  });

  test('pagination arguments are bounded and previews keep surrogate pairs',
      () async {
    await expectLater(service.listTasks(offset: -1), throwsArgumentError);
    await expectLater(service.listTasks(limit: 0), throwsArgumentError);
    await expectLater(service.listTasks(limit: 101), throwsArgumentError);
    await addConversation(1, title: 'null');
    await addMessage(1, 101);
    final prompt = '${'文' * 78}😀${'文' * 200}';
    await addTask(1, overrides: {'prompt': prompt});
    final entry = (await service.listTasks()).entries.single;
    expect(entry.title, '${'文' * 78}…');
    expect(entry.preview.length, lessThanOrEqualTo(200));
    expect(entry.title.runes, isNot(contains(0xd83d)));
  });
}
