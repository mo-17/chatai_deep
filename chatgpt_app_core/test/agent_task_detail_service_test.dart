import 'dart:async';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_detail_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/agent_verification_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('old ordinary conversation returns null without creating task tables',
      () async {
    final db = await _database();
    final manager = HiDBManager.test(db);
    final conversations = await ConversationListDao.create(manager);
    await conversations.saveConversation(
        ConversationModel(cid: 7, title: '原普通对话', icon: '🤖'));
    final before =
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
    final service = await AgentTaskDetailService.create(manager);
    expect(await service.loadDetail(7), isNull);
    expect(
        await service.conversationForResume(7,
            userCreatedAt: 100, generation: 0),
        isNull);
    expect(
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'"),
        before);
    final store = await AgentTaskDao.create(manager);
    await store.write(7, {'enabled': true, 'version': 1});
    expect(await service.loadDetail(7), isNull);
  });

  test(
      'full todos and paired result metadata are read without exposing protocol payloads',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(
        7,
        _snapshot(messages: [
          _declarations(['read-1', 'write-1', 'unknown-1']),
          {
            'role': 'tool',
            'tool_call_id': 'read-1',
            'content': 'PRIVATE_READ_TEXT'
          },
          {
            'role': 'tool',
            'tool_call_id': 'write-1',
            'content': '工具错误：PRIVATE_RESULT'
          },
          {
            'role': 'tool',
            'tool_call_id': 'unknown-1',
            'content': _unknownResult
          },
          {'role': 'tool', 'tool_call_id': 'orphan', 'content': '不能计入配对'},
        ], executing: 'unknown-1'));
    final detail = (await fixture.service.loadDetail(7))!;
    expect(
        detail.todos.map((todo) => todo.content), ['阅读全部原文', '写入成果', '验收成果']);
    expect(detail.nextRound, 3);
    expect(detail.generation, 4);
    expect(detail.canResume, isTrue);
    expect(detail.pairedToolResultCount, 2, reason: '错误/拒绝也属于已有结果，不能称为业务成功');
    expect(
        detail.pairedTools.map((tool) => tool.toolId), ['read-1', 'write-1']);
    expect(detail.pairedTools.map((tool) => tool.name),
        ['read_file', 'write_file']);
    expect(detail.uncertainTools.single.toolId, 'unknown-1');
    expect(detail.pendingApproval, isNull, reason: '持久执行标识不能冒充实时待审批');
    expect(() => detail.todos.add(const AgentTodo('修改详情', 'pending')),
        throwsUnsupportedError);
  });

  test(
      'resume and pause identity revalidate generation and real latest user row',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(7, _snapshot());
    expect(
        await fixture.service
            .validateIdentity(7, userCreatedAt: 100, generation: 4),
        isTrue);
    expect(
        (await fixture.service
                .conversationForResume(7, userCreatedAt: 100, generation: 4))
            ?.cid,
        7);
    await fixture.store.write(7, {..._snapshot(), 'generation': 5});
    expect(
        await fixture.service
            .validateIdentity(7, userCreatedAt: 100, generation: 4),
        isFalse);
    expect(
        await fixture.service
            .conversationForResume(7, userCreatedAt: 100, generation: 4),
        isNull);
    await fixture.messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, createdAt: 101, content: '新的用户输入'));
    final detail = (await fixture.service.loadDetail(7))!;
    expect(detail.latestUserMatches, isFalse);
    expect(detail.canResume, isFalse);
    expect(detail.pauseReason, contains('新的用户输入'));
    expect(
        await fixture.service
            .validateIdentity(7, userCreatedAt: 100, generation: 5),
        isFalse);
    expect(
        await fixture.service
            .conversationForResume(7, userCreatedAt: 100, generation: 5),
        isNull);
  });

  test(
      'outputs and report belong to this exact turn and preserve historical revisions',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(7, _snapshot());
    final workspace =
        await AgentWorkspaceService.create(fixture.manager, cid: 7);
    final first = await workspace.writeFile(name: '成果.txt', content: '旧版实际成果');
    final verification = await AgentVerificationDao.create(fixture.manager);
    await verification
        .beginTurn(7, 100, {'inputIds': [], 'outputs': {}, 'criteria': {}});
    await verification.saveOutput(7, 100, first.id, first.revision);
    final report = AgentTaskVerificationReport(
        cid: 7,
        userCreatedAt: 100,
        createdAt: 200,
        checks: [
          AgentVerificationCheck(
              label: '成果检查',
              passed: true,
              detail: '历史版本通过',
              fileId: first.id,
              revision: 1)
        ]);
    await verification.saveReport(7, 100, report.toJson());
    await verification
        .beginTurn(7, 99, {'inputIds': [], 'outputs': {}, 'criteria': {}});
    final other =
        await workspace.writeFile(name: '别轮.txt', content: '不能冒充本轮成果');
    await verification.saveOutput(7, 99, other.id, other.revision);
    await verification.saveReport(
        7,
        99,
        (const AgentTaskVerificationReport(
            cid: 7, userCreatedAt: 99, createdAt: 999, checks: [])).toJson());
    final current = (await fixture.service.loadDetail(7))!;
    expect(current.outputs.single.name, '成果.txt');
    expect(current.verificationReport?.userCreatedAt, 100);
    expect(current.verificationIsCurrent, isTrue);
    await workspace.writeFile(
        fileId: first.id, name: first.name, content: '更新后的实际成果');
    final historical = (await fixture.service.loadDetail(7))!;
    expect(historical.outputs.single.revision, 1);
    expect(historical.outputs.single.currentRevision, 2);
    expect(historical.outputs.single.available, isTrue);
    expect(historical.outputs.single.isCurrent, isFalse);
    expect(historical.verificationReport?.checks.single.detail, '历史版本通过');
    expect(historical.verificationIsCurrent, isFalse);
    await fixture.manager.db.delete('tb_agent_workspace_revisions',
        where: 'fileId=? AND revision=?', whereArgs: [first.id, 1]);
    expect((await fixture.service.loadDetail(7))!.outputs.single.available,
        isFalse);
    await fixture.manager.db.delete('tb_agent_verification_report',
        where: 'cid=? AND userCreatedAt=?', whereArgs: [7, 100]);
    expect((await fixture.service.loadDetail(7))!.verificationReport, isNull,
        reason: '本轮报告缺失时不能使用别轮 latest 报告');
  });

  test(
      'foreign file ids and report internal identity never leak another conversation',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(7, _snapshot());
    final foreign = await AgentWorkspaceService.create(fixture.manager, cid: 9);
    final output = await foreign.writeFile(name: '私有其他对话.txt', content: '私有正文');
    final verification = await AgentVerificationDao.create(fixture.manager);
    await verification.beginTurn(7, 100, {
      'inputIds': [],
      'outputs': {'${output.id}': 1},
      'criteria': {}
    });
    await verification.saveReport(
        7,
        100,
        (const AgentTaskVerificationReport(
            cid: 9, userCreatedAt: 100, createdAt: 200, checks: [])).toJson());
    final detail = (await fixture.service.loadDetail(7))!;
    expect(detail.outputs.single.available, isFalse);
    expect(detail.outputs.single.name, '文件 ${output.id}');
    expect(detail.verificationReport, isNull);
  });

  test(
      'report file ids need version evidence and empty reports still need exact turn identity',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(7, _snapshot());
    final workspace =
        await AgentWorkspaceService.create(fixture.manager, cid: 7);
    final output = await workspace.writeFile(name: '成果.txt', content: '实际成果');
    final verification = await AgentVerificationDao.create(fixture.manager);
    final expected = AgentVerificationCheck(
        label: '预期输出', passed: true, detail: '旧报告缺版本', fileId: output.id);
    Future<void> save(List<AgentVerificationCheck> checks,
            {int reportUserAt = 100}) =>
        verification.saveReport(
            7,
            100,
            AgentTaskVerificationReport(
                    cid: 7,
                    userCreatedAt: reportUserAt,
                    createdAt: 200,
                    checks: checks)
                .toJson());
    await save([expected]);
    expect(
        (await fixture.service.loadDetail(7))!.verificationIsCurrent, isFalse);
    await save([
      expected,
      AgentVerificationCheck(
          label: '输出版本',
          passed: true,
          detail: '同文件版本证据',
          fileId: output.id,
          revision: output.revision)
    ]);
    expect((await fixture.service.loadDetail(7))!.verificationIsCurrent, isTrue,
        reason: '正常预期输出检查可由同文件的版本检查补充证据');
    await save(const []);
    expect(
        (await fixture.service.loadDetail(7))!.verificationIsCurrent, isTrue);
    await save(const [], reportUserAt: 99);
    final wrongTurn = (await fixture.service.loadDetail(7))!;
    expect(wrongTurn.verificationReport, isNull);
    expect(wrongTurn.verificationIsCurrent, isFalse);
  });

  test('input cannot be an output receipt but remains valid report evidence',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(7, _snapshot());
    final workspace =
        await AgentWorkspaceService.create(fixture.manager, cid: 7);
    final input = await workspace.importText(name: '输入.txt', content: '实际输入');
    final verification = await AgentVerificationDao.create(fixture.manager);
    await verification.beginTurn(7, 100, {
      'inputIds': [input.id],
      'outputs': {},
      'criteria': {}
    });
    await verification.saveReport(
        7,
        100,
        AgentTaskVerificationReport(
            cid: 7,
            userCreatedAt: 100,
            createdAt: 200,
            checks: [
              AgentVerificationCheck(
                  label: '输入阅读',
                  passed: true,
                  detail: '本轮阅读证据',
                  fileId: input.id,
                  revision: input.revision)
            ]).toJson());
    expect(
        (await fixture.service.loadDetail(7))!.verificationIsCurrent, isTrue);
    await verification.saveOutput(7, 100, input.id, input.revision);
    final invalid = (await fixture.service.loadDetail(7))!;
    expect(invalid.outputs.single.available, isFalse);
    expect(invalid.verificationIsCurrent, isFalse);
  });

  test(
      'legacy system protocol and nullable content load; malformed parameters cannot resume',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(
        7,
        _snapshot(messages: [
          {'role': 'system', 'content': '旧系统上下文'},
          {'role': 'assistant', 'content': null, 'tool_calls': []},
        ]));
    expect((await fixture.service.loadDetail(7))!.canResume, isTrue);
    final malformed = _declarations(['write-1']);
    ((malformed['tool_calls'] as List).single['function'] as Map)['arguments'] =
        '坏JSON';
    await fixture.store.write(7, _snapshot(messages: [malformed]));
    final invalid = (await fixture.service.loadDetail(7))!;
    expect(invalid.snapshotValid, isFalse);
    expect(invalid.canResume, isFalse);
  });

  test('malformed optional fields are safely viewable and cannot resume',
      () async {
    final fixture = await _fixture();
    await fixture.store.write(7, {
      ..._snapshot(),
      'status': 17,
      'executingToolId': {},
      'generation': '坏字段',
      'failureDiagnosis': {
        'version': 1,
        'code': 'unknown-secret-code',
        'message': 'PRIVATE_SECRET'
      }
    });
    final detail = (await fixture.service.loadDetail(7))!;
    expect(detail.snapshotValid, isFalse);
    expect(detail.canResume, isFalse);
    expect(detail.hasConversation, isTrue);
    expect(detail.failureDiagnosis, isNull);
    expect(detail.pendingApproval, isNull);
    await fixture.store.write(7, {..._snapshot(), 'status': 'running'});
    final interrupted = (await fixture.service.loadDetail(7))!;
    expect(interrupted.status, 'paused');
    expect(interrupted.interrupted, isTrue);
    expect(interrupted.canResume, isTrue);
    expect(interrupted.pauseReason, contains('保存'));
  });

  test('legacy conversation missing optional fields remains resumable',
      () async {
    final db = await _database();
    final manager = HiDBManager.test(db);
    await db
        .execute('CREATE TABLE tb_conversation_list (cid INTEGER, title TEXT)');
    await db.insert('tb_conversation_list', {'cid': 7, 'title': '旧版对话'});
    final messages = await MessageDao.create(manager, cid: 7);
    await messages.saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender, createdAt: 100, content: '旧版任务'));
    final store = await AgentTaskDao.create(manager);
    await store.write(7, _snapshot());
    final service = await AgentTaskDetailService.create(manager);
    final detail = (await service.loadDetail(7))!;
    expect(detail.hasConversation, isTrue);
    expect(detail.canResume, isTrue);
    expect(detail.conversation?.icon, '🤖');
    expect(detail.conversation?.stickTime, 0);
  });

  test('same cid in separate injected account databases remains isolated',
      () async {
    final a = await _fixture();
    final b = await _fixture();
    await a.store.write(7, {..._snapshot(), 'prompt': '账户 A 任务'});
    await b.store.write(7, {..._snapshot(), 'prompt': '账户 B 任务'});
    expect((await a.service.loadDetail(7))!.prompt, '账户 A 任务');
    expect((await b.service.loadDetail(7))!.prompt, '账户 B 任务');
    await a.manager.db
        .delete('tb_conversation_list', where: 'cid=?', whereArgs: [7]);
    expect((await a.service.loadDetail(7))!.canResume, isFalse);
    expect((await b.service.loadDetail(7))!.canResume, isTrue);
  });

  test(
      'active session overrides stale SQLite and exposes actual awaiting approval',
      () async {
    var account = 'A';
    final executor = AgentTaskExecutor(
        currentAccount: () => account, observeApplication: false);
    final fixture = await _fixture(executor: executor);
    final session = AgentTaskSession(cid: 7, store: fixture.store);
    await session.setEnabled(true);
    await session.begin(userAt: 100, input: '真实当前任务');
    final workspace =
        await AgentWorkspaceService.create(fixture.manager, cid: 7);
    final workspaceTools = await AgentWorkspaceTools.create(fixture.manager,
        cid: 7, workspace: workspace);
    await workspaceTools.beginTurn(100, const []);
    final entered = Completer<void>();
    final approval = Completer<bool>();
    const key = AgentTaskKey('A', 7);
    executor.bindConfirmation(key, Object(),
        visible: () => true,
        confirm: (_, __) {
          entered.complete();
          return approval.future;
        },
        dismiss: () {});
    final chat = _ToolService();
    final settings = AISettings.defaults()..streamEnabled = true;
    final prepared = PreparedAgentRun(
        key: key,
        conversation: fixture.conversation,
        user: MessageModel(
            ownerType: OwnerType.sender, createdAt: 100, content: '真实当前任务'),
        receiver: MessageModel(
            ownerType: OwnerType.receiver, createdAt: 200, content: ''),
        settings: settings,
        completion: CompletionDao(
            settings: settings, chatService: chat, messages: const []),
        messages: fixture.messages,
        usage: UsageRecordService(await UsageDao.create(fixture.manager)),
        session: session,
        workspace: workspace,
        workspaceTools: workspaceTools,
        attachments: const ChatAttachments(),
        background: _NoBackground(),
        tools: ToolRegistry([
          ChatTool(
              name: 'write_file',
              description: '测试审批元数据',
              parameters: const {'type': 'object'},
              execute: (_) async => ToolOutcome(
                  content: await executor.confirm(key, '写入输出', '确认测试')
                      ? '允许'
                      : '拒绝'))
        ]));
    addTearDown(() async {
      await executor.cancelAll('测试完成').timeout(const Duration(seconds: 2));
      executor.dispose();
      session.dispose();
    });
    await executor.enqueue(prepared);
    await entered.future.timeout(const Duration(seconds: 2));
    session.todos = const [AgentTodo('实时清单', 'in_progress')];
    await fixture.store.write(7, _snapshot()); // 模拟比 live checkpoint 更早的落库视图。
    final detail = (await fixture.service.loadDetail(7))!;
    expect(detail.status, 'running');
    expect(detail.generation, session.generation);
    expect(detail.todos.single.content, '实时清单');
    expect(detail.pendingApproval?.name, 'write_file');
    expect(detail.pendingApproval?.toolId, 'pending-write');
    expect(detail.uncertainTools, isEmpty);
    expect(detail.canResume, isFalse);
    expect(chat.requests, 1);
    account = 'B';
    expect((await fixture.service.loadDetail(7))!.todos.length, 3,
        reason: '账号变化后不混入旧 executor 的 live 内容');
    await executor.cancelAll('账户变化');
    expect(chat.requests, 1, reason: '详情查询没有发起模型请求');
  });
}

