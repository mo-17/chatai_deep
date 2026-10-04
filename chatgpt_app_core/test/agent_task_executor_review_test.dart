import 'dart:async';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_failure_diagnosis.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
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

  test('失败运行将安全诊断保存在真实SQLite任务快照中', () async {
    final executor =
        AgentTaskExecutor(currentAccount: () => 'A', observeApplication: false);
    final service = _Service(const [],
        failure: const ChatTransportException(
            safeCode: 'insufficient_balance',
            safeMessage: 'SECRET provider response',
            statusCode: 402,
            failureStage: ChatFailureStage.response,
            failureKind: ChatFailureKind.httpStatus));
    final fixture = await _fixture(executor, service);
    addTearDown(executor.dispose);
    final run = await executor.enqueue(fixture.prepared);
    await run.finished.timeout(const Duration(seconds: 2));
    final reopened =
        AgentTaskSession(cid: 7, store: fixture.prepared.session.store);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(run.phase, AgentRunPhase.paused);
    expect(reopened.failureDiagnosis!.code, 'insufficient_balance');
    expect(reopened.failureDiagnosis!.action, ChatFailureAction.checkBalance);
    expect(reopened.failureDiagnosis!.statusCode, 402);
    expect(reopened.pauseReason, isNot(contains('SECRET')));
    expect(service.requests, 1);
  });

  test('取消恢复中的任务清掉旧诊断，迟到错误不覆盖用户暂停原因', () async {
    final executor =
        AgentTaskExecutor(currentAccount: () => 'A', observeApplication: false);
    final errorGate = Completer<void>();
    final service = _Service(const [],
        failureGate: errorGate.future,
        failure: const ChatTransportException(
            safeCode: 'authentication_error',
            safeMessage: '',
            statusCode: 401));
    final fixture = await _fixture(executor, service);
    addTearDown(executor.dispose);
    await fixture.prepared.session.pause('旧余额不足',
        diagnosis: ChatFailureDiagnosis.from(const ChatTransportException(
            safeCode: 'insufficient_balance',
            safeMessage: '',
            statusCode: 402)));
    final run = await executor.enqueue(fixture.prepared);
    await service.started.future.timeout(const Duration(seconds: 2));
    expect(fixture.prepared.session.failureDiagnosis, isNull);
    await executor.cancel(fixture.prepared.key, reason: '用户已停止');
    await run.finished.timeout(const Duration(seconds: 2));
    errorGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final snapshot = await fixture.prepared.session.store.read(7);
    expect(snapshot!['failureDiagnosis'], isNull);
    expect(snapshot['pauseReason'], '用户已停止');
    expect(service.requests, 1);
  });

  test(
      'logout during slow admission never sends or returns a disposed observable to the page',
      () async {
    var account = 'A';
    final executor = AgentTaskExecutor(
        currentAccount: () => account, observeApplication: false);
    final service = _Service([StreamEvent.text('不应发送')]);
    final fixture = await _fixture(executor, service);
    final store = _GateStore(fixture.prepared.session.store)..blockNext = true;
    final session =
        AgentTaskSession(cid: fixture.prepared.key.cid, store: store);
    await session.load();
    final prepared = _withSession(fixture.prepared, session);
    var observed = false;
    // LogoutReadyHook 执行时账号 token 尚未清除；页面此时仍通过 accountCurrent。
    final admission = executor.enqueue(prepared).then((run) {
      if (account == 'A' && !run.isRetired) {
        run.addListener(() {}); // 与 Page._bindAgentRun 相同的公开订阅动作。
        observed = true;
      }
      return run;
    });
    await store.entered.future.timeout(const Duration(seconds: 2));
    final logout = executor.cancelAll('退出账户，任务已暂停');
    store.release.complete();
    await logout.timeout(const Duration(seconds: 2));
    final run = await admission.timeout(const Duration(seconds: 2));
    account = 'B';
    expect(run.isRetired, isTrue);
    expect(observed, isFalse, reason: '取消的排队项不能重新绑定旧页面');
    expect(run.busy, isFalse);
    expect(executor.lookup(prepared.key), isNull);
    expect(service.requests, 0);
    expect(fixture.background.starts, 0);
    final saved = await store.read(prepared.key.cid);
    expect(saved!['status'], 'paused');
    expect(saved['pauseReason'], contains('退出'));
    final messages = await fixture.prepared.messages.getAllMessage();
    expect(
        messages.where((m) => m.ownerType == OwnerType.sender), hasLength(1));
    expect(messages.where((m) => m.ownerType == OwnerType.receiver), isEmpty);
    session.dispose();
    executor.dispose();
  });

  test(
      'cancel and account switch release pending approval; late true cannot write original or new account',
      () async {
    var account = 'A';
    final executor = AgentTaskExecutor(
        currentAccount: () => account, observeApplication: false);
    final service = _Service([
      StreamEvent.toolCall(
          toolId: 'write-1',
          name: 'write_file',
          arguments: const {
            'name': 'forbidden.txt',
            'content': '迟到审批不得创建此文件',
          }),
    ]);
    final fixture =
        await _fixture(executor, service, exposeWorkspaceTools: true);
    final pendingApproval = Completer<bool>();
    final dialogEntered = Completer<void>();
    var dismissed = 0;
    executor.bindConfirmation(fixture.prepared.key, Object(),
        visible: () => true,
        confirm: (_, __) {
          dialogEntered.complete();
          return pendingApproval.future;
        },
        dismiss: () => dismissed++);
    final run = await executor.enqueue(fixture.prepared);
    await dialogEntered.future.timeout(const Duration(seconds: 2));
    account = 'B';
    await executor.cancelAll('账户已切换').timeout(const Duration(seconds: 2));
    await run.finished.timeout(const Duration(seconds: 2));
    expect(dismissed, greaterThan(0));
    expect(fixture.background.stops, 1);
    expect(await fixture.prepared.workspace.listFiles(), isEmpty);
    expect(
        (await fixture.prepared.session.store
            .read(fixture.prepared.key.cid))!['status'],
        'paused');
    pendingApproval.complete(true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await fixture.prepared.workspace.listFiles(), isEmpty);
    final savedBlocks = await fixture.prepared.messages
        .getBlocksByCreatedAt([fixture.prepared.receiver.createdAt]);
    final writeBlock = MessageBlock.decodeList(savedBlocks[run.messageKey])
        .whereType<ToolBlock>()
        .singleWhere((block) => block.toolId == 'write-1');
    expect(writeBlock.toolName, 'write_file');
    expect(writeBlock.status, MessageBlockStatus.paused,
        reason: '取消时尚未执行的工具不能在历史回复中显示成功');
    expect(writeBlock.content, isNull, reason: '等待审批时取消，没有成功写入结果；迟到允许也不得补写结果');
    expect(service.requests, 1, reason: '取消后不得开启下一轮收费请求');
    expect(executor.lookup(fixture.prepared.key), isNull);
    executor.dispose();
  });

  test(
      'restore maintenance rejects new admission and releases its guard when restore fails',
      () async {
    final executor =
        AgentTaskExecutor(currentAccount: () => 'A', observeApplication: false);
    final service = _Service([StreamEvent.text('维护失败后仍能执行')]);
    final fixture = await _fixture(executor, service);
    final entered = Completer<void>();
    final release = Completer<void>();
    final maintenance =
        executor.runWithTasksPaused<void>('A', '导入备份', () async {
      entered.complete();
      await release.future;
      throw StateError('导入内容无效');
    });
    // 预先监听预期错误，避免受控 release 后出现未处理的异步错误。
    final maintenanceExpectation = expectLater(maintenance, throwsStateError);
    await entered.future.timeout(const Duration(seconds: 2));
    await expectLater(executor.enqueue(fixture.prepared), throwsStateError);
    expect(executor.lookup(fixture.prepared.key), isNull);
    expect(service.requests, 0);
    expect(fixture.background.starts, 0);
    release.complete();
    await maintenanceExpectation;
    final run = await executor.enqueue(fixture.prepared);
    await run.finished.timeout(const Duration(seconds: 2));
    expect(run.phase, AgentRunPhase.complete);
    expect(service.requests, 1);
    expect(fixture.background.stops, 1);
    expect(
        (await fixture.prepared.messages.getAllMessage())
            .where((message) => message.ownerType == OwnerType.receiver)
            .single
            .content,
        '维护失败后仍能执行');
    await executor.cancelAll('测试结束');
    executor.dispose();
  });

  test('approved write cannot overwrite restored workspace after maintenance',
      () async {
    final executor =
        AgentTaskExecutor(currentAccount: () => 'A', observeApplication: false);
    final service = _Service([
      StreamEvent.toolCall(
          toolId: 'approved-write',
          name: 'write_file',
          arguments: const {
            'name': 'restored.txt',
            'content': '恢复前旧任务的迟到内容',
          }),
    ]);
    late _OutputGateDatabase gate;
    final fixture = await _fixture(executor, service,
        exposeWorkspaceTools: true,
        workspaceDatabase: (db) => gate = _OutputGateDatabase(db));
    gate.blockNextOutput = true;
    executor.bindConfirmation(fixture.prepared.key, Object(),
        visible: () => true, confirm: (_, __) async => true, dismiss: () {});
    addTearDown(() async {
      if (!gate.release.isCompleted) gate.release.complete();
      await executor.cancelAll('测试结束').timeout(const Duration(seconds: 2));
      executor.dispose();
    });
    final run = await executor.enqueue(fixture.prepared);
    await gate.entered.future.timeout(const Duration(seconds: 2));
    // 暂停的是已批准但尚未提交事务的写；SQLite 没有被 gate 持锁。
    await executor.runWithTasksPaused<void>('A', '覆盖恢复备份', () async {
      final db = fixture.prepared.messages.storage.db;
      await db.transaction((txn) async {
        await txn.delete('tb_agent_workspace_revisions');
        await txn.delete('tb_agent_workspace_files');
        await txn.update('tb_conversation_list', {'title': '恢复后的同号对话'},
            where: 'cid=?', whereArgs: [fixture.prepared.key.cid]);
      });
      final restoredWorkspace = await AgentWorkspaceService.create(
          fixture.prepared.messages.storage,
          cid: fixture.prepared.key.cid);
      await restoredWorkspace.writeFile(
          name: 'restored.txt', content: '来自备份的正文');
    }).timeout(const Duration(seconds: 2));
    expect(run.isRetired, isTrue);
    await run.finished.timeout(const Duration(seconds: 2));
    // 同一服务以后可绑定另一项有效任务；旧操作仍必须使用开始时捕获的 guard。
    fixture.prepared.workspaceTools.bindExecutionGuard(() => true);
    gate.release.complete();
    await gate.finished.future.timeout(const Duration(seconds: 2));
    final restored = (await fixture.prepared.workspace.listFiles()).single;
    expect(restored.revision, 1, reason: '旧任务不能给恢复后的同名输出添加版本');
    expect((await fixture.prepared.workspace.getRevision(restored.id)).content,
        '来自备份的正文');
    expect(service.requests, 1);
  });
}

