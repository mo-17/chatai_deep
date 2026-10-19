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
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
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
  Completer<void>? responseGate, postEntered;
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

  Future<void> editor(WidgetTester t) async {
    await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme)
        ],
        child: MaterialApp(initialRoute: '/edit', routes: {
          '/': (_) => const Scaffold(body: Text('LIST')),
          '/edit': (_) => AssistantEditPage(assistant: assistant)
        })));
    await pump(t, 20);
  }

  Future<void> mocked(Future<void> Function() action) => http.runWithClient(
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
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              requests.add(body);
              if (postEntered?.isCompleted == false) postEntered!.complete();
              if (responseGate != null) await responseGate!.future;
              expect(request.headers['Authorization'], 'Bearer synthetic-jwt');
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
  final cases = [
    (
      name: 'conversation pair',
      c: 'pair',
      a: 'pair',
      legacyC: null,
      legacyA: 'old assistant',
      code: 'C',
      model: 'plain'
    ),
    (
      name: 'conversation follow skips old model',
      c: 'follow',
      a: 'pair',
      legacyC: 'ignored-old',
      legacyA: 'old assistant',
      code: 'A',
      model: 'plain'
    ),
    (
      name: 'both follow skip old models',
      c: 'follow',
      a: 'follow',
      legacyC: 'ignored-old',
      legacyA: 'ignored-assistant',
      code: 'G',
      model: 'plain'
    ),
    (
      name: 'NULL conversation keeps raw legacy',
      c: 'none',
      a: 'pair',
      legacyC: ' raw conversation / ',
      legacyA: 'old assistant',
      code: 'B',
      model: ' raw conversation / '
    ),
    (
      name: 'NULL assistant keeps raw legacy',
      c: 'follow',
      a: 'none',
      legacyC: 'ignored-old',
      legacyA: ' raw assistant / ',
      code: 'B',
      model: ' raw assistant / '
    ),
  ];
  for (final item in cases) {
    testWidgets(
        'actual send inheritance ${item.name} exact pair and namespace usage',
        (t) async {
      try {
        await mocked(() async {
          await init(t,
              c: item.c == 'pair'
                  ? pair('C')
                  : item.c == 'follow'
                      ? BackendSelection.follow()
                      : null,
              a: item.a == 'pair'
                  ? pair('A')
                  : item.a == 'follow'
                      ? BackendSelection.follow()
                      : null,
              legacyC: item.legacyC,
              legacyA: item.legacyA,
              hasAssistant: true);
          await conversationPage(t);
          await send(t);
          await until(
              t, () => service.runs.isNotEmpty && !service.runs.last.busy);
          expect(requests, hasLength(1));
          expect(requests.single['providerCode'], item.code);
          expect(requests.single['model'], item.model);
          expect(probes, item.code == 'B' ? 1 : 0);
          final rows = (await t.runAsync(() => storage.db.query('tb_usage')))!;
          expect(rows, hasLength(1));
          expect(
              rows.single['providerId'],
              'backend:${jsonEncode([
                    'https://backend.synthetic.invalid',
                    item.code
                  ])}');
          expect(rows.single['modelId'], item.model);
          observations.add({
            'case': item.name,
            'requests': requests.toList(),
            'usage': rows,
            'probes': probes
          });
        });
      } finally {
        await close(t);
      }
    });
  }
  for (final layer in ['conversation', 'assistant']) {
    for (final kind in ['invalid', 'foreign']) {
      testWidgets(
          'modern $kind $layer blocks instead of valid ancestor fallback',
          (t) async {
        try {
          await mocked(() async {
            final blocked = kind == 'invalid'
                ? BackendSelection.fromStorage({'version': 99})
                : pair('C', account: 'other');
            await init(t,
                c: layer == 'conversation'
                    ? blocked
                    : BackendSelection.follow(),
                a: layer == 'assistant' ? blocked : pair('A'),
                hasAssistant: true);
            await conversationPage(t);
            await send(t);
            expect(find.byKey(const ValueKey('ai_send_guard_primary')),
                findsOneWidget);
            expect(requests, isEmpty);
            expect(service.runs, isEmpty);
          });
        } finally {
          await close(t);
        }
      });
    }
  }
  testWidgets(
      'conversation pair picker explicit save leaves local columns/global pair untouched and follow persists',
      (t) async {
    try {
      await mocked(() async {
        await init(t,
            c: pair('A'),
            a: pair('B'),
            legacyC: ' local model ',
            hasAssistant: true);
        await conversationPage(t);
        final global = jsonEncode(settings.settings.toJson());
        final label = t
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .modelLabel!;
        await t.tap(find.text(label));
        await pump(t, 15);
        expect(
            find.byKey(ValueKey(jsonEncode(['B', 'plain']))), findsOneWidget);
        await t.tap(find.byKey(ValueKey(jsonEncode(['B', 'plain']))));
        await pump(t, 20);
        final row = (await t.runAsync(() => storage.db.query(
                conversationDao.tableName,
                where: 'id=?',
                whereArgs: [conversation.id])))!
            .single;
        expect(
            BackendSelection.fromStorage(row['backendSelection'])!.providerCode,
            'B');
        expect(row['modelProviderId'], 'other-local');
        expect(row['modelId'], ' local model ');
        expect(jsonEncode(settings.settings.toJson()), global);
        expect(requests, isEmpty);
        final nextLabel = t
            .widget<MessageInputWidget>(find.byType(MessageInputWidget))
            .modelLabel!;
        await t.tap(find.text(nextLabel));
        await pump(t, 15);
        await t.tap(find.byKey(const ValueKey('backend_follow')));
        await pump(t, 20);
        final fresh = (await t.runAsync(() => storage.db.query(
                conversationDao.tableName,
                where: 'id=?',
                whereArgs: [conversation.id])))!
            .single;
        expect(
            BackendSelection.fromStorage(fresh['backendSelection'])!.isFollow,
            isTrue);
        expect(fresh['modelId'], ' local model ');
      });
    } finally {
      await close(t);
    }
  });
  for (final change in ['origin', 'epoch', 'CAS']) {
    testWidgets(
        'conversation picker late $change cannot overwrite original/newer selection',
        (t) async {
      try {
        await mocked(() async {
          await init(t, c: pair('A'), legacyC: ' local model ');
          await conversationPage(t);
          await t.tap(find.text(t
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .modelLabel!));
          await pump(t, 15);
          final tile = find.byKey(ValueKey(jsonEncode(['B', 'plain'])));
          expect(tile, findsOneWidget);
          final lateTap = t.widget<ListTile>(tile).onTap!;
          if (change == 'origin') {
            BackendConfig.host = 'other.synthetic.invalid';
          }
          if (change == 'epoch') {
            await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
                userName: 'Synthetic', extras: {'accountHash': 'account-a'}));
          }
          if (change == 'CAS') {
            await t.runAsync(() => storage.db.update(conversationDao.tableName,
                {'backendSelection': pair('C').toSqlValue()},
                where: 'id=?', whereArgs: [conversation.id]));
          }
          lateTap();
          await pump(t, 20);
          final row = (await t.runAsync(() => storage.db.query(
                  conversationDao.tableName,
                  where: 'id=?',
                  whereArgs: [conversation.id])))!
              .single;
          expect(
              BackendSelection.fromStorage(row['backendSelection'])!
                  .providerCode,
              change == 'CAS' ? 'C' : 'A');
          expect(row['modelId'], ' local model ');
          expect(requests, isEmpty);
        });
      } finally {
        await close(t);
      }
    });
  }
  for (final revoke in [false, true]) {
    testWidgets(
        'held ordinary pair stays bound after parent change; revoke=$revoke never replaces it',
        (t) async {
      try {
        await mocked(() async {
          await init(t,
              c: BackendSelection.follow(), a: pair('B'), hasAssistant: true);
          await conversationPage(t);
          responseGate = Completer<void>();
          postEntered = Completer<void>();
          await send(t);
          await until(t, () => postEntered!.isCompleted);
          final run = service.runs.single;
          expect(run.profile.settings.backendSelection!.providerCode, 'B');
          await t.runAsync(() => settings
              .update(settings.settings.clone()..backendSelection = pair('C')));
          await t.runAsync(() => storage.db.update(assistantDao.tableName,
              {'backendSelection': pair('A').toSqlValue()},
              where: 'id=?', whereArgs: [assistant!.id]));
          if (revoke) {
            revoked = true;
            await t.runAsync(() => ModelCatalog.refreshFromBackend());
          }
          responseGate!.complete();
          await until(t, () => !run.busy);
          expect(requests, hasLength(1));
          expect(requests.single['providerCode'], 'B');
          expect(run.profile.settings.backendSelection!.providerCode, 'B');
          if (revoke) expect(run.profile.visiblyCurrent, isFalse);
          final rows = (await t.runAsync(() => storage.db.query('tb_usage')))!;
          if (rows.isNotEmpty) {
            expect(
                rows.single['providerId'],
                'backend:${jsonEncode([
                      'https://backend.synthetic.invalid',
                      'B'
                    ])}');
          }
        });
      } finally {
        if (responseGate?.isCompleted == false) responseGate!.complete();
        await close(t);
      }
    });
  }
  for (final change in ['origin', 'epoch', 'CAS']) {
    testWidgets(
        'assistant explicit backend edit saves only on original scope and original row $change',
        (t) async {
      try {
        await mocked(() async {
          await init(t,
              a: pair('A'), legacyA: ' local model ', hasAssistant: true);
          await editor(t);
          final tile =
              find.byKey(const ValueKey('assistant_backend_selection'));
          await t.scrollUntilVisible(find.text('模型与语音'), 300,
              scrollable: find
                  .descendant(
                      of: find.byType(AssistantEditPage),
                      matching: find.byType(Scrollable))
                  .first);
          await t.tap(find.text('模型与语音'));
          await pump(t, 15);
          expect(tile, findsOneWidget);
          await t.ensureVisible(tile);
          await t.tap(tile);
          await pump(t, 15);
          await t.tap(find.byKey(ValueKey(jsonEncode(['B', 'plain']))));
          await pump(t, 15);
          if (change == 'origin') {
            BackendConfig.host = 'other.synthetic.invalid';
          }
          if (change == 'epoch') {
            await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
                userName: 'Synthetic', extras: {'accountHash': 'account-a'}));
          }
          if (change == 'CAS') {
            await t.runAsync(() => storage.db.update(
                assistantDao.tableName, {'updatedAt': assistant!.updatedAt + 1},
                where: 'id=?', whereArgs: [assistant!.id]));
          }
          final save = find.ancestor(
              of: find.text('保存修改'),
              matching: find.byWidgetPredicate((w) => w is FilledButton));
          await t.ensureVisible(save);
          await t.tap(save);
          await pump(t, 30);
          final row = (await t
              .runAsync(() => assistantDao.getAssistant(assistant!.id!)))!;
          expect(row.backendSelection!.providerCode, 'A');
          expect(row.providerId, ' local-id ');
          expect(row.model, ' local model ');
          expect(requests, isEmpty);
        });
      } finally {
        await close(t);
      }
    });
  }
  testWidgets(
      'assistant explicit pair and follow save require final page save; committed object and row agree',
      (t) async {
    try {
      await mocked(() async {
        await init(t,
            a: pair('A'), legacyA: ' local model ', hasAssistant: true);
        await editor(t);
        final tile = find.byKey(const ValueKey('assistant_backend_selection'));
        await t.scrollUntilVisible(find.text('模型与语音'), 300,
            scrollable: find
                .descendant(
                    of: find.byType(AssistantEditPage),
                    matching: find.byType(Scrollable))
                .first);
        await t.tap(find.text('模型与语音'));
        await pump(t, 15);
        expect(tile, findsOneWidget);
        await t.ensureVisible(tile);
        await t.tap(tile);
        await pump(t, 15);
        await t.tap(find.byKey(ValueKey(jsonEncode(['B', 'plain']))));
        await pump(t, 15);
        expect(
            (await t.runAsync(() => assistantDao.getAssistant(assistant!.id!)))!
                .backendSelection!
                .providerCode,
            'A');
        final save = find.ancestor(
            of: find.text('保存修改'),
            matching: find.byWidgetPredicate((w) => w is FilledButton));
        await t.ensureVisible(save);
        await t.ensureVisible(save);
        await t.tap(save);
        await pump(t, 40);
        final row = (await t
            .runAsync(() => assistantDao.getAssistant(assistant!.id!)))!;
        expect(row.backendSelection!.providerCode, 'B');
        expect(assistant!.backendSelection!.providerCode, 'B');
        expect(row.providerId, ' local-id ');
        expect(row.model, ' local model ');
        expect(settings.settings.backendSelection!.providerCode, 'G');
        expect(requests, isEmpty);
      });
    } finally {
      await close(t);
    }
  });
  testWidgets(
      'assistant explicit follow preserves local fields and next ordinary request follows global pair',
      (t) async {
    try {
      await mocked(() async {
        await init(t,
            a: pair('A'), legacyA: ' local model ', hasAssistant: true);
        await editor(t);
        await t.scrollUntilVisible(find.text('模型与语音'), 300,
            scrollable: find
                .descendant(
                    of: find.byType(AssistantEditPage),
                    matching: find.byType(Scrollable))
                .first);
        await t.tap(find.text('模型与语音'));
        await pump(t, 15);
        final tile = find.byKey(const ValueKey('assistant_backend_selection'));
        expect(tile, findsOneWidget);
        await t.ensureVisible(tile);
        await t.tap(tile);
        await pump(t, 15);
        await t.tap(find.byKey(const ValueKey('backend_follow')));
        await pump(t, 15);
        final save = find.ancestor(
            of: find.text('保存修改'),
            matching: find.byWidgetPredicate((w) => w is FilledButton));
        await t.ensureVisible(save);
        await t.tap(save);
        await pump(t, 40);
        final row = (await t
            .runAsync(() => assistantDao.getAssistant(assistant!.id!)))!;
        expect(row.backendSelection!.isFollow, isTrue);
        expect(row.providerId, ' local-id ');
        expect(row.model, ' local model ');
        await conversationPage(t);
        await send(t);
        await until(
            t, () => service.runs.isNotEmpty && !service.runs.last.busy);
        expect(requests, hasLength(1));
        expect(requests.single['providerCode'], 'G');
        expect(requests.single['model'], 'plain');
      });
    } finally {
      await close(t);
    }
  });

  for (final change in ['none', 'origin', 'epoch']) {
    testWidgets('conversation custom pair dialog original identity $change',
        (t) async {
      try {
        await mocked(() async {
          await init(t, c: pair('A'), legacyC: ' local model ');
          await conversationPage(t);
          await t.tap(find.text(t
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .modelLabel!));
          await pump(t, 15);
          await t.tap(find.byKey(const ValueKey('backend_custom')));
          await pump(t, 15);
          await t.enterText(find.byKey(const ValueKey('backend_provider_code')),
              ' raw/provider ');
          await t.enterText(
              find.byKey(const ValueKey('backend_model_id')), ' raw/model ');
          if (change == 'origin') {
            BackendConfig.host = 'other.synthetic.invalid';
          }
          if (change == 'epoch') {
            await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
                userName: 'Synthetic', extras: {'accountHash': 'account-a'}));
          }
          await t.tap(find.descendant(
              of: find.byType(AlertDialog), matching: find.text('保存')));
          await pump(t, 20);
          final row = (await t.runAsync(() => storage.db.query(
                  conversationDao.tableName,
                  where: 'id=?',
                  whereArgs: [conversation.id])))!
              .single;
          final actual = BackendSelection.fromStorage(row['backendSelection'])!;
          expect(
              actual.providerCode, change == 'none' ? ' raw/provider ' : 'A');
          expect(actual.modelId, change == 'none' ? ' raw/model ' : 'plain');
          expect(row['modelProviderId'], 'other-local');
          expect(row['modelId'], ' local model ');
          expect(settings.settings.backendSelection!.providerCode, 'G');
          expect(requests, isEmpty);
          expect(probes, 0);
        });
      } finally {
        await close(t);
      }
    });
  }
}