const _unknownResult = '此工具在中断前可能已执行，结果未保存。请用户核对；禁止自动重复此操作。';

Map<String, dynamic> _declarations(List<String> ids) => {
      'role': 'assistant',
      'content': 'PRIVATE_ANSWER',
      'reasoning_content': 'PRIVATE_REASONING',
      'tool_calls': [
        for (final id in ids)
          {
            'id': id,
            'type': 'function',
            'function': {
              'name': id == 'read-1' ? 'read_file' : 'write_file',
              'arguments': '{"content":"PRIVATE_PARAMS"}'
            }
          }
      ]
    };

Map<String, dynamic> _snapshot(
        {List<Map<String, dynamic>> messages = const [], String? executing}) =>
    {
      'version': 1,
      'enabled': true,
      'backgroundEnabled': true,
      'status': 'paused',
      'prompt': '当前文件任务',
      'userCreatedAt': 100,
      'generation': 4,
      'nextRound': 3,
      'todos': const [
        {'content': '阅读全部原文', 'status': 'completed'},
        {'content': '写入成果', 'status': 'in_progress'},
        {'content': '验收成果', 'status': 'pending'}
      ],
      'messages': messages,
      'executingToolId': executing,
      'pauseReason': '已保存进度，可明确继续',
    };

Future<Database> _database() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
  addTearDown(db.close);
  return db;
}

