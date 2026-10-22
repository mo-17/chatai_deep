import 'support/owned_test_directory.dart';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
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
import 'package:chatgpt_app_core/model/ai_provider.dart';
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

class _OwnedLoopbackHTTP extends HttpOverrides {}

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B4_ROOT',
    nonceKey: 'R3B4_NONCE',
    legacyPrefix: '/tmp/chatai-r3b4-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory owned, caseRoot;
  late DatabaseFactory? oldFactory;
  late String oldHost;
  late bool oldHttps;
  late HiDBManager storage;
  HttpServer? server;
  bool partial = false;
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
  Completer<void>? responseGate, postEntered;
  bool revoked = false;
  final requests = <Map<String, dynamic>>[],
      observations = <Object>[],
      cleanup = <Object>[];
  const channel = MethodChannel('plugins.flutter.io/path_provider');
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
    partial = false;
    probes = 0;
    responseGate = null;
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
    expect(done(), isTrue,
        reason:
            'bounded real SQLite/page settlement: ${t.widgetList<Text>(find.byType(Text)).map((w) => w.data).whereType<String>().join(" | ")}');
  }

  Future<void> init(WidgetTester t,
      {BackendSelection? c,
      BackendSelection? a,
      String? legacyC,
      String legacyA = '',
      bool hasAssistant = false}) async {
    active = t;
    await t.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((r) async {
        final body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, dynamic>;
        requests.add({...body, 'fixturePath': r.uri.path});
        if (r.uri.path.contains('/A/')) {
          if (partial && body['stream'] == true) {
            r.response.headers.contentType =
                ContentType('text', 'event-stream');
            r.response.write(
                'data: {"choices":[{"delta":{"content":"OLD PARTIAL"}}]}\n\n'
                'data: {"error":{"message":"synthetic raw secret"}}\n\n');
          } else {
            r.response.statusCode = 503;
            r.response.write('{"error":{"message":"synthetic raw secret"}}');
          }
        } else if (body['stream'] == true) {
          r.response.headers.contentType = ContentType('text', 'event-stream');
          r.response.write(
              'data: {"choices":[{"delta":{"content":"NEW SUCCESS"}}]}\n\ndata: [DONE]\n\n');
        } else {
          r.response
              .write('{"choices":[{"message":{"content":"NEW SUCCESS"}}]}');
        }
        await r.response.close();
      });
      final global = AISettings.defaults()
        ..mode = AIMode.local
        ..activeProviderId = 'A'
        ..providers = [
          for (final p in ['A', 'B'])
            AiProvider(
                id: p,
                name: 'Service $p',
                type: 'openai',
                enabled: true,
                apiKey: 'synthetic-$p',
                apiHost: 'http://127.0.0.1:${server!.port}/$p/v1',
                models: [AiModel(id: 'plain')],
                selectedModelId: 'plain')
        ]
        ..streamEnabled = false
        ..composerPredictionsEnabled = false;
      await HiCache.getInstance().setString(
          AISettingsDao.keyFor('account-a'), jsonEncode(global.toJson()));
      settings = AISettingsProvider();
      theme = ThemeProvider();

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
          modelProviderId: 'A',
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

  Future<void> mocked(Future<void> Function() action) =>
      HttpOverrides.runWithHttpOverrides(
          () => http.runWithClient(
              action,
              () => MockClient((request) async {
                    if (request.url.path == '/uapi/ai/model-selection') {
                      probes++;
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
                      final body =
                          jsonDecode(request.body) as Map<String, dynamic>;
                      requests.add(body);
                      if (postEntered?.isCompleted == false) {
                        postEntered!.complete();
                      }
                      if (responseGate != null) await responseGate!.future;
                      expect(request.headers['Authorization'],
                          'Bearer synthetic-jwt');
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
                              'usage': {
                                'prompt_tokens': 10,
                                'completion_tokens': 5
                              }
                            }
                          }),
                          200);
                    }
                    return http.Response(
                        jsonEncode({
                          'code': 0,
                          'data': {
                            'models': [
                              for (final code in (revoked
                                  ? ['G', 'A', 'C']
                                  : ['G', 'A', 'B', 'C']))
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
                  })),
          _OwnedLoopbackHTTP());
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
      await server?.close(force: true);
      server = null;
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

  Future<void> failed(WidgetTester t,
      {bool task = false, bool stream = false}) async {
    await init(t);
    settings.settings.streamEnabled = stream;
    if (task) {
      await t.runAsync(() async {
        final session = AgentTaskSession(
            cid: 700, store: await AgentTaskDao.create(storage));
        await session.setEnabled(true);
        await session.setBackgroundEnabled(false);
        session.dispose();
      });
    }
    await conversationPage(t);
    await send(t);
    await until(
        t,
        () => find
            .byKey(const ValueKey('direct_recovery_cancel'))
            .evaluate()
            .isNotEmpty);
    expect(requests.length, 1);
    expect(probes, 0);
    expect(find.textContaining('synthetic raw secret'), findsNothing);
  }

  Future<void> chooseB(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('direct_recovery_choice')));
    await pump(t, 12);
    await t.tap(find.text('Service B · plain').last);
    await pump(t, 12);
    expect(requests.length, 1);
    await t.tap(find.byKey(const ValueKey('direct_recovery_confirm')));
    await pump(t, 12);
  }

  for (final task in [false, true]) {
    testWidgets(
        '${task ? "single Agent" : "ordinary"} local fail cancel leaves one POST',
        (t) async {
      try {
        await mocked(() async {
          await failed(t, task: task);
          await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
          await pump(t, 15);
          expect(requests.length, 1);
          expect(settings.settings.activeProviderId, 'A');
        });
      } finally {
        await close(t);
      }
    });
    testWidgets(
        '${task ? "single Agent" : "ordinary"} explicit B is one new request and does not save global',
        (t) async {
      try {
        await mocked(() async {
          await failed(t, task: task);
          await chooseB(t);
          await until(t, () => requests.length == 2);
          await pump(t, 20);
          expect(requests.last['fixturePath'], contains('/B/'));
          expect(settings.settings.activeProviderId, 'A');
          expect(probes, 0);
        });
      } finally {
        await close(t);
      }
    });
  }
  testWidgets('ordinary partial old output persists and B reply is a new row',
      (t) async {
    try {
      await mocked(() async {
        partial = true;
        await failed(t, stream: true);
        final before =
            (await t.runAsync(() => storage.db.query('tb_messages')))!;
        expect(before.any((r) => r['content'] == 'OLD PARTIAL'), true);
        await chooseB(t);
        await until(t, () => requests.length == 2);
        await pump(t, 25);
        final after =
            (await t.runAsync(() => storage.db.query('tb_messages')))!;
        expect(after.any((r) => r['content'] == 'OLD PARTIAL'), true);
        expect(after.any((r) => r['content'] == 'NEW SUCCESS'), true);
      });
    } finally {
      await close(t);
    }
  });
  testWidgets('ordinary configuration changed in dialog prevents new POST',
      (t) async {
    try {
      await mocked(() async {
        await failed(t);
        settings.settings.providers.first.enabled = false;
        await t.tap(find.byKey(const ValueKey('direct_recovery_original')));
        await pump(t, 15);
        expect(requests.length, 1);
        await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
        await pump(t);
      });
    } finally {
      await close(t);
    }
  });
  for (final change in ['origin', 'token', 'none']) {
    testWidgets(
        'cold persisted single Agent without run rejects late $change confirmation',
        (t) async {
      try {
        await mocked(() async {
          await init(t);
          await t.runAsync(() async {
            conversation.id = null;
            conversation.cid = 98000 + serial;
            conversation.id =
                await conversationDao.saveConversation(conversation);
            final messages =
                await MessageDao.create(storage, cid: conversation.cid);
            await messages.saveMessageWithBlocks(MessageModel(
                ownerType: OwnerType.sender,
                content: 'COLD INPUT',
                createdAt: 100));
            final session = AgentTaskSession(
                cid: conversation.cid,
                store: await AgentTaskDao.create(storage));
            await session.setEnabled(true);
            await session.begin(userAt: 100, input: 'COLD INPUT');
            await session.pause('原请求状态未知');
            session.dispose();
          });
          expect(
              AgentTaskExecutor.instance
                  .lookup(AgentTaskKey('account-a', conversation.cid)),
              isNull);
          await conversationPage(t);
          await t.tap(find.text('继续任务').first);
          await until(
              t,
              () => find
                  .byKey(const ValueKey('direct_recovery_cancel'))
                  .evaluate()
                  .isNotEmpty);
          await t.tap(find.byKey(const ValueKey('direct_recovery_choice')));
          await pump(t, 8);
          await t.tap(find.text('Service B · plain').last);
          await pump(t, 8);
          if (change == 'origin') {
            BackendConfig.host = 'other.synthetic.invalid';
          }
          if (change == 'token') tokens.token = 'synthetic-new-token';
          await t.tap(find.byKey(const ValueKey('direct_recovery_confirm')));
          await pump(t, 20);
          expect(requests.length, change == 'none' ? 1 : 0);
          if (change == 'none') {
            expect(requests.single['fixturePath'], contains('/B/'));
          }
          expect(probes, 0);
          if (find
              .byKey(const ValueKey('direct_recovery_cancel'))
              .evaluate()
              .isNotEmpty) {
            await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
          }
        });
      } finally {
        await close(t);
      }
    });
  }
}
