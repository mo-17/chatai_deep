import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/ai_readiness/ai_onboarding_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory owned, caseRoot;
  late DatabaseFactory? oldFactory;
  late String oldHost;
  late bool oldHttps;
  late HiDBManager storage;
  late AssistantDao assistantDao;
  late ConversationListDao conversationDao;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late AIReadinessProvider readiness;
  late PairTokens tokens;
  late ConversationGenerationService service;
  late ConversationModel conversation;
  AssistantModel? assistant;
  WidgetTester? active;
  int serial = 0;
  int probes = 0;
  Completer<void>? responseGate, postEntered, probeGate, probeEntered;
  bool revoked = false;
  final requests = <Map<String, dynamic>>[],
      observations = <Object>[],
      cleanup = <Object>[];
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  BackendSelection pair(String code,
          {String? origin, String account = 'account-a'}) =>
      BackendSelection.pair(
          providerCode: code,
          modelId: 'plain',
          accountHash: account,
          origin: origin ?? BackendConfig.buildUri('/uapi/ai/catalog').origin);
  setUpAll(() {
    owned = Directory(Platform.environment['R3B1_ROOT']!);
    final nonce = Platform.environment['R3B1_NONCE']!;
    expect(owned.path, '/tmp/chatai-r3b1-exclusive-owned-$nonce');
    expect(
        jsonDecode(
            File('${owned.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': nonce});
    sqfliteFfiInit();
  });
  setUp(() async {
    caseRoot = Directory('${owned.path}/case-${serial++}')..createSync();
    oldFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath('${caseRoot.path}/db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => caseRoot.path);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    AISettingsDao.resetSecureStateForTest();
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'backend.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'backend.synthetic.invalid';
    BackendConfig.useHttps = true;
    requests.clear();
    probes = 0;
    responseGate = null;
    probeGate = probeEntered = null;
    postEntered = null;
    revoked = false;
    assistant = null;
    service = ConversationGenerationService(
        observeApplication: false, createMemory: (_) async => null);
  });
  Future<void> pump(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 15));
    }
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 160 && !done(); i++) {
      await pump(t, 1);
    }
    expect(done(), isTrue, reason: 'bounded real SQLite/page settlement');
  }

  Future<void> init(WidgetTester t,
      {BackendSelection? c,
      BackendSelection? a,
      String? legacyC,
      String legacyA = '',
      bool hasAssistant = false}) async {
    active = t;
    await t.runAsync(() async {
      final global = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendSelection = pair('G')
        ..backendModel = 'global-old'
        ..streamEnabled = false
        ..composerPredictionsEnabled = false;
      await HiCache.getInstance().setString(
          AISettingsDao.keyFor('account-a'), jsonEncode(global.toJson()));
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
      storage = await HiDBManager.instance(dbName: 'account-a');
      assistantDao = await AssistantDao.create(storage);
      conversationDao = await ConversationListDao.create(storage);
      if (hasAssistant) {
        assistant = (await assistantDao.saveChecked(AssistantModel(
                name: 'SYNTHETIC',
                providerId: ' local-id ',
                model: legacyA,
                backendSelection: a,
                useTools: false)))
            .assistant;
      }
      conversation = ConversationModel(
          cid: 700,
          title: 'SYNTHETIC',
          icon: '',
          speechInputEnabled: false,
          modelProviderId: 'other-local',
          modelId: legacyC,
          backendSelection: c,
          assistantId: assistant?.id);
      conversation.id = await conversationDao.saveConversation(conversation);
    });
  }

  Widget shell(Widget child) => MultiProvider(providers: [
        ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
        ChangeNotifierProvider<AIReadinessProvider>.value(value: readiness),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme)
      ], child: MaterialApp(home: child));
  Future<void> conversationPage(WidgetTester t) async {
    await t.pumpWidget(shell(ConversationPage(
        conversationModel: conversation,
        generationService: service,
        readAloudService: const NoopReadAloudService(),
        draftStore: ConversationDraftStore(
            conversationId: '700',
            accountHash: 'account-a',
            directoryResolver: () async => caseRoot))));
    await until(
        t,
        () =>
            find.byType(MessageInputWidget).evaluate().isNotEmpty &&
            t
                .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                .enable);
  }

  Future<void> mocked(Future<void> Function() action) => http.runWithClient(
      action,
      () => MockClient((request) async {
            if (request.url.path == '/uapi/ai/model-selection') {
              probes++;
              if (probeEntered?.isCompleted == false) probeEntered!.complete();
              if (probeGate != null) await probeGate!.future;
              return http.Response(
                  jsonEncode({
                    'code': 0,
                    'data': {
                      'providerCode': 'B',
                      'modelId': request.url.queryParameters['modelId']
                    }
                  }),
                  200);
            }
            if (request.method == 'POST' &&
                request.url.path.contains('/chat/completions')) {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              requests.add(body);
              if (postEntered?.isCompleted == false) postEntered!.complete();
              if (responseGate != null) await responseGate!.future;
              expect(request.headers['Authorization'], 'Bearer synthetic-jwt');
              if (body['stream'] == true) {
                return http.Response(
                    'data: {"choices":[{"delta":{"content":"FINAL"}}]}\n\n'
                    'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}\n\n'
                    'data: [DONE]\n\n',
                    200,
                    headers: {'content-type': 'text/event-stream'});
              }
              return http.Response(
                  jsonEncode({
                    'code': 0,
                    'data': {
                      'content': 'FINAL',
                      'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
                    }
                  }),
                  200);
            }
            return http.Response(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'models': [
                      for (final code
                          in (revoked ? ['G', 'A', 'C'] : ['G', 'A', 'B', 'C']))
                        {
                          'providerCode': code,
                          'modelId': 'plain',
                          'displayName': 'plain',
                          'supportsVision': false,
                          'supportsTool': false,
                          'supportsReasoning': false,
                          'supportsPdf': false
                        },
                      for (final model in [
                        ' raw conversation / ',
                        ' raw assistant / '
                      ])
                        {
                          'providerCode': 'B',
                          'modelId': model,
                          'displayName': model,
                          'supportsVision': false,
                          'supportsTool': false,
                          'supportsReasoning': false,
                          'supportsPdf': false
                        },
                    ],
                    'providers': [
                      for (final code in ['G', 'A', 'B', 'C'])
                        {'code': code, 'displayName': 'Synthetic $code'}
                    ]
                  }
                }),
                200);
          }));
  Future<void> send(WidgetTester t) async {
    await t.enterText(
        find
            .descendant(
                of: find.byType(MessageInputWidget),
                matching: find.byType(TextField))
            .first,
        'RUN_INPUT');
    await t.pump();
    await t.tap(find.descendant(
        of: find.byType(MessageInputWidget),
        matching: find.byIcon(Icons.send)));
    await pump(t, 3);
  }

  Future<void> close(WidgetTester t) async {
    var stopped = false;
    final stopping = Future.wait(service.runs
        .where((r) => !r.retired)
        .map((r) => r.retire('fixture completion')));
    stopping.then((_) => stopped = true);
    await until(t, () => stopped);
    await stopping;
    await t.pumpWidget(const SizedBox.shrink());
    await pump(t, 8);
    var idle = false;
    final waiting = ConversationDraftStore(
        conversationId: '700',
        accountHash: 'account-a',
        directoryResolver: () async => caseRoot).whenIdle();
    waiting.then((_) => idle = true);
    await until(t, () => idle);
    await waiting;
  }

  tearDown(() async {
    await active!.runAsync(() async {
      expect(service.runs.every((r) => r.ticket.released), isTrue);
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
          .setMockMethodCallHandler(channel, null);
      BackendConfig.host = oldHost;
      BackendConfig.useHttps = oldHttps;
      databaseFactory = oldFactory;
      cleanup.add({'case': caseRoot.path, 'sqliteClosed': true});
    });
    active = null;
  });
  tearDownAll(() {
    File('${owned.path}/page-evidence.json')
        .writeAsStringSync(jsonEncode(observations));
    File('${owned.path}/cleanup.json').writeAsStringSync(
        jsonEncode({'allClosed': true, 'resources': cleanup}));
  });
  for (final legacy in [false, true]) {
    testWidgets(
        'single Agent actual backend task ${legacy ? "legacy" : "modern"} fixed pair and usage',
        (t) async {
      try {
        await mocked(() async {
          await init(t,
              c: legacy ? null : pair('C'),
              legacyC: legacy ? ' raw conversation / ' : 'ignored-old');
          await t.runAsync(() async {
            final session = AgentTaskSession(
                cid: 700, store: await AgentTaskDao.create(storage));
            await session.setEnabled(true);
            await session.setBackgroundEnabled(false);
            session.dispose();
          });
          await conversationPage(t);
          await send(t);
          await until(
              t,
              () =>
                  AgentTaskExecutor.instance
                          .lookup(const AgentTaskKey('account-a', 700)) !=
                      null &&
                  !AgentTaskExecutor.instance
                      .lookup(const AgentTaskKey('account-a', 700))!
                      .busy);
          final code = legacy ? 'B' : 'C';
          expect(requests, hasLength(1));
          expect(requests.single['providerCode'], code);
          expect(requests.single['model'],
              legacy ? ' raw conversation / ' : 'plain');
          expect(probes, legacy ? 1 : 0);
          final rows = (await t.runAsync(() => storage.db.query('tb_usage')))!;
          expect(rows, hasLength(1));
          expect(
              rows.single['providerId'],
              'backend:${jsonEncode([
                    'https://backend.synthetic.invalid',
                    code
                  ])}');
          final stored = AgentTaskSession(
              cid: 700,
              store: (await t.runAsync(() => AgentTaskDao.create(storage)))!);
          await t.runAsync(stored.load);
          final snapshot = (await t.runAsync(
              () async => (await AgentTaskDao.create(storage)).read(700)))!;
          expect((snapshot['backendRequestSelection'] as Map?)?['providerCode'],
              code);
          stored.dispose();
        });
      } finally {
        await t.runAsync(
            () => AgentTaskExecutor.instance.cancelAll('fixture complete'));
        await close(t);
      }
    });
  }
  for (final change in ['account', 'origin']) {
    testWidgets(
        'single Agent legacy GET late $change creates no attempt or model POST',
        (t) async {
      try {
        await mocked(() async {
          await init(t, legacyC: ' raw conversation / ');
          await t.runAsync(() async {
            final session = AgentTaskSession(
                cid: 700, store: await AgentTaskDao.create(storage));
            await session.setEnabled(true);
            await session.setBackgroundEnabled(false);
            session.dispose();
          });
          await conversationPage(t);
          probeGate = Completer();
          probeEntered = Completer();
          await send(t);
          await until(t, () => probeEntered!.isCompleted);
          if (change == 'account') {
            tokens.account = 'account-b';
          } else {
            BackendConfig.host = 'other.synthetic.invalid';
          }
          probeGate!.complete();
          await pump(t, 25);
          expect(requests, isEmpty);
          expect(probes, 1);
          final rows = (await t.runAsync(() => storage.db.query('tb_usage')))!;
          expect(rows, isEmpty);
          expect(tokens.clears, 0);
        });
      } finally {
        if (probeGate?.isCompleted == false) probeGate!.complete();
        await close(t);
      }
    });
  }
}
