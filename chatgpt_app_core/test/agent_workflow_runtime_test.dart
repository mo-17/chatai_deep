import 'dart:async';
import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late AgentWorkspaceTools workspace;
  late int userId, inputId, privateId;
  late bool foreground;
  late _Transport transport;
  late _Background native;
  final profiles = {
    for (final r in WorkflowRole.values)
      r: WorkflowModelProfile('local', 'fixture', r.name)
  };
  AgentWorkflowScope scope() => AgentWorkflowScope(accountHash: 'a');
  Future<AgentWorkflow> create(
          {int budget = 8,
          bool fullRead = true,
          TaskAcceptanceCriteria? acceptance}) =>
      dao.createFromSource(scope(),
          cid: 1,
          userRowId: userId,
          profiles: profiles,
          inputFileIds: [inputId],
          grantedTools: {'list_files', 'read_file', 'file_search'},
          canReadInputs: true,
          acceptance:
              acceptance ?? TaskAcceptanceCriteria(requireFullRead: fullRead),
          budget: WorkflowBudget(maxDispatches: budget));
  AgentWorkflowRunner run(AgentWorkflow w) => AgentWorkflowRunner(
      dao: dao,
      scope: scope(),
      workflow: w,
      serviceForProfile: (p) async => _Service(transport, p.modelId),
      profileAvailable: (_) async => true,
      foreground: () => foreground,
      background: native,
      workspaceTools: workspace,
      channel: AgentExecutionChannel());
  setUp(() async {
    LoginDao.resetHooksForTest();
    PersonalMemoryTestAccount('a').install();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 1, title: '合成协作', icon: ''));
    userId = await (await MessageDao.create(storage, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: 'PRIVATE_TASK_SENTINEL',
            ownerType: OwnerType.sender,
            createdAt: 10));
    final files = await AgentWorkspaceDao.create(storage, cid: 1);
    inputId = (await files.saveInput(
            name: 'selected.txt',
            sourceKey: 'selected',
            contentHash: workflowHash('选中正文'),
            content: '选中正文',
            pageTexts: [],
            sizeBytes: 12))
        .id;
    privateId = (await files.saveInput(
            name: 'private.txt',
            sourceKey: 'private',
            contentHash: workflowHash('UNSELECTED_SENTINEL'),
            content: 'UNSELECTED_SENTINEL',
            pageTexts: [],
            sizeBytes: 19))
        .id;
    workspace = await AgentWorkspaceTools.create(storage,
        cid: 1, workspace: await AgentWorkspaceService.create(storage, cid: 1));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'a');
    foreground = true;
    transport = _Transport(inputId);
    native = _Background();
  });
  tearDown(() async {
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  test('真实工具断点+独立节点六次dispatch，客观读取通过；同一父原生许可报告0..3', () async {
    final runner = run(await create());
    await runner.start().timeout(const Duration(seconds: 8));
    expect(runner.workflow.state, WorkflowState.complete);
    expect(transport.requests.map((r) => r['model']),
        ['analysis', 'analysis', 'writing', 'writing', 'review', 'review']);
    expect(runner.workflow.dispatches, 6);
    expect(
        (await dao.attemptHistory(runner.workflow.id))
            .every((a) => a['state'] == 'succeeded'),
        true);
    expect(
        (await dao.steps(runner.workflow.id))
            .every((n) => n.toolRounds == 1 && n.checkpoint != null),
        true);
    final report =
        AgentTaskVerificationReport.fromJson(runner.workflow.verification!);
    expect(report.hasChecks, true);
    expect(report.isPassed, true);
    expect((await workspace.store.readIntervals(1, 10, inputId, 1)).length, 3);
    expect(
        jsonEncode(transport.requests), isNot(contains('UNSELECTED_SENTINEL')));
    expect(native.starts.length, 1);
    expect(
        native.updates.map((u) => u['runId']).toSet(), {native.starts.single});
    expect(native.updates.map((u) => u['completed']).toSet(),
        containsAll([0, 1, 2, 3]));
    expect(native.updates.every((u) => u['total'] == 3), true);
    expect(
        jsonEncode(native.updates), isNot(contains('PRIVATE_TASK_SENTINEL')));
    expect(native.stops, 1);
  });
  test('工具授权只显示选中文件，不读取未选中输入或开放写/历史/网络工具', () async {
    transport.forbiddenFile = privateId;
    final runner = run(await create(fullRead: false));
    await runner.start().timeout(const Duration(seconds: 8));
    expect(runner.workflow.state, WorkflowState.complete);
    expect((await workspace.store.readIntervals(1, 10, privateId, 1)), isEmpty);
    expect(
        jsonEncode(transport.requests), isNot(contains('UNSELECTED_SENTINEL')));
    final declared = (transport.requests.first['tools'] as List)
        .map((t) => t['function']['name'])
        .toSet();
    expect(declared, {'list_files', 'read_file', 'file_search'});
    expect(jsonEncode(transport.requests), contains('未获当前节点/输入范围授权'));
  });
  test('单节点两轮工具后第三次请求无工具，异常新调用不能执行', () async {
    transport.alwaysTools = true;
    final runner = run(await create());
    await runner.start().timeout(const Duration(seconds: 8));
    expect(runner.workflow.state, WorkflowState.paused);
    expect(runner.workflow.dispatches, 3);
    expect(transport.requests.length, 3);
    expect(transport.requests.last['tools'], null);
    expect((await workspace.store.readIntervals(1, 10, inputId, 1)).length, 2);
    expect((await dao.steps(runner.workflow.id)).first.toolRounds, 2);
  });
  test('保存工具结果后503已知失败，明确继续复用断点，不重复读取', () async {
    transport.failSecond = true;
    final first = run(await create());
    await first.start().timeout(const Duration(seconds: 8));
    expect(first.workflow.state, WorkflowState.paused);
    expect((await workspace.store.readIntervals(1, 10, inputId, 1)).length, 1);
    transport.failSecond = false;
    final resumed = run(first.workflow);
    await resumed.start().timeout(const Duration(seconds: 8));
    expect(resumed.workflow.state, WorkflowState.complete);
    expect((await workspace.store.readIntervals(1, 10, inputId, 1)).length, 3);
    expect(transport.requests.where((r) => r['model'] == 'analysis').length, 3);
    expect(resumed.workflow.dispatches, 7);
  });
  test('坏流式审阅保留原结果与扣用，明确继续仅重发review，不重播坏checkpoint', () async {
    transport.badReview = true;
    final first = run(await create());
    await first.start().timeout(const Duration(seconds: 8));
    expect(first.workflow.state, WorkflowState.paused);
    final attempts = await dao.attemptHistory(first.workflow.id);
    expect(attempts.where((a) => a['state'] == 'failed').single['result'],
        'bad-json');
    expect(first.workflow.dispatches, 6);
    transport.badReview = false;
    final resumed = run(first.workflow);
    await resumed.start().timeout(const Duration(seconds: 8));
    expect(resumed.workflow.state, WorkflowState.complete);
    expect(transport.requests.where((r) => r['model'] == 'analysis').length, 2);
    expect(transport.requests.where((r) => r['model'] == 'writing').length, 2);
    expect(transport.requests.where((r) => r['model'] == 'review').length, 3);
    expect(resumed.workflow.dispatches, 7);
  });
  test('模型accept及待办不能替代实际读取，最多返工一次后等待处理', () async {
    transport.skipReads = true;
    final runner = run(await create());
    await runner.start().timeout(const Duration(seconds: 8));
    expect(runner.workflow.state, WorkflowState.waitingConfirmation);
    expect(runner.workflow.reworks, 1);
    expect(runner.workflow.dispatches, 5);
    expect(runner.workflow.verification!['isPassed'], false);
    expect(
        (await dao.steps(runner.workflow.id))
            .every((n) => n.state == WorkflowState.complete),
        true);
  });
  test('原生update许可失效不启动下一节点，不重新申请刷新期限', () async {
    final runner = run(await create());
    native.afterUpdate = (completed) async {
      if (completed == 1 && native.active) {
        foreground = false;
        native.active = false;
        await native.interrupted!('expired');
      }
    };
    await runner.start().timeout(const Duration(seconds: 8));
    expect(transport.requests.map((r) => r['model']).toSet(), {'analysis'});
    expect(runner.workflow.state, WorkflowState.paused);
    expect(native.starts.length, 1);
    expect(native.stops, 1);
  });
  test('来源删除后迟到工具调用不读不写，不污染同号新消息', () async {
    transport.beforeEvents = () async {
      await storage.db
          .delete('tb_messages', where: 'id=?', whereArgs: [userId]);
    };
    final runner = run(await create());
    await runner.start().timeout(const Duration(seconds: 8));
    expect(await dao.read(runner.workflow.id), null);
    expect(await storage.db.query('tb_agent_read_interval'), isEmpty);
    expect(transport.requests.length, 1);
  });
  test('工具多轮累计输出不能每轮重置12000字符额度', () async {
    transport.largeToolText = true;
    final runner = run(await create());
    await runner.start().timeout(const Duration(seconds: 8));
    expect(runner.workflow.state, WorkflowState.paused);
    expect(transport.requests.length, 2);
    expect(runner.workflow.dispatches, 2);
    final attempts = await dao.attemptHistory(runner.workflow.id);
    expect((attempts.first['result'] as String).length, 7000);
    expect(attempts.last['state'], 'unknown');
    expect((await dao.steps(runner.workflow.id)).first.state,
        WorkflowState.paused);
    await run(runner.workflow).start().timeout(const Duration(seconds: 8));
    expect(transport.requests.length, 2); // 不重放结果不明请求。
  });
  test('模型审阅不算文件交付，前台确认保存后真实验收与回复只发布一次', () async {
    transport.skipReads = true;
    final runner = run(await create(
        acceptance: const TaskAcceptanceCriteria(
            expectedOutputNames: ['result.md'],
            requiredTerms: ['writing-result'],
            requireFullRead: false)));
    await runner.start().timeout(const Duration(seconds: 8));
    var task = runner.workflow;
    expect(task.state, WorkflowState.waitingConfirmation);
    expect(transport.requests.length, 3);
    expect(
        await storage.db
            .query(AgentWorkspaceDao.filesTable, where: "kind='output'"),
        isEmpty);
    final id = await dao.publishOutputOnce(scope(), task, name: 'result.md');
    expect(await dao.publishOutputOnce(scope(), task, name: 'result.md'), id);
    await workspace.beginTurn(10, [], resume: true);
    final report = await workspace.verify();
    expect(report.isPassed, true);
    task = await dao.acceptVerification(scope(), task, report);
    expect(task.state, WorkflowState.complete);
    final reply = await dao.publishReplyOnce(scope(), task.id, task.revision,
        createdAt: 20);
    expect(
        await dao.publishReplyOnce(scope(), task.id, task.revision,
            createdAt: 21),
        reply);
    expect(await storage.db.query(AgentWorkflowDao.outputPublications),
        hasLength(1));
    expect(
        await storage.db.query('tb_messages',
            where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]),
        hasLength(1));
    expect(transport.requests.length, 3);
    await (await AgentWorkspaceDao.create(storage, cid: 1)).saveOutput(
        fileId: id,
        name: 'result.md',
        content: '用户修改',
        contentHash: workflowHash('用户修改'),
        sizeBytes: 12,
        note: '合成修改');
    await expectLater(dao.publishOutputOnce(scope(), task, name: 'result.md'),
        throwsA(isA<WorkflowStale>()));
  });
  test('成果账本写失败回滚新文件、版本和验收来源，成功任务保留', () async {
    transport.skipReads = true;
    final runner = run(await create(fullRead: false));
    await runner.start().timeout(const Duration(seconds: 8));
    final before = await storage.db.query('tb_agent_verification_turn');
    await storage.db.execute('''CREATE TRIGGER fail_publication BEFORE INSERT ON
      ${AgentWorkflowDao.outputPublications} BEGIN SELECT RAISE(ABORT,'fixture_failure'); END''');
    await expectLater(
        dao.publishOutputOnce(scope(), runner.workflow, name: 'result.txt'),
        throwsA(isA<DatabaseException>()));
    expect(
        await storage.db
            .query(AgentWorkspaceDao.filesTable, where: "kind='output'"),
        isEmpty);
    expect(
        await storage.db.query(AgentWorkflowDao.outputPublications), isEmpty);
    expect(await storage.db.query('tb_agent_verification_turn'), before);
    expect((await dao.read(runner.workflow.id))!.state, WorkflowState.complete);
    expect(transport.requests.length, 3);
  });
  test('覆盖成果须匹配确认时的真实版本，旧目标变化不得覆盖', () async {
    transport.skipReads = true;
    final runner = run(await create(fullRead: false));
    await runner.start().timeout(const Duration(seconds: 8));
    final files = await AgentWorkspaceDao.create(storage, cid: 1);
    final original = await files.saveOutput(
        name: 'result.txt',
        content: '旧成果',
        contentHash: workflowHash('旧成果'),
        sizeBytes: 9,
        note: '合成旧成果');
    final changed = await files.saveOutput(
        fileId: original.id,
        name: 'result.txt',
        content: '新版本',
        contentHash: workflowHash('新版本'),
        sizeBytes: 9,
        note: '合成新版本');
    await expectLater(
        dao.publishOutputOnce(scope(), runner.workflow,
            name: 'result.txt',
            expectedFileId: original.id,
            expectedRevision: original.revision),
        throwsA(isA<WorkflowStale>()));
    expect((await files.getFile(original.id))!.revision, changed.revision);
    expect(
        await storage.db.query(AgentWorkflowDao.outputPublications), isEmpty);
    final published = await dao.publishOutputOnce(scope(), runner.workflow,
        name: 'result.txt',
        expectedFileId: changed.id,
        expectedRevision: changed.revision);
    expect(published, original.id);
    expect((await files.getFile(published))!.revision, changed.revision + 1);
    expect(transport.requests.length, 3);
  });
}

