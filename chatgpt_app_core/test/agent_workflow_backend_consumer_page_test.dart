import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/pages/agent_workflow_page.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'support/workflow_backend_consumer_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkflowBackendFixture f;
  WidgetTester? active;
  bool closed = false;
  final evidence = <Map<String, Object?>>[];
  setUp(() async {
    f = WorkflowBackendFixture('page');
    closed = false;
    await f.setup();
  });
  tearDown(() async {
    expect(active, isNull);
    if (!closed) await f.close();
    evidence.add(f.evidence());
  });
  tearDownAll(() {
    final root = Platform.environment['R3B4_ROOT']!;
    File('$root/page-evidence.json').writeAsStringSync(jsonEncode(evidence));
    File('$root/cleanup.json').writeAsStringSync(jsonEncode({
      'cases': evidence.length,
      'sqliteClosed': evidence.every((e) => e['sqlClosed'] == true),
      'actualPage': true,
      'syntheticHTTPOnly': true
    }));
  });
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
    fail('bounded actual page settlement did not reach condition');
  }

  Future<void> open(WidgetTester t, {String? parent}) async {
    active = t;
    await t.binding.setSurfaceSize(const Size(900, 1400));
    await t.runAsync(() => t.pumpWidget(MaterialApp(
        home: AgentWorkflowPage(
            conversation: parent == null ? f.conversation : null,
            parentId: parent,
            expectedAccountHash: 'account-a',
            storage: f.storage,
            scope: f.scope(),
            coordinator: f.coordinator,
            loadSettings: f.load))));
    await until(
        t, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
  }

  Future<void> configure(WidgetTester t) async {
    await t.tap(find.widgetWithText(SwitchListTile, '本次启用三Agent协作'));
    await t.enterText(find.byKey(const ValueKey('workflow-task')),
        'synthetic explicit backend workflow');
    for (final role in WorkflowRole.values) {
      final control = find.byKey(ValueKey('workflow-profile-${role.name}'));
      await t.ensureVisible(control);
      await t.tap(control);
      await t.pumpAndSettle();
      final code = ['A', 'B', 'C'][role.index];
      await t.tap(find.text('后端代理 · Synthetic $code ($code) · same').last);
      await t.pumpAndSettle();
    }
    await t.ensureVisible(find.byKey(const ValueKey('workflow-start')));
  }

  Future<void> mocked(Future<void> Function() body) => f.synthetic(() async {
        try {
          await body();
        } finally {
          if (active != null) {
            await active!.pumpWidget(const SizedBox.shrink());
            await active!.pump();
            await active!.runAsync(() => f.close());
            closed = true;
            active = null;
          }
        }
      });

  testWidgets(
      'actual page explicit three pairs -> same prepared run -> one publication',
      (t) async => mocked(() async {
            await t.runAsync(() => ModelCatalog.refreshFromBackend());
            await open(t);
            expect(
                t
                    .widget<FilledButton>(
                        find.byKey(const ValueKey('workflow-start')))
                    .onPressed,
                null);
            expect(f.posts, isEmpty);
            await configure(t);
            await t.runAsync(
                () => t.tap(find.byKey(const ValueKey('workflow-start'))));
            await until(
                t,
                () async => (await f.dao.list(1))
                    .any((w) => w.state == WorkflowState.complete));
            expect(f.posts.map((p) => p['providerCode']), ['A', 'B', 'C']);
            expect(f.resolverGets, 0);
            expect(f.loads, 4,
                reason:
                    'page load plus three pair settings; coordinator reuses prepared model owner');
            final task = (await t.runAsync(() => f.dao.list(1)))!.single;
            final nodes = (await t.runAsync(() => f.dao.steps(task.id)))!;
            expect(nodes.map((s) => s.profile.providerCode), ['A', 'B', 'C']);
            expect(
                (await t.runAsync(
                        () => f.raw.query(AgentWorkflowDao.publications)))!
                    .length,
                1);
            expect(t.takeException(), null);
          }));
  for (final change in ['account', 'origin']) {
    testWidgets(
        'actual page $change during preparation writes no task or source',
        (t) async => mocked(() async {
              await t.runAsync(() => ModelCatalog.refreshFromBackend());
              await open(t);
              await configure(t);
              f.gateLoad = 2;
              f.loadGate = Completer();
              f.loadEntered = Completer();
              await t.runAsync(
                  () => t.tap(find.byKey(const ValueKey('workflow-start'))));
              await until(t, () => f.loadEntered!.isCompleted);
              if (change == 'account') {
                f.tokens.account = 'account-b';
              } else {
                BackendConfig.host = 'changed.synthetic.invalid';
              }
              f.loadGate!.complete();
              for (var i = 0; i < 8; i++) {
                await pump(t);
              }
              expect((await t.runAsync(() => f.dao.list(1)))!, isEmpty);
              expect(f.posts, isEmpty);
              expect(f.resolverGets, 0);
              final source =
                  (await t.runAsync(() => f.raw.query('tb_messages')))!.single;
              expect(source['id'], f.userId);
              expect(source['content'], 'synthetic bounded task');
              expect(t.takeException(), null);
            }));
  }
  testWidgets(
      'actual history resume legacy keeps original reference and no probe/replay',
      (t) async => mocked(() async {
            final created = (await t.runAsync(() => f.create(selected: {
                  for (final r in WorkflowRole.values)
                    r: const WorkflowModelProfile('backend', 'backend', 'same')
                })))!;
            final task = (await t.runAsync(() => f.dao.stop(
                f.scope(), created.id, created.revision,
                state: WorkflowState.paused,
                reason: 'synthetic explicit resume')))!;
            await open(t, parent: task.id);
            final resume = find.text('明确继续');
            await t.ensureVisible(resume);
            await t.tap(resume);
            for (var i = 0; i < 12; i++) {
              await pump(t);
            }
            expect(f.posts, isEmpty);
            expect(f.resolverGets, 0);
            expect((await t.runAsync(() => f.dao.read(task.id)))!.toRow(),
                task.toRow());
            expect(find.textContaining('服务商待确认').evaluate().isNotEmpty, true);
            expect(t.takeException(), null);
          }));
}
