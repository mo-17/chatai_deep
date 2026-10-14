import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/usage_record_service.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/usage_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'agent_workflow_foundation_test.dart'
    show FakeWorkflowTransport, FakeWorkflowBackground;
import 'support/personal_memory_test_support.dart';

const bounded = Duration(seconds: 5);

void main() {
  final evidence = <String, Object?>{};
  late HiDBManager db;
  late AgentWorkflowDao dao;
  late _Auth auth;
  late int source, clock, epoch, restore;
  late Directory root;
  final profiles = {
    for (final role in WorkflowRole.values)
      role: WorkflowModelProfile('local', 'fixture', role.name)
  };
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'a',
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => restore);
  Future<AgentWorkflow> create(
          {WorkflowBudget budget = const WorkflowBudget()}) =>
      dao.createFromSource(scope(),
          cid: 1, userRowId: source, profiles: profiles, budget: budget);
  AgentWorkflowRunner runner(AgentWorkflow w, FakeWorkflowTransport t,
          {AgentExecutionChannel? channel,
          FakeWorkflowBackground? bg,
          Future<bool> Function(WorkflowModelProfile)? available}) =>
      AgentWorkflowRunner(
          dao: dao,
          scope: scope(),
          workflow: w,
          serviceForProfile: (p) async => t.service(p),
          profileAvailable: available ?? (_) async => true,
          foreground: () => true,
          background: bg ?? FakeWorkflowBackground(),
          channel: channel ?? AgentExecutionChannel());
  setUp(() async {
    LoginDao.resetHooksForTest();
    auth = _Auth()..install();
    epoch = restore = 0;
    clock = 100000;
    LoginDao.addLogoutHook(() => epoch++);
    LoginDao.addLoginHook(() => epoch++);
    sqfliteFfiInit();
    db = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(db))
        .saveConversation(ConversationModel(cid: 1, title: '合成工作流', icon: ''));
    source = await (await MessageDao.create(db, cid: 1)).saveMessageWithBlocks(
        MessageModel(
            content: '本次合成任务', ownerType: OwnerType.sender, createdAt: 100));
    dao = await AgentWorkflowDao.create(db, accountHash: 'a', now: () => clock);
    root = await Directory.systemTemp.createTemp('workflow-fixes-');
    BackupService.debugGeneratedImageDirectoryResolver = () async => root;
    BackupService.debugRoleCardAssetsDirectoryResolver = () async => root;
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/attachments');
  });
  tearDown(() async {
    await db.db.close();
    await root.delete(recursive: true);
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    ManagedAttachmentStore.debugRootDirectory = null;
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  // 只有本轮显式指定独立输出路径时才留证，普通复测不得覆盖历史冻结工件。
  tearDownAll(() {
    final path = Platform.environment['CHATAI_WORKFLOW_EVIDENCE_PATH'];
    if (path != null && path.isNotEmpty) {
      File(path).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(evidence));
    }
  });

  for (final maintenance in ['restore', 'logout']) {
    for (final waiting in ['HTTP', 'account-lease']) {
      test('真实LoginDao队列 $maintenance 停止等待 $waiting 的工作流且释放许可', () async {
        final service = BackupService(db);
        final archive = await service.exportArchive(
            settings: AISettings.defaults(), accountHash: 'a');
        final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final releaseHttp = Completer<void>(), received = Completer<void>();
        final bodies = <Object?>[];
        http.listen((request) async {
          bodies.add(jsonDecode(await utf8.decoder.bind(request).join()));
          if (!received.isCompleted) received.complete();
          await releaseHttp.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'choices': [
              {
                'message': {'content': '迟到结果'}
              }
            ]
          }));
          await request.response.close();
        });
        addTearDown(() async {
          if (!releaseHttp.isCompleted) releaseHttp.complete();
          await http.close(force: true);
        });
        final channel = AgentExecutionChannel();
        final executor = AgentTaskExecutor(
            currentAccount: () => auth.account,
            executionChannel: channel,
            observeApplication: false);
        addTearDown(executor.dispose);
        final toReserve = Completer<void>(), atReserve = Completer<void>();
        var checks = 0;
        final w = await create();
        final r = AgentWorkflowRunner(
            dao: dao,
            scope: scope(),
            workflow: w,
            channel: channel,
            foreground: () => true,
            background: FakeWorkflowBackground(),
            profileAvailable: (_) async {
              if (++checks == 2 && waiting == 'account-lease') {
                atReserve.complete();
                await toReserve.future;
              }
              return true;
            },
            serviceForProfile: (p) async => DirectChatService(ProviderConfig(
                apiKey: 'synthetic-key',
                baseUrl: 'http://127.0.0.1:${http.port}/chat/completions',
                model: p.modelId)));
        final done = r.start();
        if (waiting == 'HTTP') {
          await received.future.timeout(bounded);
        } else {
          await atReserve.future.timeout(bounded);
        }
        Future<void> stopAndRestore() =>
            executor.runWithTasksPaused('a', '真实恢复维护', () async {
              await service.importArchive(archive, accountHash: 'a',
                  accountGuard: () {
                expect(LoginDao.getAccountHash(), 'a');
              });
              restore++;
            });
        LoginDao.addLogoutReadyHook(() => executor.cancelAll('真实登出钩子'));
        if (waiting == 'account-lease') {
          Future<void>? logout;
          // 完全复用备份页已持短许可→维护的顺序；确保真实预留已排队，不靠pump猜。
          await LoginDao.runWithStableAccount(
              expectedAccountHash: 'a',
              action: () async {
                if (maintenance == 'logout') logout = LoginDao.logOut();
                toReserve.complete();
                while (LoginDao.debugQueuedAuthOperations <
                    (maintenance == 'logout' ? 2 : 1)) {
                  await Future<void>.delayed(Duration.zero);
                }
                expect((await dao.read(w.id))!.dispatches, 0);
                if (maintenance == 'restore') {
                  await stopAndRestore();
                }
              }).timeout(bounded);
          if (logout != null) await logout!.timeout(bounded);
        } else if (maintenance == 'restore') {
          await LoginDao.runWithStableAccount(
                  expectedAccountHash: 'a', action: stopAndRestore)
              .timeout(bounded);
        } else {
          await LoginDao.logOut().timeout(bounded);
        }
        await done.timeout(bounded);
        releaseHttp.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(bodies.length, waiting == 'HTTP' ? 1 : 0);
        expect(channel.accountAvailable('a'), true);
        expect(
            await db.db.query('tb_messages',
                where: 'ownerType=?',
                whereArgs: [OwnerType.receiver.toString()]),
            isEmpty);
        expect(await db.db.query(AgentWorkflowDao.publications), isEmpty);
        if (maintenance == 'restore') {
          expect(await dao.read(w.id), isNull);
        } else {
          expect((await dao.read(w.id))!.state, WorkflowState.paused);
          final attempts = await dao.attemptHistory(w.id);
          expect(attempts.length, waiting == 'HTTP' ? 1 : 0);
          if (attempts.isNotEmpty) expect(attempts.single['state'], 'unknown');
          await LoginDao.saveAuthToken('synthetic-new-token',
              userName: '合成B',
              extras: const {'accountHash': 'b'}).timeout(bounded);
          expect(LoginDao.getAccountHash(), 'b');
          await expectLater(
              dao.claim(scope(), w.id, (await dao.read(w.id))!.revision),
              throwsA(isA<WorkflowStale>()));
        }
        // 前面的已取消条目不会堵住账号队尾，亦不会在许可释放后执行写入。
        await LoginDao.runWithStableAccount(
                expectedAccountHash: LoginDao.getAccountHash()!,
                action: () async {})
            .timeout(bounded);
        // 合成回环验收日志；不输出真实账号、令牌或用户资料。
        // ignore: avoid_print
        print(
            'AUTH_QUEUE_EVIDENCE:$maintenance/$waiting posts=${bodies.length} lateRows=0 queue=${LoginDao.debugQueuedAuthOperations}');
        evidence['$maintenance/$waiting'] = {
          'httpBodies': bodies,
          'posts': bodies.length,
          'lateReceiverRows': (await db.db.query('tb_messages',
                  where: 'ownerType=?',
                  whereArgs: [OwnerType.receiver.toString()]))
              .length,
          'publicationRows':
              (await db.db.query(AgentWorkflowDao.publications)).length,
          'attempts': await dao.attemptHistory(w.id),
          'maintenanceCompleted': true,
          'authQueueReleased': LoginDao.debugQueuedAuthOperations == 0,
        };
      });
    }
  }

  test('短许可只在原operation存活时重入，逃逸回调必须重新排队', () async {
    late Future<void> Function() escaped;
    await LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          await scope().stable(() async {});
          final zone = Zone.current;
          escaped = () => zone.run(() => scope().stable(() async {}));
        }).timeout(bounded);
    final inside = Completer<void>(), release = Completer<void>();
    final held = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          inside.complete();
          await release.future;
        });
    await inside.future;
    var finished = false;
    final staleZone = escaped().then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    expect(LoginDao.debugQueuedAuthOperations, 1);
    release.complete();
    await Future.wait([held, staleZone]);
  });

  test('取得账号许可后取消仍等待真实短事务回滚，登出不得越过未结束的事务', () async {
    final captured = scope();
    final acquired = Completer<void>(), release = Completer<void>();
    var transactionFinished = false,
        actualTransactionEnded = false,
        logoutFinished = false;
    Object? observedContent;
    bool? observedEnded;
    final operation = captured
        .stable(() => db.db.transaction((tx) async {
              await tx.update('tb_messages', {'content': '禁止提交的临时结果'},
                  where: 'id=?', whereArgs: [source]);
              acquired.complete();
              await release.future;
              captured.verify();
            }).whenComplete(() => actualTransactionEnded = true))
        .then<Object?>((_) => null, onError: (Object error) => error)
        .whenComplete(() => transactionFinished = true);
    await acquired.future.timeout(bounded);
    captured.cancel();
    LoginDao.addLogoutReadyHook(() async {
      observedEnded = actualTransactionEnded;
      observedContent =
          (await db.db.query('tb_messages', where: 'id=?', whereArgs: [source]))
              .single['content'];
    });
    final logout = LoginDao.logOut().whenComplete(() => logoutFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(transactionFinished, false);
    expect(logoutFinished, false);
    release.complete();
    expect(await operation.timeout(bounded), isA<WorkflowStale>());
    await logout.timeout(bounded);
    expect(observedEnded, true);
    expect(observedContent, '本次合成任务');
    expect(
        (await db.db.query('tb_messages', where: 'id=?', whereArgs: [source]))
            .single['content'],
        '本次合成任务');
    expect(LoginDao.getAccountHash(), isNull);
    evidence['acquired-transaction-cancellation'] = {
      'transactionRollbackBeforeLogoutHook': observedEnded,
      'contentAtLogoutHook': observedContent,
      'waitingActionDidNotReturnBeforeRollback': true,
    };
  });

  test('前驱不释放时停止workflow票据立即结算，同cid重排不会越过前驱', () async {
    final channel = AgentExecutionChannel();
    final release = Completer<void>();
    var active = 0, peak = 0;
    final first = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () async {
          active++;
          peak = active;
          await release.future;
          active--;
        },
        pause: (_) async {});
    final t = FakeWorkflowTransport();
    final bg = FakeWorkflowBackground();
    final r = runner(await create(), t, channel: channel, bg: bg);
    final waiting = r.start();
    await r.pause('取消排队').timeout(bounded);
    await waiting.timeout(bounded);
    expect(active, 1);
    expect(t.requests, isEmpty);
    expect(bg.started, isEmpty);
    final reopened =
        runner((await dao.read(r.workflow.id))!, t, channel: channel);
    final next = reopened.start();
    await Future<void>.delayed(Duration.zero);
    expect(t.requests, isEmpty);
    release.complete();
    await Future.wait([first, next]).timeout(bounded);
    expect(peak, 1);
    expect(t.requests.length, 3);
  });

  test('duplicate loser未取得票据，pause不能摘除同快照queued winner或修改其DB', () async {
    final channel = AgentExecutionChannel();
    final release = Completer<void>();
    final predecessor = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () => release.future,
        pause: (_) async {});
    final initial = await create();
    final t = FakeWorkflowTransport();
    final winner = runner(initial, t, channel: channel);
    var winnerFinished = false;
    final waiting = winner.start().whenComplete(() => winnerFinished = true);
    final loserTransport = FakeWorkflowTransport();
    final loser = runner(initial, loserTransport, channel: channel);
    await expectLater(loser.start(), throwsStateError);
    await loser.pause('失败实例的迟到停止').timeout(bounded);
    expect(winnerFinished, false);
    expect((await dao.read(initial.id))!.toRow(), initial.toRow());
    expect(t.requests, isEmpty);
    release.complete();
    await Future.wait([predecessor, waiting]).timeout(bounded);
    expect(winner.workflow.state, WorkflowState.complete);
    expect(t.requests.length, 3);
    expect(loserTransport.requests, isEmpty);
  });

  test('旧已完成runner的迟到pause不影响同cid新workflow票据', () async {
    final channel = AgentExecutionChannel();
    final t = FakeWorkflowTransport();
    final old = runner(await create(), t, channel: channel);
    await old.start();
    expect(old.workflow.state, WorkflowState.complete);
    final release = Completer<void>();
    final predecessor = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () => release.future,
        pause: (_) async {});
    final nextUser = await (await MessageDao.create(db, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: '新一轮合成任务', ownerType: OwnerType.sender, createdAt: 300));
    final initial = await dao.createFromSource(scope(),
        cid: 1, userRowId: nextUser, profiles: profiles);
    final nextTransport = FakeWorkflowTransport();
    final next = runner(initial, nextTransport, channel: channel);
    var settled = false;
    final waiting = next.start().whenComplete(() => settled = true);
    await old.pause('旧回调').timeout(bounded);
    expect(settled, false);
    expect((await dao.read(initial.id))!.toRow(), initial.toRow());
    release.complete();
    await Future.wait([predecessor, waiting]).timeout(bounded);
    expect(next.workflow.state, WorkflowState.complete);
    expect(nextTransport.requests.length, 3);
  });

  test('legacy入队前被共享票据拒绝，cancel不得摘除workflow票据', () async {
    final channel = AgentExecutionChannel();
    final release = Completer<void>();
    final predecessor = channel.run(
        accountHash: 'a',
        cid: 2,
        action: () => release.future,
        pause: (_) async {});
    final initial = await create();
    final t = FakeWorkflowTransport();
    final winner = runner(initial, t, channel: channel);
    var settled = false;
    final waiting = winner.start().whenComplete(() => settled = true);
    final executor = AgentTaskExecutor(
        currentAccount: () => 'a',
        executionChannel: channel,
        observeApplication: false);
    addTearDown(executor.dispose);
    final gate = _GateStore(await AgentTaskDao.create(db));
    final legacy = _HeldLegacy();
    final prepared =
        await _legacy(db, executor, legacy, cid: 1, taskStore: gate);
    gate.hold = true;
    // 同 cid 互斥发生于首次 await 前，未获票据的实例不触发快照写入。
    await expectLater(executor.enqueue(prepared), throwsStateError);
    expect(gate.entered.isCompleted, false);
    expect(executor.lookup(prepared.key), isNull);
    await executor.cancel(prepared.key).timeout(bounded);
    expect(settled, false);
    expect((await dao.read(initial.id))!.toRow(), initial.toRow());
    expect(legacy.requests, 0);
    expect(legacy.bg.started, isEmpty);
    release.complete();
    await Future.wait([predecessor, waiting]).timeout(bounded);
    expect(winner.workflow.state, WorkflowState.complete);
    expect(t.requests.length, 3);
  });

  test('成功注册的owner不能再次注册', () async {
    final channel = AgentExecutionChannel();
    final owner = AgentExecutionOwner();
    await channel.run(
        accountHash: 'a',
        cid: 2,
        owner: owner,
        action: () async {},
        pause: (_) async {});
    await Future<void>.delayed(Duration.zero);
    await expectLater(
        channel.run(
            accountHash: 'a',
            cid: 2,
            owner: owner,
            action: () async {},
            pause: (_) async {}),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'reason', '运行票据身份不可复用')));
  });

  for (final method in ['cancel', 'forget']) {
    test('workflow占通道时legacy排队 $method 不等待前驱且同cid可重新入队', () async {
      final channel = AgentExecutionChannel();
      final t = FakeWorkflowTransport()..gate = Completer<void>();
      final w = runner(await create(), t, channel: channel);
      final running = w.start();
      await t.firstDispatch.future.timeout(bounded);
      final executor = AgentTaskExecutor(
          currentAccount: () => 'a',
          executionChannel: channel,
          observeApplication: false);
      addTearDown(executor.dispose);
      final legacy = _HeldLegacy();
      final prepared = await _legacy(db, executor, legacy);
      final queued = await executor.enqueue(prepared);
      await Future<void>.delayed(Duration.zero);
      if (method == 'cancel') {
        await executor.cancel(prepared.key).timeout(bounded);
      } else {
        await executor.forget(prepared.key).timeout(bounded);
      }
      await queued.finished.timeout(bounded);
      expect(t.requests.length, 1);
      expect(w.workflow.state, WorkflowState.running);
      expect(legacy.requests, 0);
      expect(legacy.bg.started, isEmpty);
      final preparedAgain = await _legacy(db, executor, legacy);
      final again = await executor.enqueue(preparedAgain);
      await Future<void>.delayed(Duration.zero);
      expect(legacy.requests, 0);
      await executor.cancel(preparedAgain.key).timeout(bounded);
      await again.finished.timeout(bounded);
      t.gate!.complete();
      await running.timeout(bounded);
      expect(t.requests.length, 3);
    });
  }
  test('legacy活跃时forget排队workflow不停止legacy，不申请第二个原生许可', () async {
    final channel = AgentExecutionChannel();
    final executor = AgentTaskExecutor(
        currentAccount: () => 'a',
        executionChannel: channel,
        observeApplication: false);
    addTearDown(executor.dispose);
    final legacy = _HeldLegacy();
    final prepared = await _legacy(db, executor, legacy);
    final active = await executor.enqueue(prepared);
    await legacy.started.future.timeout(bounded);
    final t = FakeWorkflowTransport();
    final bg = FakeWorkflowBackground();
    final w = runner(await create(), t, channel: channel, bg: bg);
    final waiting = w.start();
    await executor.forget(const AgentTaskKey('a', 1)).timeout(bounded);
    await waiting.timeout(bounded);
    expect(active.phase, AgentRunPhase.running);
    expect(legacy.requests, 1);
    expect(t.requests, isEmpty);
    expect(bg.started, isEmpty);
    final again = runner((await dao.read(w.workflow.id))!, t, channel: channel);
    final requeued = again.start();
    await Future<void>.delayed(Duration.zero);
    expect(t.requests, isEmpty);
    await executor.cancel(prepared.key).timeout(bounded);
    await requeued.timeout(bounded);
    expect(t.requests.length, 3);
    await legacy.controller.close();
  });

  test('跨一天普通resume不赠送时间，明确追加从当前时刻扩窗并复用分析', () async {
    final t = FakeWorkflowTransport();
    final first = runner(
        await create(budget: const WorkflowBudget(durationMs: 1000)), t,
        available: (p) async => p.modelId == 'analysis');
    await first.start();
    expect(t.requests.length, 1);
    var paused =
        await dao.stop(scope(), first.workflow.id, first.workflow.revision);
    clock += const Duration(days: 1).inMilliseconds;
    final expired = runner(paused, t);
    await expired.start();
    expect(t.requests.length, 1);
    expect(expired.workflow.state, WorkflowState.budgetExhausted);
    paused = await dao.addBudget(
        scope(), expired.workflow.id, expired.workflow.revision,
        dispatches: 0, estimatedTokens: 0, milliseconds: 1000);
    expect(paused.deadlineAt, clock + 1000);
    expect(paused.dispatches, 1);
    var checks = 0;
    final resumed = runner(paused, t, available: (p) async {
      if (p.modelId == 'review' && ++checks == 2) clock += 1000;
      return true;
    });
    await resumed.start();
    expect(t.requests.map((r) => r['model']), ['analysis', 'writing']);
    expect(resumed.workflow.state, WorkflowState.budgetExhausted);
    expect(resumed.workflow.dispatches, 2);
    expect((await dao.steps(paused.id)).first.result, 'analysis-result');
    evidence['explicit-time-addition'] = {
      'newDeadlineAt': paused.deadlineAt,
      'nowAtNewDeadline': clock,
      'models': t.requests.map((r) => r['model']).toList(),
      'finalState': resumed.workflow.state.name,
      'dispatches': resumed.workflow.dispatches,
    };
  });

  for (final invalid in [
    '',
    '```json\n{}\n```',
    '{"decision":"pass","feedback":"意见"}',
    jsonEncode({'decision': 'accept', 'feedback': 'x' * 2001})
  ]) {
    test('无效审阅已知失败保留原文/预算，明确继续仅重试review一次 ${invalid.length}', () async {
      final t = FakeWorkflowTransport(reviewResponses: [invalid]);
      final w = runner(await create(), t);
      await w.start();
      expect(w.workflow.state, WorkflowState.paused);
      expect(w.workflow.dispatches, 3);
      expect(t.requests.length, 3);
      expect(w.workflow.reservedTokens,
          greaterThan(3 * WorkflowBudget.outputTokens));
      final bad = (await db.db
              .query(AgentWorkflowDao.attempts, where: "state='failed'"))
          .single;
      expect(bad['result'], invalid);
      expect(bad['reason'], contains('格式无效'));
      expect((await dao.steps(w.workflow.id)).last.state, WorkflowState.paused);
      expect((await dao.steps(w.workflow.id)).last.result, invalid);
      expect(w.workflow.usageUnknown, false);
      await Future<void>.delayed(Duration.zero);
      expect(t.requests.length, 3);
      final again = runner((await dao.read(w.workflow.id))!, t);
      await again.start();
      expect(again.workflow.state, WorkflowState.complete);
      expect(t.requests.map((r) => r['model']),
          ['analysis', 'writing', 'review', 'review']);
      expect(again.workflow.dispatches, 4);
      final id = await dao.publishReplyOnce(
          scope(), again.workflow.id, again.workflow.revision,
          createdAt: 999);
      expect(
          await dao.publishReplyOnce(
              scope(), again.workflow.id, again.workflow.revision,
              createdAt: 1000),
          id);
      expect(
          (await db.db
                  .query(AgentWorkflowDao.attempts, where: "state='failed'"))
              .single['result'],
          invalid);
      expect(await db.db.query(AgentWorkflowDao.publications), hasLength(1));
      evidence['invalid-review-${invalid.length}'] = {
        'failedResult': bad['result'],
        'failedState': bad['state'],
        'models': t.requests.map((r) => r['model']).toList(),
        'dispatches': again.workflow.dispatches,
        'reservedTokens': again.workflow.reservedTokens,
        'publicationCount': 1,
      };
    });
  }
}