class _Fixture {
  final PreparedAgentRun prepared;
  final _Background background;
  const _Fixture(this.prepared, this.background);
}

Future<_Fixture> _fixture(AgentTaskExecutor executor, _Service service,
    {bool exposeWorkspaceTools = false,
    Database Function(Database)? workspaceDatabase}) async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false));
  addTearDown(db.close);
  final manager = HiDBManager.test(db);
  const key = AgentTaskKey('A', 7);
  final conversation = ConversationModel(cid: 7, title: '独立审查任务', icon: '🤖');
  final conversations = await ConversationListDao.create(manager);
  await conversations.saveConversation(conversation);
  final messages = await MessageDao.create(manager, cid: 7);
  final user = MessageModel(
      ownerType: OwnerType.sender, createdAt: 101, content: '创建文件');
  final receiver =
      MessageModel(ownerType: OwnerType.receiver, createdAt: 102, content: '');
  await messages.saveMessageWithBlocks(user);
  final session =
      AgentTaskSession(cid: 7, store: await AgentTaskDao.create(manager));
  addTearDown(session.dispose);
  await session.setEnabled(true);
  await session.begin(userAt: 101, input: user.content);
  final workspaceManager = workspaceDatabase == null
      ? manager
      : HiDBManager.test(workspaceDatabase(db));
  final workspace =
      await AgentWorkspaceService.create(workspaceManager, cid: 7);
  final workspaceTools = await AgentWorkspaceTools.create(workspaceManager,
      cid: 7,
      workspace: workspace,
      confirm: (title, detail) => executor.confirm(key, title, detail));
  await workspaceTools.beginTurn(101, const []);
  final settings = AISettings.defaults()..streamEnabled = true;
  final background = _Background();
  final completion = CompletionDao(
      settings: settings, chatService: service, messages: const []);
  return _Fixture(
      PreparedAgentRun(
          key: key,
          conversation: conversation,
          user: user,
          receiver: receiver,
          settings: settings,
          completion: completion,
          messages: messages,
          usage: UsageRecordService(await UsageDao.create(manager)),
          session: session,
          workspace: workspace,
          workspaceTools: workspaceTools,
          attachments: const ChatAttachments(),
          background: background,
          tools:
              exposeWorkspaceTools ? ToolRegistry(workspaceTools.tools) : null),
      background);
}

