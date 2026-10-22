import 'support/owned_test_directory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_workflow_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;
import 'agent_workflow_foundation_test.dart'
    show FakeWorkflowTransport, FakeWorkflowBackground;

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B4_ROOT',
    nonceKey: 'R3B4_NONCE',
    legacyPrefix: '/tmp/chatai-r3b4-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database db;
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late AgentWorkflowCoordinator coordinator;
  late PairTokens tokens;
  late AISettings settings;
  late FakeWorkflowTransport transport;
  late AgentWorkflow old;
  late String oldHost;
  late bool oldHttps;
  int serial = 0;
  final evidence = <Map<String, Object?>>[];
  AgentWorkflowScope scope() => AgentWorkflowScope(accountHash: 'account-a');
  final conversation = ConversationModel(cid: 8, title: 'synthetic', icon: '');
  Future<void> pump(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> until(WidgetTester t, FutureOr<bool> Function() done) async {
    for (var i = 0; i < 150; i++) {
      if (await t.runAsync(() async => done()) == true) return;
      await pump(t, 1);
    }
    fail(
        'bounded actual workflow page settlement: ${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).whereType<String>().join(" | ")}');
  }

  setUpAll(() {
    root = ownedFixture.directory;
    sqfliteFfiInit();
  });
  Future<void> setup() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    LoginDao.resetHooksForTest();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'workflow.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'workflow.synthetic.invalid';
    BackendConfig.useHttps = true;
    db = await databaseFactoryFfi
        .openDatabase('${root.path}/case-${serial++}.sqlite');
    storage = HiDBManager.test(db);
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel.fromJson(conversation.toJson()));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'account-a');
    settings = AISettings.defaults()
      ..mode = AIMode.local
      ..activeProviderId = 'A'
      ..providers = [
        for (final p in ['A', 'B'])
          AiProvider(
              id: p,
              name: 'Service $p',
              type: 'openai',
              enabled: true,
              apiHost: 'http://synthetic.invalid',
              apiKey: 'synthetic-$p',
              models: [
                for (final r in WorkflowRole.values) AiModel(id: r.name)
              ],
              selectedModelId: 'analysis')
      ];
    transport = FakeWorkflowTransport();
    coordinator = AgentWorkflowCoordinator(
        channel: AgentExecutionChannel(),
        background: FakeWorkflowBackground(),
        foreground: () => true,
        observeApplication: false,
        serviceForProfile: (p) async => transport.service(p),
        profileAvailable: (_) async => true);
    old = await dao.createFromSource(scope(),
        cid: 8,
        newTask: 'old unknown request',
        newUserCreatedAt: 101,
        profiles: {
          for (final r in WorkflowRole.values)
            r: WorkflowModelProfile('local', 'A', r.name)
        },
        acceptance: const TaskAcceptanceCriteria(requireFullRead: false));
    old = await dao.claim(scope(), old.id, old.revision);
    final first = (await dao.steps(old.id)).first;
    old = await dao.beginStep(scope(), WorkflowFence.of(old), first.id,
        inputHash: workflowHash('original'));
    final reserved = await dao.reserveDispatch(
        scope(), WorkflowFence.of(old), first.id,
        inputHash: workflowHash('original'), estimatedInput: 10);
    old = await dao.stop(scope(), old.id, reserved.workflow.revision,
        reason: 'timeout');
  }

  Future<void> open(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(900, 1400));
    await t.runAsync(setup);
    await t.runAsync(() => t.pumpWidget(MaterialApp(
        home: AgentWorkflowPage(
            conversation: conversation,
            parentId: old.id,
            storage: storage,
            expectedAccountHash: 'account-a',
            scope: scope(),
            coordinator: coordinator,
            loadSettings: () async => settings.clone()))));
    await until(t, () => find.text('明确继续').evaluate().isNotEmpty);
    await t.ensureVisible(find.text('明确继续'));
    await t.tap(find.text('明确继续'));
    await pump(t, 12);
  }

  Future<void> close(WidgetTester t) async {
    await t.runAsync(() => coordinator.stopAll(scope()));
    await t.pumpWidget(const SizedBox.shrink());
    await pump(t, 2);
    await t.runAsync(() => db.close());
    coordinator.dispose();
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    evidence.add({
      'sqliteClosed': !db.isOpen,
      'syntheticRequests': transport.requests.length,
      'logout': tokens.clears
    });
  }

  tearDownAll(
      () => File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
            'cases': evidence,
            'allClosed': true,
            'modelHTTP': 0,
            'fakeWorkflowTransport': true
          })));
  testWidgets(
      'unknown local workflow cancel leaves original attempt and zero dispatch',
      (t) async {
    try {
      await open(t);
      expect(
          find.byKey(const ValueKey('direct_recovery_cancel')), findsOneWidget);
      final before = (await t.runAsync(() => dao.read(old.id)))!.toRow();
      final attempts = (await t.runAsync(() => dao.attemptHistory(old.id)))!;
      await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
      await pump(t, 15);
      expect(transport.requests, isEmpty);
      expect((await t.runAsync(() => dao.read(old.id)))!.toRow(), before);
      expect((await t.runAsync(() => dao.attemptHistory(old.id)))!, attempts);
    } finally {
      await close(t);
    }
  });
  testWidgets(
      'explicit B atomically ends old parent; unknown attempt and other roles retained',
      (t) async {
    try {
      await open(t);
      final before = (await t.runAsync(() => dao.read(old.id)))!.toRow();
      await t.tap(find.byKey(const ValueKey('direct_recovery_choice')));
      await pump(t, 12);
      await t.tap(find.text('Service B · analysis').last);
      await pump(t, 12);
      expect(transport.requests, isEmpty);
      await t.tap(find.byKey(const ValueKey('direct_recovery_confirm')));
      await pump(t, 15);
      await until(
          t,
          () async =>
              (await dao.list(8)).length == 2 &&
              !coordinator.busy('account-a', (await dao.list(8)).first.id));
      final rows = (await t.runAsync(() => dao.list(8)))!;
      expect(rows.length, 2);
      final ended = (await t.runAsync(() => dao.read(old.id)))!;
      expect(ended.state, WorkflowState.cancelled);
      for (final entry in before.entries) {
        if (!{
          'state',
          'reason',
          'revision',
          'leaseId',
          'activeStepId',
          'updatedAt'
        }.contains(entry.key)) {
          expect(ended.toRow()[entry.key], entry.value);
        }
      }
      final attempts = (await t.runAsync(() => dao.attemptHistory(old.id)))!;
      expect(attempts.single['state'], 'unknown');
      expect(ended.dispatches, 1);
      expect(ended.reason, contains('timeout'));
      final fresh = rows.firstWhere((w) => w.id != old.id);
      final nodes = (await t.runAsync(() => dao.steps(fresh.id)))!;
      expect(nodes.map((s) => s.profile.providerId), ['B', 'A', 'A']);
      expect(transport.requests.length, 3);
      expect(settings.activeProviderId, 'A');
      expect(fresh.state, WorkflowState.complete);
    } finally {
      await close(t);
    }
  });
  testWidgets(
      'new parent insert failure rolls back explicit old end with no request',
      (t) async {
    try {
      await open(t);
      final before = (await t.runAsync(() => dao.read(old.id)))!.toRow();
      await t.runAsync(() => db.execute(
          "CREATE TRIGGER fail_confirmed_copy BEFORE INSERT ON ${AgentWorkflowDao.workflows} BEGIN SELECT RAISE(ABORT,'synthetic insertion failure'); END"));
      await t.tap(find.byKey(const ValueKey('direct_recovery_original')));
      await pump(t, 30);
      expect((await t.runAsync(() => dao.list(8)))!.length, 1);
      expect((await t.runAsync(() => dao.read(old.id)))!.toRow(), before);
      expect(transport.requests, isEmpty);
      expect(
          (await t.runAsync(() => dao.attemptHistory(old.id)))!.single['state'],
          'unknown');
    } finally {
      await close(t);
    }
  });
  for (final change in ['origin', 'parent']) {
    testWidgets('late $change confirmation creates no parent or request',
        (t) async {
      try {
        await open(t);
        if (change == 'origin') {
          BackendConfig.host = 'other.synthetic.invalid';
        } else {
          await t.runAsync(
              () => dao.stop(scope(), old.id, old.revision, reason: 'changed'));
        }
        await t.tap(find.byKey(const ValueKey('direct_recovery_original')));
        await pump(t, 25);
        expect((await t.runAsync(() => dao.list(8)))!.length, 1);
        expect(transport.requests, isEmpty);
        if (find
            .byKey(const ValueKey('direct_recovery_cancel'))
            .evaluate()
            .isNotEmpty) {
          await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
          await pump(t);
        }
      } finally {
        await close(t);
      }
    });
  }
}