class _Fixture {
  final HiDBManager manager;
  final AgentTaskDao store;
  final MessageDao messages;
  final ConversationModel conversation;
  final AgentTaskDetailService service;
  const _Fixture(
      this.manager, this.store, this.messages, this.conversation, this.service);
}

Future<_Fixture> _fixture({AgentTaskExecutor? executor}) async {
  final manager = HiDBManager.test(await _database());
  final conversation = ConversationModel(cid: 7, title: '详情测试任务', icon: '🤖');
  final conversations = await ConversationListDao.create(manager);
  await conversations.saveConversation(conversation);
  final messages = await MessageDao.create(manager, cid: 7);
  await messages.saveMessageWithBlocks(MessageModel(
      ownerType: OwnerType.sender, createdAt: 100, content: '当前文件任务'));
  final store = await AgentTaskDao.create(manager);
  return _Fixture(
      manager,
      store,
      messages,
      conversation,
      await AgentTaskDetailService.create(manager,
          accountHash: 'A', executor: executor));
}

class _ToolService implements ChatService {
  int requests = 0;
  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);
  @override
  Stream<StreamEvent> chatStreamEvents(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const []}) async* {
    requests++;
    yield StreamEvent.toolCall(
        toolId: 'pending-write', name: 'write_file', arguments: const {});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoBackground implements AgentBackgroundExecution {
  @override
  Future<AgentBackgroundStartResult> start(
          {required String runId,
          required int cid,
          required String title,
          required Future<void> Function(String reason) onInterrupted}) async =>
      const AgentBackgroundStartResult(active: false);
  @override
  bool isActive(String runId) => false;
  @override
  Future<void> stop({required String runId, bool success = false}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
