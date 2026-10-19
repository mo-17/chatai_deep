import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/pages/agent_workflow_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/workflow_backend_consumer_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkflowBackendFixture f;
  WidgetTester? active;
  bool closed = false;
  var claimWrites = 0, reservationWrites = 0;
  final evidence = <Map<String, Object?>>[];
  final checks = <Map<String, Object?>>[];
  setUp(() async {
    f = WorkflowBackendFixture('stop-all');
    active = null;
    closed = false;
    claimWrites = reservationWrites = 0;
    checks.clear();
    await f.setup();
  });
  tearDown(() async {
    expect(active, isNull);
    if (!closed) await f.close();
    evidence.add({...f.evidence(), 'stopChecks': List.of(checks)});
  });
  tearDownAll(() {
    final root = Platform.environment['R3B4_ROOT']!;
    File('$root/stop-all-evidence.json')
        .writeAsStringSync(jsonEncode(evidence));
    File('$root/cleanup.json').writeAsStringSync(jsonEncode({
      'cases': evidence.length,
      'allSqliteClosed': evidence.every((e) => e['sqlClosed'] == true),
      'syntheticHTTPOnly': true,
      'actualCoordinatorAndPageStopAll': true
    }));
  });

  void countLedger(AgentWorkflow initial) {
    claimWrites = reservationWrites = 0;
    var lease = initial.leaseId;
    var dispatches = initial.dispatches;
    f.sql.afterUpdate = (table, values) async {
      if (table != AgentWorkflowDao.workflows) return;
      final nextLease = values['leaseId'] as String?;
      final nextDispatches = values['dispatches'] as int;
      if (nextLease != null && nextLease != lease) claimWrites++;
      if (nextDispatches > dispatches) reservationWrites++;
      lease = nextLease;
      dispatches = nextDispatches;
    };
  }

  void observeNoLedgerOrPost(int beforePosts) {
    checks.add({
      'claimWrites': claimWrites,
      'reservationWrites': reservationWrites,
      'postDelta': f.posts.length - beforePosts,
      'resolverGets': f.resolverGets
    });
    expect(claimWrites, 0);
    expect(reservationWrites, 0);
    expect(f.posts.length, beforePosts);
    expect(f.resolverGets, 0);
  }

  Future<AgentWorkflow> taskWithOldRunner(bool oldRunner) async {
    final created = await f.create();
    if (!oldRunner) return created;
    f.failed409 = true;
    await f.coordinator.start(f.dao, f.scope(), created);
    expect(f.posts.length, 1);
    expect(f.coordinator.lookup('account-a', created.id), isNotNull);
    f.failed409 = false;
    return (await f.dao.read(created.id))!;
  }

  for (final oldRunner in [false, true]) {
    test(
        'actual stopAll cancels ${oldRunner ? 'new preparation under old runner' : 'unregistered preparation'} before claim',
        () async => f.synthetic(() async {
              final task = await taskWithOldRunner(oldRunner);
              final old = f.coordinator.lookup('account-a', task.id);
              final beforeSteps =
                  (await f.dao.steps(task.id)).map((s) => s.toRow()).toList();
              final beforeAttempts = await f.dao.attemptHistory(task.id);
              final beforePosts = f.posts.length;
              f.gateLoad = f.loads + 2;
              f.loadGate = Completer();
              f.loadEntered = Completer();
              countLedger(task);
              final run = f.coordinator.start(f.dao, f.scope(), task);
              expect(
                  await Future.any<bool>([
                    f.loadEntered!.future.then((_) => true),
                    run.then((_) => false)
                  ]),
                  true);
              expect(f.coordinator.busy('account-a', task.id), true);
              expect(identical(f.coordinator.lookup('account-a', task.id), old),
                  true);
              final preparingScope = f.latestModels!.scope;
              if (old != null) {
                expect(identical(old.scope, preparingScope), false);
              }
              await f.coordinator.stopAll(f.scope());
              final cancelledAtStopReturn = !preparingScope.isCurrent;
              f.loadGate!.complete();
              await run;
              checks.add({
                'cancelledAtStopReturn': cancelledAtStopReturn,
                'oldRunnerPresent': oldRunner
              });
              observeNoLedgerOrPost(beforePosts);
              expect(cancelledAtStopReturn, true);
              expect((await f.dao.read(task.id))!.toRow(), task.toRow());
              expect(
                  (await f.dao.steps(task.id)).map((s) => s.toRow()).toList(),
                  beforeSteps);
              expect(await f.dao.attemptHistory(task.id), beforeAttempts);
              expect(f.coordinator.busy('account-a', task.id), false);
              // stopAll 的短维护许可已释放，之后新的明确操作仍可开始。
              await f.coordinator.start(f.dao, f.scope(), task);
              expect(f.posts.length - beforePosts, 3);
              expect(
                  (await f.dao.read(task.id))!.state, WorkflowState.complete);
            }));
  }

  test(
      'actual stopAll keeps registered runner pause path and no later role',
      () async => f.synthetic(() async {
            final task = await f.create();
            f.responseGate = Completer();
            f.responseEntered = Completer();
            final run = f.coordinator.start(f.dao, f.scope(), task);
            expect(
                await Future.any<bool>([
                  f.responseEntered!.future.then((_) => true),
                  run.then((_) => false)
                ]),
                true);
            final registered = f.coordinator.lookup('account-a', task.id)!;
            expect(registered.scope.isCurrent, true);
            final beforePosts = f.posts.length;
            await f.coordinator.stopAll(f.scope());
            expect((await f.dao.read(task.id))!.state, WorkflowState.paused);
            expect(registered.scope.isCurrent, false);
            f.responseGate!.complete();
            await run;
            expect(f.posts.length, beforePosts);
            expect((await f.dao.read(task.id))!.dispatches, 1);
            expect((await f.dao.steps(task.id)).every((s) => s.result.isEmpty),
                true);
          }));

  test(
      'old control epoch cannot stop a new same-account preparation',
      () async => f.synthetic(() async {
            final oldControl = f.scope();
            f.epoch++;
            final task = await f.create();
            f.gateLoad = f.loads + 2;
            f.loadGate = Completer();
            f.loadEntered = Completer();
            final run = f.coordinator.start(f.dao, f.scope(), task);
            expect(
                await Future.any<bool>([
                  f.loadEntered!.future.then((_) => true),
                  run.then((_) => false)
                ]),
                true);
            expect(await workflowError(f.coordinator.stopAll(oldControl)),
                isA<WorkflowStale>());
            expect(f.latestModels!.scope.isCurrent, true);
            f.loadGate!.complete();
            await run;
            expect(f.posts.length, 3);
            expect((await f.dao.read(task.id))!.state, WorkflowState.complete);
          }));

  test(
      'account held by stop rejects a new preparation before settings await',
      () async => f.synthetic(() async {
            final task = await f.create();
            f.coordinator.channel.holdAccount('account-a');
            Object? failure;
            try {
              failure = await workflowError(
                  f.coordinator.start(f.dao, f.scope(), task));
            } finally {
              f.coordinator.channel.releaseAccount('account-a');
            }
            expect(failure, isA<WorkflowStale>());
            expect(f.loads, 0);
            expect(f.posts, isEmpty);
            expect((await f.dao.read(task.id))!.toRow(), task.toRow());
          }));

  Future<void> pump(WidgetTester t) async {
    await t.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 20));
  }

  Future<void> until(WidgetTester t, FutureOr<bool> Function() done) async {
    for (var i = 0; i < 150; i++) {
      if (await t.runAsync(() async => done()) == true) return;
      await pump(t);
    }
    fail('bounded actual stop-all page settlement');
  }

  Future<void> pageMocked(WidgetTester t, Future<void> Function() body) =>
      f.synthetic(() async {
        active = t;
        try {
          await body();
        } finally {
          if (f.loadGate?.isCompleted == false) f.loadGate!.complete();
          await t.pumpWidget(const SizedBox.shrink());
          await t.pump();
          await t.runAsync(() => f.close());
          closed = true;
          active = null;
        }
      });
  for (final oldRunner in [false, true]) {
    testWidgets(
        'actual history page stop-all during second-role preparation ${oldRunner ? 'with' : 'without'} old runner',
        (t) async => pageMocked(t, () async {
              await t.binding.setSurfaceSize(const Size(900, 1400));
              final created =
                  (await t.runAsync(() => taskWithOldRunner(oldRunner)))!;
              final task = oldRunner
                  ? created
                  : (await t.runAsync(() => f.dao.stop(
                      f.scope(), created.id, created.revision,
                      state: WorkflowState.paused,
                      reason: 'synthetic history')))!;
              final beforeAttempts =
                  (await t.runAsync(() => f.dao.attemptHistory(task.id)))!;
              final beforePosts = f.posts.length;
              await t.runAsync(() => t.pumpWidget(MaterialApp(
                  home: AgentWorkflowPage(
                      parentId: task.id,
                      expectedAccountHash: 'account-a',
                      storage: f.storage,
                      scope: f.scope(),
                      coordinator: f.coordinator,
                      loadSettings: f.load))));
              await until(
                  t,
                  () =>
                      find.byType(LinearProgressIndicator).evaluate().isEmpty);
              f.gateLoad = f.loads + 2;
              f.loadGate = Completer();
              f.loadEntered = Completer();
              countLedger(task);
              await t.ensureVisible(find.text('明确继续'));
              await t.runAsync(() => t.tap(find.text('明确继续')));
              await until(t, () => f.loadEntered!.isCompleted);
              final button = find.widgetWithText(TextButton, '停止全部本机任务');
              await t.ensureVisible(button);
              await until(
                  t, () => t.widget<TextButton>(button).onPressed != null);
              await t.runAsync(() => t.tap(button));
              // 等实际 _action 完成 stopAll、读取快照并再次开放按钮，之后才释放准备。
              await pump(t);
              await until(
                  t, () => t.widget<TextButton>(button).onPressed != null);
              final cancelledAtStopReturn = !f.latestModels!.scope.isCurrent;
              f.loadGate!.complete();
              await until(t, () => !f.coordinator.busy('account-a', task.id));
              checks.add({
                'actualPage': true,
                'oldRunnerPresent': oldRunner,
                'cancelledAtStopReturn': cancelledAtStopReturn
              });
              observeNoLedgerOrPost(beforePosts);
              expect(cancelledAtStopReturn, true);
              expect((await t.runAsync(() => f.dao.read(task.id)))!.toRow(),
                  task.toRow());
              expect((await t.runAsync(() => f.dao.attemptHistory(task.id)))!,
                  beforeAttempts);
              expect(t.takeException(), null);
            }));
  }
}
