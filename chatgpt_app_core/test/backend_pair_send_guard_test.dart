import 'support/owned_test_directory.dart';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_ready_state.dart';
import 'package:chatgpt_app_core/ai_readiness/ai_send_guard.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/ai_settings_page.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_readiness_provider.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;
import 'support/fake_composer_chat.dart';

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3A2_ROOT',
    nonceKey: 'R3A2_NONCE',
    legacyPrefix: '/tmp/chatai-r3a2-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reason in [
    'invalid_backend_selection',
    'backend_scope_changed',
    'model_unavailable'
  ]) {
    test('grandfathered modern $reason blocks with configure action', () {
      final decision = resolveAISendGuard(
          state: AIReadyState(
              status: AIReadyStatus.needsSetup, reasonCode: reason),
          onboardingStatus: AIOnboardingStatus.grandfathered);
      expect(decision.allowed, isFalse);
      expect(decision.reasonCode, reason);
      expect(decision.action, AISendGuardAction.configure);
    });
  }
  test(
      'legacy/local grandfathered behavior and exact reason classification remain',
      () {
    for (final reason in [
      'missing_model',
      'missing_api_key',
      'provider_disabled',
      'model_unverified',
      'prefix_model_unavailable',
      'model_unavailable_suffix'
    ]) {
      final decision = resolveAISendGuard(
          state: AIReadyState(
              status: AIReadyStatus.needsSetup, reasonCode: reason),
          onboardingStatus: AIOnboardingStatus.grandfathered);
      expect(decision.allowed, isTrue);
      expect(decision.reasonCode, 'legacy_account_passthrough');
    }
  });
  group('actual ConversationPage send entry', () {
    late Directory owned, caseRoot;
    late DatabaseFactory? oldFactory;
    late String oldHost;
    late bool oldHttps;
    late AISettingsProvider settings;
    late AIReadinessProvider readiness;
    late ThemeProvider theme;
    late HiDBManager storage;
    late ConversationGenerationService service;
    late FakeComposerChat chat;
    late ConversationModel conversation;
    WidgetTester? activeTester;
    int serial = 0, modelPosts = 0;
    final cleanup = <Object>[];
    final observations = <Object>[];
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    setUpAll(() {
      owned = ownedFixture.directory;
      sqfliteFfiInit();
    });
    setUp(() async {
      caseRoot = Directory('${owned.path}/case-${serial++}')..createSync();
      oldFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.setDatabasesPath('${caseRoot.path}/db');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (_) async => caseRoot.path);
      LoginDao.resetHooksForTest();
      ModelCatalog.resetExecutionForTest();
      SharedPreferences.setMockInitialValues({});
      await HiCache.preInit();
      await HiCache.getInstance().prefs!.clear();
      AISettingsDao.resetSecureStateForTest();
      LoginSdkConfig.install(LoginSdkConfig(
          baseUrl: 'catalog.synthetic.invalid',
          headerProvider: () async => {},
          syncHeaders: () => {},
          routes: LoginRoutes.imooc,
          responseAdapter: ImoocResponseAdapter(),
          storage: PairTokens(),
          onLogoutNavigate: () {}));
      oldHost = BackendConfig.host;
      oldHttps = BackendConfig.useHttps;
      BackendConfig.host = 'catalog.synthetic.invalid';
      BackendConfig.useHttps = true;
      modelPosts = 0;
      chat = FakeComposerChat();
      service = ConversationGenerationService(
          observeApplication: false,
          createChat: (_) => chat,
          createMemory: (_) async => null);
    });
    Future<void> pump(WidgetTester t, [int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 10));
      }
    }

    Future<void> mount(WidgetTester t, String kind) async {
      activeTester = t;
      await t.runAsync(() async {
        final selected = AISettings.defaults()
          ..mode = AIMode.backend
          ..backendModel = 'plain';
        if (kind == 'invalid_backend_selection') {
          selected.backendSelection =
              BackendSelection.fromStorage({'version': 99}, allowFollow: false);
        } else if (kind == 'backend_scope_changed') {
          selected.backendSelection = BackendSelection.pair(
              providerCode: 'A',
              modelId: 'plain',
              accountHash: 'foreign-account',
              origin: 'https://catalog.synthetic.invalid');
        } else if (kind == 'model_unavailable') {
          selected.backendSelection = BackendSelection.pair(
              providerCode: 'B',
              modelId: 'plain',
              accountHash: 'account-a',
              origin: 'https://catalog.synthetic.invalid');
        } else if (kind == 'legacy') {
          selected.backendModel = '';
        } else if (kind == 'local') {
          selected.mode = AIMode.local;
          selected.activeProvider.apiKey = '';
        }
        await HiCache.getInstance().setString(
            AISettingsDao.keyFor('account-a'), jsonEncode(selected.toJson()));
        settings = AISettingsProvider();
        theme = ThemeProvider();
        await ModelCatalog.refreshFromBackend();
        readiness = AIReadinessProvider(
            evidenceReader: (
                    {required accountHash, required settings, storage}) async =>
                const AIOnboardingEvidence(
                    hasStoredSettings: true,
                    hasConversationHistory: false,
                    hasCustomProvider: false,
                    hasSuccessfulHealthCheck: false));
        readiness.synchronize(
            settings: settings.settings,
            accountHash: 'account-a',
            isGuest: false);
        await readiness.initialize();
        expect(readiness.onboardingStatus, AIOnboardingStatus.grandfathered);
        if (kind != 'legacy' && kind != 'local') {
          expect(readiness.state.reasonCode, kind);
        }
        storage = await HiDBManager.instance(dbName: 'account-a');
        final dao = await ConversationListDao.create(storage);
        conversation = ConversationModel(
            cid: 700, title: 'SYNTHETIC', icon: '', speechInputEnabled: false);
        conversation.id = await dao.saveConversation(conversation);
        await t.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
              ChangeNotifierProvider<AIReadinessProvider>.value(
                  value: readiness),
              ChangeNotifierProvider<ThemeProvider>.value(value: theme),
            ],
            child: MaterialApp(
                home: ConversationPage(
                    conversationModel: conversation,
                    generationService: service,
                    chatService: chat,
                    readAloudService: const NoopReadAloudService(),
                    draftStore: ConversationDraftStore(
                        conversationId: '700',
                        accountHash: 'account-a',
                        directoryResolver: () async => caseRoot)))));
      });
      for (var i = 0; i < 70; i++) {
        await pump(t, 1);
        final input = find.byType(MessageInputWidget);
        if (input.evaluate().isNotEmpty &&
            t.widget<MessageInputWidget>(input).enable) {
          return;
        }
      }
      fail(
          'actual page did not enable its synthetic composer within bounded wait');
    }

    Future<void> mocked(Future<void> Function() action) => http.runWithClient(
        action,
        () => MockClient((request) async {
              if (request.method == 'POST' &&
                  request.url.path.contains('/chat/completions')) {
                modelPosts++;
              }
              return http.Response(
                  jsonEncode({
                    'code': 0,
                    'data': {
                      'models': [
                        {
                          'providerCode': 'A',
                          'modelId': 'plain',
                          'displayName': 'plain',
                          'supportsVision': false,
                          'supportsTool': false,
                          'supportsReasoning': false,
                          'supportsPdf': false
                        }
                      ]
                    }
                  }),
                  200);
            }));
    Future<void> send(WidgetTester t) async {
      final text = find
          .descendant(
              of: find.byType(MessageInputWidget),
              matching: find.byType(TextField))
          .first;
      await t.enterText(text, 'SYNTHETIC_DRAFT');
      await t.pump();
      await t.tap(find.descendant(
          of: find.byType(MessageInputWidget),
          matching: find.byIcon(Icons.send)));
      await pump(t);
    }

    Future<void> waitFor(WidgetTester t, bool Function() done) async {
      for (var i = 0; i < 150 && !done(); i++) {
        await pump(t, 1);
      }
      expect(done(), isTrue,
          reason: 'bounded widget pump and real SQLite settlement');
    }

    Future<void> closePage(WidgetTester t) async {
      var stopped = false;
      final stopping = Future.wait(service.runs
          .where((run) => !run.retired)
          .map((run) => run.retire('fixture completion')));
      stopping.then((_) => stopped = true);
      await waitFor(t, () => stopped);
      await stopping;
      await t.pumpWidget(const SizedBox.shrink());
      await pump(t, 8);
      var idle = false;
      final waiting = ConversationDraftStore(
          conversationId: '700',
          accountHash: 'account-a',
          directoryResolver: () async => caseRoot).whenIdle();
      waiting.then((_) => idle = true);
      await waitFor(t, () => idle);
      await waiting;
    }

    tearDown(() async {
      Future<void> cleanupNow() async {
        expect(service.runs.every((run) => run.ticket.released), isTrue,
            reason: 'test body already awaited retirement and draft queue');
        expect(storage.db.path.startsWith(caseRoot.path), isTrue);
        service.dispose();
        await HiDBManager.closeAll();
        expect(storage.db.isOpen, isFalse);
        settings.dispose();
        readiness.dispose();
        theme.dispose();
        LoginDao.resetHooksForTest();
        LoginSdkConfig.reset();
        AISettingsDao.resetSecureStateForTest();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathChannel, null);
        BackendConfig.host = oldHost;
        BackendConfig.useHttps = oldHttps;
        databaseFactory = oldFactory;
        cleanup.add({
          'case': caseRoot.path,
          'sqliteClosed': true,
          'modelPosts': modelPosts
        });
      }

      if (activeTester != null) {
        await activeTester!.runAsync(cleanupNow);
      } else {
        await cleanupNow();
      }
      activeTester = null;
    });
    tearDownAll(() {
      expect(cleanup, hasLength(5));
      File('${owned.path}/guard-page-evidence.json')
          .writeAsStringSync(jsonEncode(observations));
      File('${owned.path}/cleanup.json').writeAsStringSync(
          jsonEncode({'allClosed': true, 'pageResources': cleanup}));
    });
    for (final reason in [
      'invalid_backend_selection',
      'backend_scope_changed',
      'model_unavailable'
    ]) {
      testWidgets(
          'grandfathered page $reason blocks actual send and opens configuration, zero run/model request',
          (t) async {
        try {
          await mocked(() async {
            await mount(t, reason);
            await send(t);
            observations.add({
              'kind': reason,
              'grandfathered': readiness.onboardingStatus ==
                  AIOnboardingStatus.grandfathered,
              'reason': readiness.state.reasonCode,
              'dialog': find.byType(AlertDialog).evaluate().isNotEmpty,
              'generationRuns': service.runs.length,
              'fakeChatCalls': chat.calls,
              'modelPosts': modelPosts
            });
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(find.byKey(const ValueKey('ai_send_guard_primary')),
                findsOneWidget);
            expect(find.text('去配置'), findsOneWidget);
            expect(service.runs, isEmpty);
            expect(chat.calls, 0);
            expect(modelPosts, 0);
            expect(
                t
                    .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                    .controller!
                    .text,
                'SYNTHETIC_DRAFT');
            await t.tap(find.byKey(const ValueKey('ai_send_guard_primary')));
            await pump(t, 30);
            expect(find.byType(AISettingsPage), findsOneWidget);
            expect(service.runs, isEmpty);
            expect(chat.calls, 0);
            expect(modelPosts, 0);
            expect(t.takeException(), isNull);
          });
        } finally {
          await closePage(t);
        }
      });
    }
    for (final kind in ['legacy', 'local']) {
      testWidgets(
          'grandfathered page preserves $kind compatibility at actual send gate',
          (t) async {
        try {
          await mocked(() async {
            await mount(t, kind);
            await send(t);
            observations.add({
              'kind': kind,
              'grandfathered': readiness.onboardingStatus ==
                  AIOnboardingStatus.grandfathered,
              'reason': readiness.state.reasonCode,
              'dialog': find.byType(AlertDialog).evaluate().isNotEmpty,
              'generationRuns': service.runs.length,
              'fakeChatCalls': chat.calls,
              'modelPosts': modelPosts
            });
            expect(find.byKey(const ValueKey('ai_send_guard_primary')),
                findsNothing);
            expect(service.runs, isNotEmpty);
            expect(modelPosts, 0);
            expect(t.takeException(), isNull);
          });
        } finally {
          await closePage(t);
        }
      });
    }
  });
}