PreparedAgentRun _withSession(
        PreparedAgentRun source, AgentTaskSession session) =>
    PreparedAgentRun(
        key: source.key,
        conversation: source.conversation,
        user: source.user,
        receiver: source.receiver,
        settings: source.settings,
        completion: source.completion,
        messages: source.messages,
        usage: source.usage,
        session: session,
        workspace: source.workspace,
        workspaceTools: source.workspaceTools,
        attachments: source.attachments,
        background: source.background,
        tools: source.tools,
        webSearch: source.webSearch);

class _GateStore implements IAgentTaskStore {
  final IAgentTaskStore delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  bool blockNext = false;
  _GateStore(this.delegate);
  @override
  Future<Map<String, dynamic>?> read(int cid) => delegate.read(cid);
  @override
  Future<void> write(int cid, Map<String, dynamic> value) async {
    if (blockNext) {
      blockNext = false;
      entered.complete();
      await release.future;
    }
    await delegate.write(cid, value);
  }
}

/// 仅延迟输出事务入队，模拟已批准写入的异步解析尚未返回。
/// 事务、元数据与版本正文都由真实 SQLite 执行，其他调用不经过 gate。
class _OutputGateDatabase implements Database {
  final Database delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  bool blockNextOutput = false;
  _OutputGateDatabase(this.delegate);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    final gated = blockNextOutput &&
        StackTrace.current.toString().contains('AgentWorkspaceDao.saveOutput');
    if (gated) {
      blockNextOutput = false;
      entered.complete();
      await release.future;
    }
    try {
      return await delegate.transaction(action, exclusive: exclusive);
    } finally {
      if (gated) finished.complete();
    }
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      delegate.execute(sql, arguments);
  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      delegate.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      delegate.rawQuery(sql, arguments);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service implements ChatService {
  final List<StreamEvent> events;
  final Object? failure;
  final Future<void>? failureGate;
  final started = Completer<void>();
  int requests = 0;
  _Service(this.events, {this.failure, this.failureGate});
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
    if (!started.isCompleted) started.complete();
    yield* Stream.fromIterable(events);
    if (failureGate != null) await failureGate;
    if (failure != null) throw failure!;
  }

  @override
  Future<String?> chat(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          Duration? timeout}) async =>
      throw StateError('不能使用非流式入口');
  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      throw StateError('不能使用非流式入口');
  @override
  Stream<String> chatStream(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      throw StateError('不能使用普通文本入口');
}

class _Background implements AgentBackgroundExecution {
  final active = <String>{};
  int starts = 0, stops = 0;
  @override
  Future<AgentBackgroundCapabilities> capabilities() async =>
      const AgentBackgroundCapabilities(supported: true);
  @override
  bool isActive(String runId) => active.contains(runId);
  @override
  Future<AgentBackgroundStartResult> start(
      {required String runId,
      required int cid,
      required String title,
      required Future<void> Function(String reason) onInterrupted}) async {
    starts++;
    active.add(runId);
    return const AgentBackgroundStartResult(active: true);
  }

  @override
  Future<void> stop({required String runId, bool success = false}) async {
    stops++;
    active.remove(runId);
  }

  @override
  Future<void> update(
      {required String runId,
      required int completed,
      required int total,
      required String status}) async {}
}