class _Auth extends PersonalMemoryTestAccount {
  bool loggedIn = true;
  _Auth() : super('a');
  @override
  Map<String, dynamic>? readProfileSync() =>
      loggedIn ? super.readProfileSync() : null;
  @override
  String? readTokenSync() => loggedIn ? 'synthetic-auth' : null;
  @override
  Future<void> clear() async => loggedIn = false;
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    loggedIn = true;
    account = extras['accountHash'] as String;
  }
}

class _HeldLegacy implements ChatService {
  final controller = StreamController<StreamEvent>();
  final started = Completer<void>();
  final bg = FakeWorkflowBackground(granted: true);
  int requests = 0;
  @override
  Stream<StreamEvent> chatStreamEvents(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const []}) {
    requests++;
    if (!started.isCompleted) started.complete();
    return controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<PreparedAgentRun> _legacy(
    HiDBManager db, AgentTaskExecutor executor, _HeldLegacy service,
    {int cid = 2, IAgentTaskStore? taskStore}) async {
  final key = AgentTaskKey('a', cid);
  final rows = await db.db
      .query('tb_conversation_list', where: 'cid=?', whereArgs: [cid]);
  final conversation = rows.isEmpty
      ? ConversationModel(cid: cid, title: '合成单Agent', icon: '')
      : ConversationModel.fromJson(rows.single.cast<String, dynamic>());
  if (rows.isEmpty) {
    await (await ConversationListDao.create(db)).saveConversation(conversation);
  }
  final messages = await MessageDao.create(db, cid: cid);
  final user = MessageModel(
      content: '仅本次任务', ownerType: OwnerType.sender, createdAt: 200);
  await messages.saveMessageWithBlocks(user);
  final session = AgentTaskSession(
      cid: cid, store: taskStore ?? await AgentTaskDao.create(db));
  await session.setEnabled(true);
  await session.setBackgroundEnabled(true);
  await session.begin(userAt: 200, input: user.content);
  addTearDown(session.dispose);
  final workspace = await AgentWorkspaceService.create(db, cid: cid);
  final workspaceTools = await AgentWorkspaceTools.create(db,
      cid: cid,
      workspace: workspace,
      confirm: (title, detail) => executor.confirm(key, title, detail));
  final settings = AISettings.defaults()..streamEnabled = true;
  return PreparedAgentRun(
      key: key,
      conversation: conversation,
      user: user,
      receiver: MessageModel(
          ownerType: OwnerType.receiver, content: '', createdAt: 201),
      settings: settings,
      completion: CompletionDao(
          settings: settings, chatService: service, messages: const []),
      messages: messages,
      usage: UsageRecordService(await UsageDao.create(db)),
      session: session,
      workspace: workspace,
      workspaceTools: workspaceTools,
      attachments: const ChatAttachments(),
      background: service.bg);
}

class _GateStore implements IAgentTaskStore {
  final IAgentTaskStore inner;
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false;
  _GateStore(this.inner);
  @override
  Future<Map<String, dynamic>?> read(int cid) => inner.read(cid);
  @override
  Future<void> write(int cid, Map<String, dynamic> value) async {
    if (hold && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await inner.write(cid, value);
  }
}
