import 'dart:async';
import 'dart:convert';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager db;
  late AgentWorkflowDao dao;
  late int userId, clock, epoch, restore;
  late String account;
  late bool foreground;
  final profiles = {
    for (final r in WorkflowRole.values)
      r: WorkflowModelProfile('local', 'fixture', r.name)
  };
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'a',
      currentAccount: () => account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => restore,
      stableOperation: (action) => action());
  Future<AgentWorkflow> create(
          {WorkflowBudget budget = const WorkflowBudget(),
          List<int> files = const [],
          Set<String> tools = const {}}) =>
      dao.createFromSource(scope(),
          cid: 1,
          userRowId: userId,
          profiles: profiles,
          acceptance: const TaskAcceptanceCriteria(requireFullRead: false),
          budget: budget,
          inputFileIds: files,
          grantedTools: tools);
  Future<int> input(String text) async =>
      (await (await AgentWorkspaceDao.create(db, cid: 1)).saveInput(
              name: 'input.txt',
              sourceKey: text,
              contentHash: workflowHash(text),
              content: text,
              pageTexts: [],
              sizeBytes: text.length))
          .id;
  Future<AgentWorkflow> finish(
      AgentWorkflow w, WorkflowStep node, String result) async {
    w = await dao.beginStep(scope(), WorkflowFence.of(w), node.id,
        inputHash: workflowHash('input'));
    final a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), node.id,
        inputHash: workflowHash('input'), estimatedInput: 10);
    return dao.finishAttempt(
        scope(), WorkflowFence.of(a.workflow), a.attemptId!,
        state: WorkflowAttemptState.succeeded,
        result: result,
        promptTokens: 10,
        completionTokens: 5);
  }

  setUp(() async {
    sqfliteFfiInit();
    account = 'a';
    epoch = 1;
    restore = 0;
    clock = 100000;
    foreground = true;
    db = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(db))
        .saveConversation(ConversationModel(cid: 1, title: '合成', icon: ''));
    userId = await (await MessageDao.create(db, cid: 1)).saveMessageWithBlocks(
        MessageModel(
            content: '本次合成任务', ownerType: OwnerType.sender, createdAt: 123));
    dao = await AgentWorkflowDao.create(db, accountHash: 'a', now: () => clock);
  });
  tearDown(() async => db.db.close());

  test('独立UUID节点不覆盖旧version1任务，也不保存设置或凭据', () async {
    final old = await AgentTaskDao.create(db);
    await old.write(1, {'version': 1, 'prompt': '旧单Agent'});
    final w = await create();
    final nodes = await dao.steps(w.id);
    expect(nodes.length, 3);
    expect(nodes.map((n) => n.id).toSet().length, 3);
    expect((await old.read(1))!['prompt'], '旧单Agent');
    expect(nodes.map((n) => n.role), WorkflowRole.values);
    expect(jsonEncode(nodes.map((n) => n.toRow()).toList()),
        isNot(contains('apiKey')));
    expect(
        () => WorkflowModelProfile.fromJson({
              'mode': 'local',
              'providerId': 'p',
              'modelId': 'm',
              'token': 'bad'
            }),
        throwsFormatException);
  });
  test('两个DAO抢同一revision只有一个claim，旧fence和越序节点拒绝', () async {
    final w = await create();
    final other =
        await AgentWorkflowDao.create(db, accountHash: 'a', now: () => clock);
    final results = await Future.wait([dao, other].map((d) async {
      try {
        return await d.claim(scope(), w.id, w.revision);
      } on WorkflowStale {
        return null;
      }
    }));
    expect(results.whereType<AgentWorkflow>().length, 1);
    final claimed = results.whereType<AgentWorkflow>().single;
    final nodes = await dao.steps(w.id);
    await expectLater(
        dao.beginStep(scope(), WorkflowFence.of(claimed), nodes[1].id,
            inputHash: workflowHash('x')),
        throwsA(isA<WorkflowStale>()));
    final running = await dao.beginStep(
        scope(), WorkflowFence.of(claimed), nodes[0].id,
        inputHash: workflowHash('x'));
    await expectLater(
        dao.reserveDispatch(scope(), WorkflowFence.of(claimed), nodes[0].id,
            inputHash: workflowHash('x'), estimatedInput: 1),
        throwsA(isA<WorkflowStale>()));
    expect(running.revision, greaterThan(claimed.revision));
  });
  test('失败不退款，预算原子拒绝；明确追加不重置已用次数', () async {
    var w = await dao.claim(scope(),
        (await create(budget: const WorkflowBudget(maxDispatches: 1))).id, 1);
    final n = (await dao.steps(w.id)).first;
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    final a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    w = await dao.finishAttempt(
        scope(), WorkflowFence.of(a.workflow), a.attemptId!,
        state: WorkflowAttemptState.failed, reason: '503');
    expect(w.dispatches, 1);
    expect(w.reservedTokens, 2058);
    w = await dao.claim(scope(), w.id, w.revision);
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    expect((await dao.steps(w.id)).first.cycles, 1);
    final blocked = await dao.reserveDispatch(
        scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    expect(blocked.allowed, false);
    expect(blocked.workflow.state, WorkflowState.budgetExhausted);
    expect((await dao.attemptHistory(w.id)).length, 1);
    w = await dao.addBudget(scope(), w.id, blocked.workflow.revision,
        dispatches: 1, estimatedTokens: 0, milliseconds: 0);
    expect(w.dispatches, 1);
    expect(w.maxDispatches, 2);
    expect(w.reservedTokens, 2058);
  });
  test('累计估算、单次输出和时限发送前硬拒绝，不伪称金额预算', () async {
    var w = await create(
        budget: const WorkflowBudget(estimatedTokens: 2048, durationMs: 20));
    w = await dao.claim(scope(), w.id, w.revision);
    final n = (await dao.steps(w.id)).first;
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    await expectLater(
        dao.reserveDispatch(scope(), WorkflowFence.of(w), n.id,
            inputHash: workflowHash('x'),
            estimatedInput: 1,
            outputTokens: 2049),
        throwsA(isA<WorkflowStale>()));
    final blocked = await dao.reserveDispatch(
        scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'), estimatedInput: 1);
    expect(blocked.allowed, false);
    expect(blocked.workflow.dispatches, 0);
    expect(blocked.workflow.estimatedCost, null);
    w = await dao.addBudget(scope(), w.id, blocked.workflow.revision,
        dispatches: 0, estimatedTokens: 5000, milliseconds: 0);
    w = await dao.claim(scope(), w.id, w.revision);
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    clock += 30;
    expect(
        (await dao.reserveDispatch(scope(), WorkflowFence.of(w), n.id,
                inputHash: workflowHash('x'), estimatedInput: 1))
            .allowed,
        false);
  });
  test('缺任一价格时总费用未知；已知用量超过预估会补扣、不会退还', () async {
    var w = await create();
    w = await dao.claim(scope(), w.id, w.revision);
    final nodes = await dao.steps(w.id);
    w = await dao.beginStep(scope(), WorkflowFence.of(w), nodes.first.id,
        inputHash: workflowHash('x'));
    var a = await dao.reserveDispatch(
        scope(), WorkflowFence.of(w), nodes.first.id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    w = await dao.finishAttempt(
        scope(), WorkflowFence.of(a.workflow), a.attemptId!,
        state: WorkflowAttemptState.succeeded,
        result: '分析',
        promptTokens: 3000,
        completionTokens: 500,
        estimatedCost: 0.5);
    expect(w.reservedTokens, 3500);
    expect(w.estimatedCost, 0.5);
    w = await dao.beginStep(scope(), WorkflowFence.of(w), nodes[1].id,
        inputHash: workflowHash('x'));
    a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), nodes[1].id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    w = await dao.finishAttempt(
        scope(), WorkflowFence.of(a.workflow), a.attemptId!,
        state: WorkflowAttemptState.succeeded,
        result: '正文',
        promptTokens: 10,
        completionTokens: 5);
    expect(w.reservedTokens, 5558);
    expect(w.estimatedCost, null);
    w = await dao.beginStep(scope(), WorkflowFence.of(w), nodes[2].id,
        inputHash: workflowHash('x'));
    a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), nodes[2].id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    w = await dao.finishAttempt(
        scope(), WorkflowFence.of(a.workflow), a.attemptId!,
        state: WorkflowAttemptState.succeeded,
        result: '审阅',
        promptTokens: 10,
        completionTokens: 5,
        estimatedCost: 0.5);
    expect(w.estimatedCost, null);
  });
  test('进程中断的dispatched变unknown，重开/明确继续也不自动重放', () async {
    var w = await create();
    w = await dao.claim(scope(), w.id, w.revision);
    final n = (await dao.steps(w.id)).first;
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    final a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    final reopened =
        await AgentWorkflowDao.create(db, accountHash: 'a', now: () => clock);
    w = await reopened.stop(scope(), w.id, a.workflow.revision, reason: '进程中断');
    expect((await reopened.attemptHistory(w.id)).single['state'], 'unknown');
    await expectLater(reopened.claim(scope(), w.id, w.revision),
        throwsA(isA<WorkflowStale>()));
    await expectLater(
        dao.finishAttempt(scope(), WorkflowFence.of(a.workflow), a.attemptId!,
            state: WorkflowAttemptState.succeeded, result: 'late'),
        throwsA(isA<WorkflowStale>()));
  });
  test('账号A→B→A、同账号重登、恢复代次均撤销scope；两账号DB不混用', () async {
    final w = await create();
    final captured = scope();
    account = 'b';
    epoch++;
    account = 'a';
    epoch++;
    await expectLater(
        dao.claim(captured, w.id, w.revision), throwsA(isA<WorkflowStale>()));
    final relog = scope();
    epoch++;
    await expectLater(
        dao.claim(relog, w.id, w.revision), throwsA(isA<WorkflowStale>()));
    final beforeRestore = scope();
    restore++;
    await expectLater(dao.claim(beforeRestore, w.id, w.revision),
        throwsA(isA<WorkflowStale>()));
    final wrong = AgentWorkflowScope(
        accountHash: 'b',
        currentAccount: () => 'b',
        stableOperation: (a) => a());
    expect(() => dao.claim(wrong, w.id, w.revision),
        throwsA(isA<WorkflowStale>()));
    expect((await dao.read(w.id))!.dispatches, 0);
  });
  test('原用户UUID/正文/会话绑定与输入版本变动逐事务拒绝', () async {
    final id = await input('允许输入');
    var w = await create(files: [id]);
    w = await dao.claim(scope(), w.id, w.revision);
    final f = WorkflowFence.of(w);
    await db.db.update('tb_agent_workspace_files', {'currentRevision': 2},
        where: 'id=?', whereArgs: [id]);
    await expectLater(
        dao.verifyCurrent(scope(), f), throwsA(isA<WorkflowStale>()));
    await db.db.update('tb_agent_workspace_files', {'currentRevision': 1},
        where: 'id=?', whereArgs: [id]);
    await db.db.update('tb_messages', {'memorySourceId': 'different'},
        where: 'id=?', whereArgs: [userId]);
    await expectLater(
        dao.verifyCurrent(scope(), f), throwsA(isA<WorkflowStale>()));
    final source = w.toRow()['sourceId'];
    await db.db.update(
        'tb_messages', {'memorySourceId': source, 'content': '变化'},
        where: 'id=?', whereArgs: [userId]);
    await expectLater(
        dao.verifyCurrent(scope(), f), throwsA(isA<WorkflowStale>()));
    await db.db.update('tb_messages', {'content': '本次合成任务'},
        where: 'id=?', whereArgs: [userId]);
    await db.db
        .update('tb_conversation_list', {'assistantId': 99}, where: 'cid=1');
    await expectLater(
        dao.verifyCurrent(scope(), f), throwsA(isA<WorkflowStale>()));
  });
  test('源删除事务清理父子attempt，不影响另一cid，late不复活', () async {
    var w = await create();
    w = await dao.claim(scope(), w.id, w.revision);
    final n = (await dao.steps(w.id)).first;
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    final a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    await (await ConversationListDao.create(db))
        .saveConversation(ConversationModel(cid: 2, title: '其它', icon: ''));
    final u2 = await (await MessageDao.create(db, cid: 2))
        .saveMessageWithBlocks(MessageModel(
            content: '其它', ownerType: OwnerType.sender, createdAt: 124));
    final other = await dao.createFromSource(scope(),
        cid: 2, userRowId: u2, profiles: profiles);
    await (await MessageDao.create(db, cid: 1)).deleteMessage(userId);
    expect(await dao.read(w.id), null);
    expect(await dao.steps(w.id), isEmpty);
    expect(await dao.attemptHistory(w.id), isEmpty);
    expect(await dao.read(other.id), isNotNull);
    await expectLater(
        dao.finishAttempt(scope(), WorkflowFence.of(a.workflow), a.attemptId!,
            state: WorkflowAttemptState.succeeded, result: 'late'),
        throwsA(isA<WorkflowStale>()));
  });
  test('节点结果/attempt/父进度原子性：中途SQL失败全部回滚', () async {
    var w = await create();
    w = await dao.claim(scope(), w.id, w.revision);
    final n = (await dao.steps(w.id)).first;
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    final a = await dao.reserveDispatch(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'), estimatedInput: 10);
    await db.db.execute(
        "CREATE TRIGGER synthetic_fail BEFORE UPDATE ON ${AgentWorkflowDao.stepTable} WHEN NEW.state='complete' BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    await expectLater(
        dao.finishAttempt(scope(), WorkflowFence.of(a.workflow), a.attemptId!,
            state: WorkflowAttemptState.succeeded, result: '不应保存'),
        throwsA(anything));
    expect((await dao.attemptHistory(w.id)).single['state'], 'dispatched');
    expect((await dao.steps(w.id)).first.result, '');
    expect((await dao.read(w.id))!.revision, a.workflow.revision);
  });
  test('最终发布后模拟崩溃/重开/两实例重试，只保留一个回复与publication', () async {
    var w = await create();
    w = await dao.claim(scope(), w.id, w.revision);
    for (final n in await dao.steps(w.id)) {
      w = await finish(w, n, '结果${n.role.name}');
    }
    w = await dao.complete(scope(), WorkflowFence.of(w));
    final first =
        await dao.publishReplyOnce(scope(), w.id, w.revision, createdAt: 500);
    final reopened = await AgentWorkflowDao.create(db, accountHash: 'a');
    final second = await reopened.publishReplyOnce(scope(), w.id, w.revision,
        createdAt: 501);
    expect(first, second);
    expect(
        (await db.db
                .query('tb_messages', where: "ownerType='OwnerType.receiver'"))
            .length,
        1);
    final row =
        (await db.db.query('tb_messages', where: 'id=?', whereArgs: [first]))
            .single;
    expect(row['content'], '结果writing');
    expect(row['blocks'], contains('结果writing'));
  });
  test('工具断点严格、最多2轮；未知工具不重放，已保存结果保留', () async {
    var w = await create();
    w = await dao.claim(scope(), w.id, w.revision);
    final n = (await dao.steps(w.id)).first;
    w = await dao.beginStep(scope(), WorkflowFence.of(w), n.id,
        inputHash: workflowHash('x'));
    await expectLater(
        dao.checkpoint(
            scope(),
            WorkflowFence.of(w),
            n.id,
            {
              'version': 1,
              'messages': [
                {'role': 'assistant', 'content': 'x', 'apiKey': 'bad'}
              ],
              'nextRound': 0
            },
            toolRounds: 0),
        throwsFormatException);
    final deep = <String, dynamic>{};
    var tail = deep;
    for (var i = 0; i < 10; i++) {
      final next = <String, dynamic>{};
      tail['nested'] = next;
      tail = next;
    }
    await expectLater(
        dao.checkpoint(
            scope(),
            WorkflowFence.of(w),
            n.id,
            {
              'version': 1,
              'messages': [deep],
              'nextRound': 0
            },
            toolRounds: 0),
        throwsFormatException);
    await expectLater(
        dao.checkpoint(scope(), WorkflowFence.of(w), n.id,
            {'version': 1, 'messages': [], 'nextRound': 0, 'apiKey': 'bad'},
            toolRounds: 0),
        throwsFormatException);
    await expectLater(
        dao.checkpoint(scope(), WorkflowFence.of(w), n.id,
            {'version': 1, 'messages': [], 'nextRound': 2},
            toolRounds: 3),
        throwsFormatException);
    w = await dao.checkpoint(
        scope(),
        WorkflowFence.of(w),
        n.id,
        {
          'version': 1,
          'messages': [
            {'role': 'tool', 'content': '已保存结果'}
          ],
          'nextRound': 2,
          'executingToolId': 'unknown-id'
        },
        toolRounds: 2);
    w = await dao.stop(scope(), w.id, w.revision, reason: '工具中断');
    await expectLater(
        dao.claim(scope(), w.id, w.revision), throwsA(isA<WorkflowStale>()));
    expect((await dao.steps(w.id)).first.checkpoint!['messages'], [
      {'role': 'tool', 'content': '已保存结果'}
    ]);
  });

  AgentWorkflowRunner runner(AgentWorkflow w, FakeWorkflowTransport transport,
          FakeWorkflowBackground bg,
          {Future<bool> Function(WorkflowModelProfile)? available,
          AgentExecutionChannel? channel}) =>
      AgentWorkflowRunner(
          dao: dao,
          scope: scope(),
          workflow: w,
          serviceForProfile: (profile) async => transport.service(profile),
          profileAvailable: available ?? (_) async => true,
          foreground: () => foreground,
          background: bg,
          channel: channel ?? AgentExecutionChannel());
  test('三节点独立实际出站、有限结果分享、零旧记忆/角色上下文，未知价格显示null', () async {
    final transport = FakeWorkflowTransport();
    final run = runner(await create(), transport, FakeWorkflowBackground());
    await run.start();
    expect(run.workflow.state, WorkflowState.complete);
    expect(transport.requests.length, 3);
    expect(transport.requests.map((r) => r['model']),
        ['analysis', 'writing', 'review']);
    expect((transport.requests[0]['messages'] as List).length, 2);
    expect(jsonEncode(transport.requests[1]), contains('analysis-result'));
    expect(jsonEncode(transport.requests[2]), contains('writing-result'));
    expect(run.workflow.dispatches, 3);
    expect(run.workflow.estimatedCost, null);
    expect(run.workflow.actualInputTokens, 30);
    expect(run.workflow.actualOutputTokens, 15);
    expect(jsonEncode(transport.requests), isNot(contains('personal_memory')));
  });
  test('最多一次返工再审，只有五个独立请求；预算4则第五次发送前暂停', () async {
    final t = FakeWorkflowTransport(reviseFirst: true);
    final r = runner(
        await create(budget: const WorkflowBudget(maxDispatches: 4)),
        t,
        FakeWorkflowBackground());
    await r.start();
    expect(t.requests.map((v) => v['model']),
        ['analysis', 'writing', 'review', 'writing']);
    expect(r.workflow.state, WorkflowState.budgetExhausted);
    expect(r.workflow.dispatches, 4);
    expect(r.workflow.reworks, 1);
  });
  test('一次返工再审成功恰好5请求，不再分析；第二次revise暂停不第六次请求', () async {
    final t = FakeWorkflowTransport(reviseFirst: true);
    final r = runner(await create(), t, FakeWorkflowBackground());
    await r.start();
    expect(r.workflow.state, WorkflowState.complete);
    expect(t.requests.map((v) => v['model']),
        ['analysis', 'writing', 'review', 'writing', 'review']);
    expect(r.workflow.dispatches, 5);
    expect(r.workflow.reworks, 1);
    final id = await (await MessageDao.create(db, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: '再次合成', ownerType: OwnerType.sender, createdAt: 701));
    final next = await dao.createFromSource(scope(),
        cid: 1, userRowId: id, profiles: profiles);
    final t2 = FakeWorkflowTransport(alwaysRevise: true);
    final r2 = runner(next, t2, FakeWorkflowBackground());
    await r2.start();
    expect(r2.workflow.state, WorkflowState.paused);
    expect(t2.requests.length, 5);
    expect(r2.workflow.reason, contains('一次自动返工'));
  });
  test('当前节点工具只允许已选输入和交集白名单，源码变化后检查失效', () async {
    final allowed = await input('允许读取');
    final other = await input('不得读取');
    final t = FakeWorkflowTransport()..gate = Completer<void>();
    final r = runner(
        await create(files: [allowed], tools: {'list_files', 'read_file'}),
        t,
        FakeWorkflowBackground());
    final done = r.start();
    await t.firstDispatch.future;
    final n = (await dao.steps(r.workflow.id)).first;
    await r.verifyTool(n.id, 'list_files');
    await r.verifyTool(n.id, 'read_file', fileId: allowed);
    for (final name in [
      'write_file',
      'web_search',
      'search_chat_history',
      'file_search'
    ]) {
      await expectLater(r.verifyTool(n.id, name, fileId: allowed),
          throwsA(isA<WorkflowStale>()));
    }
    await expectLater(r.verifyTool(n.id, 'read_file', fileId: other),
        throwsA(isA<WorkflowStale>()));
    await db.db.update('tb_messages', {'content': '源码已改'},
        where: 'id=?', whereArgs: [userId]);
    await expectLater(r.verifyTool(n.id, 'read_file', fileId: allowed),
        throwsA(isA<WorkflowStale>()));
    t.gate!.complete();
    await done;
    expect(t.requests.length, 1);
    expect((await dao.steps(r.workflow.id)).first.result, '');
  });
  test('已完成分析节点重开复用；模型撤权暂停，恢复配置不切换模型/重计分析', () async {
    var configured = false;
    final t = FakeWorkflowTransport();
    final first = runner(await create(), t, FakeWorkflowBackground(),
        available: (p) async => p.modelId == 'analysis' || configured);
    await first.start();
    expect(t.requests.length, 1);
    expect(first.workflow.state, WorkflowState.needsConfiguration);
    configured = true;
    final reopened = runner(
        (await dao.read(first.workflow.id))!, t, FakeWorkflowBackground());
    await reopened.start();
    expect(reopened.workflow.state, WorkflowState.complete);
    expect(
        t.requests.map((r) => r['model']), ['analysis', 'writing', 'review']);
  });
  test('不支持后台仍允许前台；后台无许可/late结果安全暂停，不发下一节点', () async {
    final t = FakeWorkflowTransport()..gate = Completer<void>();
    final channel = AgentExecutionChannel();
    final r =
        runner(await create(), t, FakeWorkflowBackground(), channel: channel);
    final done = r.start();
    await t.firstDispatch.future;
    foreground = false;
    await channel.enteredBackground();
    t.gate!.complete();
    await done;
    expect(t.requests.length, 1);
    expect(r.workflow.state, WorkflowState.paused);
    expect(
        (await dao.attemptHistory(r.workflow.id)).single['state'], 'unknown');
    expect((await dao.steps(r.workflow.id)).first.result, '');
  });
  test('父任务只有一次原生申请，获批许可跨三节点；排队后台不启动', () async {
    final t = FakeWorkflowTransport();
    final bg = FakeWorkflowBackground(granted: true);
    t.afterRequest = () => foreground = false;
    final r = runner(await create(), t, bg);
    await r.start();
    expect(r.workflow.state, WorkflowState.complete);
    expect(bg.started.length, 1);
    expect(bg.stopped, 1);
    foreground = false;
    final user = await (await MessageDao.create(db, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: '另一个任务', ownerType: OwnerType.sender, createdAt: 600));
    final next = await dao.createFromSource(scope(),
        cid: 1, userRowId: user, profiles: profiles);
    final t2 = FakeWorkflowTransport();
    await runner(next, t2, FakeWorkflowBackground()).start();
    expect(t2.requests, isEmpty);
  });
  test('同一通道的两父任务严格串行，重复同cid被拒', () async {
    final channel = AgentExecutionChannel();
    final held = Completer<void>();
    final events = <String>[];
    final a = channel.run(
        accountHash: 'a',
        cid: 1,
        action: () async {
          events.add('legacy-start');
          await held.future;
          events.add('legacy-end');
        },
        pause: (_) async {});
    await Future<void>.value();
    await expectLater(
        channel.run(
            accountHash: 'a', cid: 1, action: () async {}, pause: (_) async {}),
        throwsStateError);
    final t = FakeWorkflowTransport();
    final r =
        runner(await create(), t, FakeWorkflowBackground(), channel: channel);
    // Same cid intentionally rejected by the common reservation.
    await expectLater(r.start(), throwsStateError);
    final b = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () async {
          events.add('workflow-start');
        },
        pause: (_) async {});
    expect(events, ['legacy-start']);
    held.complete();
    await Future.wait([a, b]);
    expect(events, ['legacy-start', 'legacy-end', 'workflow-start']);
  });
  test('不同实例抢同一父任务，claim失败者不能暂停胜者的lease', () async {
    final initial = await create();
    final t = FakeWorkflowTransport()..gate = Completer<void>();
    final winner = runner(initial, t, FakeWorkflowBackground());
    final done = winner.start();
    await t.firstDispatch.future;
    final losingTransport = FakeWorkflowTransport();
    final loser = runner(initial, losingTransport, FakeWorkflowBackground());
    // 共享会话票据在入队前拒绝重复实例；胜者仍保持原数据库 lease。
    await expectLater(loser.start(), throwsStateError);
    final live = await dao.read(initial.id);
    expect(live!.state, WorkflowState.running);
    expect(live.leaseId, winner.workflow.leaseId);
    expect(losingTransport.requests, isEmpty);
    t.gate!.complete();
    await done;
    expect(winner.workflow.state, WorkflowState.complete);
    expect(t.requests.length, 3);
  });
  test('排队父任务被停止后不申请许可、不请求、不落入running', () async {
    final channel = AgentExecutionChannel();
    final release = Completer<void>();
    final first = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () async => release.future,
        pause: (_) async {});
    final t = FakeWorkflowTransport();
    final bg = FakeWorkflowBackground();
    final r = runner(await create(), t, bg, channel: channel);
    final waiting = r.start();
    await channel.pauseConversation('a', 1, '用户停止排队');
    release.complete();
    await Future.wait([first, waiting]);
    expect(t.requests, isEmpty);
    expect(bg.started, isEmpty);
    expect(r.workflow.state, WorkflowState.paused);
  });
  test('现有维护入口阻断新协作入队/dispatch，维护完成不自动启动', () async {
    final channel = AgentExecutionChannel();
    final executor =
        AgentTaskExecutor(executionChannel: channel, observeApplication: false);
    final t = FakeWorkflowTransport()..gate = Completer<void>();
    final w = await create();
    final r = runner(w, t, FakeWorkflowBackground(), channel: channel);
    final done = r.start();
    await t.firstDispatch.future;
    await executor.runWithTasksPaused('a', '恢复导入中', () async {
      expect(channel.accountAvailable('a'), false);
      expect(r.canDispatch, false);
      await expectLater(
          channel.run(
              accountHash: 'a',
              cid: 2,
              action: () async {},
              pause: (_) async {}),
          throwsStateError);
      expect(channel.accountAvailable('b'), true);
    });
    t.gate!.complete();
    await done;
    expect(channel.accountAvailable('a'), true);
    expect(t.requests.length, 1);
    expect((await dao.read(w.id))!.state, WorkflowState.paused);
    executor.dispose();
  });
}