class _Transport {
  final int fileId;
  _Transport(this.fileId);
  final requests = <Map<String, dynamic>>[];
  bool failSecond = false,
      badReview = false,
      alwaysTools = false,
      skipReads = false,
      largeToolText = false;
  int? forbiddenFile;
  Future<void> Function()? beforeEvents;
}

class _Service
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService,
        OptionsAwareChatService {
  final _Transport t;
  final String model;
  _Service(this.t, this.model);
  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    final messages = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt},
      ...extraMessages
    ]);
    t.requests.add({
      'model': model,
      'messages': messages,
      'tools': tools,
      'max_tokens': options.maxOutputTokensOverride
    });
    await t.beforeEvents?.call();
    if (t.failSecond && t.requests.length == 2) {
      throw const ChatTransportException(
          statusCode: 503, safeCode: 'http_503', safeMessage: '合成503');
    }
    final hasResult = extraMessages.any((m) => m['role'] == 'tool');
    if (t.largeToolText) {
      yield StreamEvent.text(List.filled(7000, 'x').join());
    }
    if (!t.skipReads && (!hasResult || t.alwaysTools)) {
      yield StreamEvent.toolCall(
          toolId: 'call_${t.requests.length}',
          name: 'read_file',
          arguments: {'file_id': t.forbiddenFile ?? t.fileId});
    } else {
      yield StreamEvent.text(model == 'review'
          ? (t.badReview
              ? 'bad-json'
              : '{"decision":"accept","feedback":"模型意见"}')
          : '$model-result');
    }
    yield StreamEvent.usage(promptTokens: 10, completionTokens: 5);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Background implements AgentBackgroundExecution {
  final starts = <String>[];
  final updates = <Map<String, dynamic>>[];
  int stops = 0;
  bool active = false;
  Future<void> Function(String)? interrupted;
  Future<void> Function(int)? afterUpdate;
  @override
  Future<AgentBackgroundCapabilities> capabilities() async =>
      const AgentBackgroundCapabilities(supported: true);
  @override
  Future<AgentBackgroundStartResult> start(
      {required String runId,
      required int cid,
      required String title,
      required Future<void> Function(String) onInterrupted}) async {
    starts.add(runId);
    interrupted = onInterrupted;
    active = true;
    return const AgentBackgroundStartResult(active: true);
  }

  @override
  bool isActive(String runId) => active && starts.last == runId;
  @override
  Future<void> update(
      {required String runId,
      required int completed,
      required int total,
      required String status}) async {
    updates.add({
      'runId': runId,
      'completed': completed,
      'total': total,
      'status': status
    });
    await afterUpdate?.call(completed);
  }

  @override
  Future<void> stop({required String runId, bool success = false}) async {
    active = false;
    stops++;
  }
}
