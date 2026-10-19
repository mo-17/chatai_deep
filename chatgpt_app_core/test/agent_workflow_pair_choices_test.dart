import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_workflow_page.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;
import 'agent_workflow_foundation_test.dart' show FakeWorkflowBackground;

List<WorkflowModelChoice> choices(AISettings s, AiCatalogIdentity identity) {
  try {
    return Function.apply(
            AgentWorkflowModels.choices, [s], {#backendIdentity: identity})
        as List<WorkflowModelChoice>;
  } on NoSuchMethodError {
    return AgentWorkflowModels.choices(s);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database db;
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late AgentWorkflowCoordinator coordinator;
  late PairTokens tokens;
  late AISettings settings;
  late String oldHost;
  late bool oldHttps;
  WidgetTester? active;
  int serial = 0, posts = 0, gets = 0, epoch = 0;
  Completer<void>? loadGate, entered;
  bool fresh = true;
  final cleanup = <Map<String, Object?>>[];
  const cid = 1;
  const rawModel = 'same:/ raw';
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'account-a',
      currentAccount: () => tokens.account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => BackupService.agentExecutionRevision);
  BackendSelection pair(String code) => BackendSelection.pair(
      providerCode: code,
      modelId: rawModel,
      accountHash: 'account-a',
      origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
  Future<void> pump(WidgetTester t, [int count = 5]) async {
    for (var i = 0; i < count; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 90 && !done(); i++) {
      await pump(t, 1);
    }
    expect(done(), true, reason: 'bounded actual page settlement');
  }

  Future<void> open(WidgetTester t, {String? parent}) async {
    active = t;
    await t.binding.setSurfaceSize(const Size(900, 1400));
    await t.runAsync(() => t.pumpWidget(MaterialApp(
        home: AgentWorkflowPage(
            conversation: parent == null
                ? ConversationModel(cid: cid, title: 'synthetic', icon: '')
                : null,
            parentId: parent,
            expectedAccountHash: 'account-a',
            storage: storage,
            scope: scope(),
            coordinator: coordinator,
            loadSettings: () async {
              if (entered?.isCompleted == false) entered!.complete();
              if (loadGate != null) await loadGate!.future;
              return settings.clone();
            }))));
    await pump(t, 6);
  }

  DropdownButtonFormField<String> field(WidgetTester t, WorkflowRole role) =>
      t.widget(find.byKey(ValueKey('workflow-profile-${role.name}')));
  Future<void> select(WidgetTester t, WorkflowRole role, String code) async {
    final f = find.byKey(ValueKey('workflow-profile-${role.name}'));
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
    final label = '后端代理 · Synthetic $code ($code) · $rawModel';
    await t.tap(find.text(label).last);
    await t.pumpAndSettle();
  }

  Future<void> mocked(Future<void> Function() body) =>
      http.runWithClient(() async {
        try {
          if (fresh) await ModelCatalog.refreshFromBackend();
          await body();
        } finally {
          if (loadGate?.isCompleted == false) loadGate!.complete();
          if (active != null) {
            await active!.pumpWidget(const SizedBox.shrink());
            await pump(active!);
            active = null;
          }
        }
      },
          () => MockClient((r) async {
                if (r.method != 'GET' || r.url.path != '/uapi/ai/catalog') {
                  posts++;
                  throw StateError(
                      'no model transport or resolver GET in selector batch');
                }
                gets++;
                expect(r.url.host, 'workflow.synthetic.invalid');
                return http.Response(
                    jsonEncode({
                      'code': 0,
                      'data': {
                        'providers': [
                          for (final p in ['A', 'B'])
                            {'code': p, 'displayName': 'Synthetic $p'}
                        ],
                        'models': [
                          for (final p in ['A', 'B'])
                            {
                              'providerCode': p,
                              'modelId': rawModel,
                              'displayName': rawModel,
                              'supportsTool': false,
                              'supportsVision': false,
                              'supportsReasoning': false,
                              'supportsPdf': false
                            }
                        ]
                      }
                    }),
                    200);
              }));
  setUpAll(() {
    root = Directory(Platform.environment['R3B4_ROOT']!);
    expect(root.path,
        '/tmp/chatai-r3b4-owned-${Platform.environment['R3B4_NONCE']}');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': Platform.environment['R3B4_NONCE']});
    sqfliteFfiInit();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
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
    ModelCatalog.resetExecutionForTest();
    db = await databaseFactoryFfi
        .openDatabase('${root.path}/case-${serial++}.sqlite');
    storage = HiDBManager.test(db);
    await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: cid, title: 'synthetic', icon: ''));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'account-a');
    coordinator = AgentWorkflowCoordinator(
        channel: AgentExecutionChannel(),
        background: FakeWorkflowBackground(),
        foreground: () => true,
        observeApplication: false);
    settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..providers = []
      ..backendSelection = pair('A')
      ..backendModel = rawModel;
    epoch = 1;
    posts = gets = 0;
    fresh = true;
    loadGate = entered = null;
  });
  tearDown(() async {
    expect(active, isNull);
    await db.close();
    cleanup.add({
      'case': serial,
      'closed': !db.isOpen,
      'posts': posts,
      'catalogGets': gets,
      'logout': tokens.clears
    });
    expect(posts, 0);
    expect(tokens.clears, 0);
    coordinator.dispose();
    LoginSdkConfig.reset();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() {
    File('${root.path}/selector-evidence.json')
        .writeAsStringSync(jsonEncode(cleanup));
    File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
      'allSqliteClosed': cleanup.every((x) => x['closed'] == true),
      'cases': cleanup.length,
      'modelPOST0': cleanup.every((x) => x['posts'] == 0)
    }));
  });
  testWidgets(
      'typed choices A/B same raw id have distinct keys and profiles',
      (t) async => mocked(() async {
            final rows = choices(settings, AiCatalogIdentity.capture())
                .where((c) => c.profile.mode == 'backend')
                .toList();
            expect(rows.length, 2);
            expect(rows.map((c) => c.key).toSet().length, 2);
            expect(rows.map((c) => c.profile.providerCode).toSet(), {'A', 'B'});
            for (final c in rows) {
              expect(c.profile.modelId, rawModel);
              expect(c.profile.backendSelection!.origin,
                  BackendConfig.buildUri('/uapi/ai/catalog').origin);
              expect(c.key, c.profile.selectionKey);
              expect(c.label, contains('(${c.profile.providerCode})'));
            }
            await open(t);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('workflow-profile-analysis'))
                    .evaluate()
                    .isNotEmpty);
            for (final r in WorkflowRole.values) {
              expect(field(t, r).initialValue, isNull);
            }
          }));
  testWidgets(
      'actual page independent role pair selection does not save defaults or start transport',
      (t) async => mocked(() async {
            await open(t);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('workflow-profile-analysis'))
                    .evaluate()
                    .isNotEmpty);
            await select(t, WorkflowRole.analysis, 'A');
            await select(t, WorkflowRole.writing, 'B');
            await select(t, WorkflowRole.review, 'A');
            expect(field(t, WorkflowRole.analysis).initialValue,
                WorkflowModelProfile.backend(pair('A')).selectionKey);
            expect(field(t, WorkflowRole.writing).initialValue,
                WorkflowModelProfile.backend(pair('B')).selectionKey);
            expect(field(t, WorkflowRole.review).initialValue,
                WorkflowModelProfile.backend(pair('A')).selectionKey);
            expect(settings.backendSelection!.providerCode, 'A');
            expect(await t.runAsync(() => dao.list(cid)), isEmpty);
            expect(posts, 0);
            // b2 的明确开始链路由实际 consumer page fixture 验证；选择本身不启动。
            expect(
                t
                    .widget<FilledButton>(
                        find.byKey(const ValueKey('workflow-start')))
                    .onPressed,
                isNull);
          }));
  testWidgets(
      'actual DAO stores three selected pairs and modern claim stays guarded',
      (t) async => mocked(() async {
            final rows = choices(settings, AiCatalogIdentity.capture())
                .where((c) => c.profile.mode == 'backend')
                .toList();
            expect(rows.every((c) => c.profile.backendSelection != null), true);
            final profiles = {
              WorkflowRole.analysis:
                  rows.firstWhere((c) => c.profile.providerCode == 'A').profile,
              WorkflowRole.writing:
                  rows.firstWhere((c) => c.profile.providerCode == 'B').profile,
              WorkflowRole.review:
                  rows.firstWhere((c) => c.profile.providerCode == 'A').profile
            };
            final s = scope();
            final fingerprint =
                await t.runAsync(() => dao.captureConversation(s, cid));
            final w = (await t.runAsync(() => dao.createFromSource(s,
                cid: cid,
                newTask: 'synthetic',
                newUserCreatedAt: 1,
                expectedConversationFingerprint: fingerprint,
                profiles: profiles,
                acceptance:
                    const TaskAcceptanceCriteria(requireFullRead: false))))!;
            final nodes = (await t.runAsync(() => dao.steps(w.id)))!;
            expect(nodes.map((n) => n.profile.providerCode).toList(),
                ['A', 'B', 'A']);
            expect(nodes.every((n) => n.profile.modelId == rawModel), true);
            final error = await t.runAsync(() async {
              try {
                await dao.claim(s, w.id, w.revision);
                return null;
              } catch (e) {
                return e;
              }
            });
            expect(error, isA<WorkflowStale>());
            expect((await t.runAsync(() => dao.read(w.id)))!.dispatches, 0);
            expect(await t.runAsync(() => dao.attemptHistory(w.id)), isEmpty);
            await open(t, parent: w.id);
            await pump(t, 10);
            expect(find.textContaining('Synthetic B (B) · $rawModel'),
                findsOneWidget);
          }));
  testWidgets(
      'tuple key local colon collision is removed without changing local profiles',
      (t) async => mocked(() async {
            settings
              ..mode = AIMode.local
              ..providers = [
                AiProvider(
                    id: 'a:b',
                    name: 'one',
                    type: 'openai',
                    apiKey: 'synthetic',
                    enabled: true,
                    models: [AiModel(id: 'c')]),
                AiProvider(
                    id: 'a',
                    name: 'two',
                    type: 'openai',
                    apiKey: 'synthetic',
                    enabled: true,
                    models: [AiModel(id: 'b:c')])
              ];
            final rows = choices(settings, AiCatalogIdentity.capture())
                .where((c) => c.profile.mode == 'local')
                .toList();
            expect(rows.length, 2);
            expect(rows.map((c) => c.key).toSet().length, 2);
            expect(rows[0].profile.providerId, 'a:b');
            expect(rows[1].profile.modelId, 'b:c');
            await open(t);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('workflow-profile-analysis'))
                    .evaluate()
                    .isNotEmpty);
            expect(field(t, WorkflowRole.analysis).initialValue,
                rows.first.profile.selectionKey);
          }));
  testWidgets(
      'no owned catalog does not stamp hardcoded or old unscoped ids as pair',
      (t) async {
    fresh = false;
    await mocked(() async {
      HiCache.getInstance().setString(
          'ai_catalog_v1',
          jsonEncode({
            'models': [
              {'providerCode': 'OTHER', 'modelId': 'legacy'}
            ]
          }));
      ModelCatalog.loadFromCache();
      final rows = choices(settings, AiCatalogIdentity.capture());
      expect(rows.where((c) => c.profile.mode == 'backend'), isEmpty);
      await open(t);
      await until(
          t,
          () => find
              .byKey(const ValueKey('workflow-profile-analysis'))
              .evaluate()
              .isNotEmpty);
      expect(field(t, WorkflowRole.analysis).initialValue, isNull);
      expect(find.textContaining('后端代理 ·'), findsNothing);
    });
  });
  for (final change in [
    'origin',
    'token',
    'epoch',
    'restore',
    'account',
    'storage'
  ]) {
    testWidgets(
        'load await $change does not replace original backend scope',
        (t) async => mocked(() async {
              loadGate = Completer();
              entered = Completer();
              await open(t);
              await until(t, () => entered!.isCompleted);
              switch (change) {
                case 'origin':
                  BackendConfig.host = 'other.synthetic.invalid';
                case 'token':
                  tokens.token = 'different';
                case 'epoch':
                  ModelCatalog.resetExecutionForTest();
                case 'restore':
                  BackupService.agentExecutionRevision++;
                case 'account':
                  tokens.account = 'account-b';
                case 'storage':
                  LoginSdkConfig.install(LoginSdkConfig(
                      baseUrl: 'workflow.synthetic.invalid',
                      headerProvider: () async => {},
                      syncHeaders: () => {},
                      routes: LoginRoutes.imooc,
                      responseAdapter: ImoocResponseAdapter(),
                      storage: PairTokens(),
                      onLogoutNavigate: () {}));
              }
              loadGate!.complete();
              await pump(t, 10);
              final finder =
                  find.byKey(const ValueKey('workflow-profile-analysis'));
              if (finder.evaluate().isNotEmpty) {
                expect(field(t, WorkflowRole.analysis).initialValue, isNull);
              }
              expect(find.textContaining('后端代理 ·'), findsNothing);
              expect(find.textContaining('重新打开'), findsOneWidget);
              expect(await t.runAsync(() => dao.list(cid)), isEmpty);
              expect(posts, 0);
            }));
  }
  testWidgets(
      'open dropdown origin change rejects late backend item',
      (t) async => mocked(() async {
            await open(t);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('workflow-profile-analysis'))
                    .evaluate()
                    .isNotEmpty);
            final f = find.byKey(const ValueKey('workflow-profile-analysis'));
            await t.tap(f);
            await t.pumpAndSettle();
            BackendConfig.host = 'other.synthetic.invalid';
            await t.tap(find.text('后端代理 · Synthetic A (A) · $rawModel').last);
            await t.pumpAndSettle();
            expect(field(t, WorkflowRole.analysis).initialValue, isNull);
            expect(t.state<FormFieldState<String>>(f).value, isNull);
            expect(await t.runAsync(() => dao.list(cid)), isEmpty);
            expect(posts, 0);
          }));
}