class FakeWorkflowTransport {
  final bool reviseFirst, alwaysRevise;
  final List<String> reviewResponses;
  final requests = <Map<String, dynamic>>[];
  Completer<void>? gate;
  final firstDispatch = Completer<void>();
  void Function()? afterRequest;
  FakeWorkflowTransport(
      {this.reviseFirst = false,
      this.alwaysRevise = false,
      this.reviewResponses = const []});
  ChatService service(WorkflowModelProfile p) => FakeWorkflowService(this, p);
}

class FakeWorkflowService
    implements
        ChatService,
        OptionsAwareNonStreamingChatService,
        AttemptAwareChatService {
  final FakeWorkflowTransport transport;
  final WorkflowModelProfile profile;
  FakeWorkflowService(this.transport, this.profile);
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    final messages = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    transport.requests.add({
      'model': profile.modelId,
      'messages': jsonDecode(jsonEncode(messages)),
      'max_tokens': options.maxOutputTokensOverride,
      'maxRetries': options.maxAutoRetries
    });
    if (!transport.firstDispatch.isCompleted) {
      transport.firstDispatch.complete();
    }
    await transport.gate?.future;
    transport.afterRequest?.call();
    final reviews =
        transport.requests.where((r) => r['model'] == 'review').length;
    return ChatCompletionResult(
        content: profile.modelId == 'review'
            ? reviews <= transport.reviewResponses.length
                ? transport.reviewResponses[reviews - 1]
                : jsonEncode({
                    'decision': transport.alwaysRevise ||
                            (transport.reviseFirst && reviews == 1)
                        ? 'revise'
                        : 'accept',
                    'feedback': '合成审阅意见'
                  })
            : '${profile.modelId}-result',
        promptTokens: 10,
        completionTokens: 5);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeWorkflowBackground implements AgentBackgroundExecution {
  final bool granted;
  final started = <String>[];
  int stopped = 0;
  bool active = false;
  FakeWorkflowBackground({this.granted = false});
  @override
  Future<AgentBackgroundCapabilities> capabilities() async =>
      AgentBackgroundCapabilities(supported: granted);
  @override
  Future<AgentBackgroundStartResult> start(
      {required String runId,
      required int cid,
      required String title,
      required Future<void> Function(String) onInterrupted}) async {
    started.add(runId);
    active = granted;
    return AgentBackgroundStartResult(active: granted);
  }

  @override
  bool isActive(String id) => active && started.single == id;
  @override
  Future<void> stop({required String runId, bool success = false}) async {
    active = false;
    stopped++;
  }

  @override
  Future<void> update(
      {required String runId,
      required int completed,
      required int total,
      required String status}) async {}
}
