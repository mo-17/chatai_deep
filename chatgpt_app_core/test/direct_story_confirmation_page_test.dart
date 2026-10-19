import 'support/story_p2_gate_database.dart';
import 'package:chatgpt_app_core/chat/application/direct_failure_recovery.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/story_room_tool_runner.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/pages/story_workbench_page.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, caseRoot;
  late _FailureSaveGate failureSaveGate;
  HttpServer? server;
  late DatabaseFactory? oldFactory;
  late String oldHost;
  late bool oldHttps;
  late HiDBManager storage;
  late StoryRoomDao dao;
  late StoryRoomModel room;
  late StoryParticipantModel actor;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late PairTokens tokens;
  WidgetTester? active;
  Completer<void>? probeGate, probeEntered, postGate, postEntered;
  final posts = <Map<String, dynamic>>[], cleanups = <Map<String, Object?>>[];
  int probes = 0, serial = 0;
  bool revoked = false, tools = false;
  bool partial = false, toolReply = false;
  List<int>? schedulerIds;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  BackendSelection pair(String code) => BackendSelection.pair(
      providerCode: code,
      modelId: 'plain',
      accountHash: 'account-a',
      origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
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
    caseRoot = Directory('${root.path}/case-${serial++}')..createSync();
    oldFactory = databaseFactoryOrNull;
    failureSaveGate = _FailureSaveGate();
    databaseFactory = _FailureSaveFactory(databaseFactoryFfi, failureSaveGate);
    await databaseFactory.setDatabasesPath('${caseRoot.path}/db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => caseRoot.path);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    AISettingsDao.resetSecureStateForTest();
    LoginDao.resetHooksForTest();
    tokens = PairTokens();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'story.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'story.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
    schedulerIds = null;
    posts.clear();
    partial = false;
    toolReply = false;
    probes = 0;
    revoked = false;
    tools = false;
    probeGate = probeEntered = postGate = postEntered = null;
  });
  Future<void> pump(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> until(WidgetTester t, bool Function() condition) async {
    for (var i = 0; i < 130 && !condition(); i++) {
      await pump(t, 1);
    }
    expect(condition(), isTrue,
        reason: 'bounded actual page/SQLite settlement');
  }

  Future<void> mocked(Future<void> Function() body) =>
      HttpOverrides.runWithHttpOverrides(
          () => http.runWithClient(() async {
                try {
                  await body();
                } finally {
                  if (!failureSaveGate.release.isCompleted) {
                    failureSaveGate.release.complete();
                  }
                  if (probeGate?.isCompleted == false) probeGate!.complete();
                  if (postGate?.isCompleted == false) postGate!.complete();
                  if (active != null) {
                    final t = active!;
                    await t.pumpWidget(const SizedBox.shrink());
                    await pump(t, 6);
                    await t.runAsync(() async {
                      await HiDBManager.closeAll();
                    });
                    expect(t.takeException(), isNull);
                    active = null;
                  }
                }
              },
                  () => MockClient((r) async {
                        expect(r.url.host, 'story.synthetic.invalid');
                        if (r.url.path == '/uapi/ai/model-selection') {
                          probes++;
                          if (probeEntered?.isCompleted == false) {
                            probeEntered!.complete();
                          }
                          if (probeGate != null) await probeGate!.future;
                          return http.Response(
                              jsonEncode({
                                'code': 0,
                                'data': {
                                  'providerCode': 'B',
                                  'modelId': r.url.queryParameters['modelId']
                                }
                              }),
                              200);
                        }
                        if (r.url.path == '/uapi/ai/catalog') {
                          return http.Response(
                              jsonEncode({
                                'code': 0,
                                'data': {
                                  'providers': [
                                    for (final code in [
                                      'G',
                                      'R',
                                      'P',
                                      'B',
                                      'Q'
                                    ])
                                      {
                                        'code': code,
                                        'displayName': 'Synthetic $code'
                                      }
                                  ],
                                  'models': revoked
                                      ? []
                                      : [
                                          for (final code in [
                                            'G',
                                            'R',
                                            'P',
                                            'B',
                                            'Q'
                                          ])
                                            {
                                              'providerCode': code,
                                              'modelId': 'plain',
                                              'displayName': 'plain',
                                              'supportsTool': true,
                                              'supportsVision': false,
                                              'supportsPdf': false,
                                              'supportsReasoning': false
                                            },
                                          {
                                            'providerCode': 'B',
                                            'modelId': ' local-original ',
                                            'displayName': 'raw',
                                            'supportsTool': false
                                          },
                                          {
                                            'providerCode': 'B',
                                            'modelId': ' role-original ',
                                            'displayName': 'raw',
                                            'supportsTool': false
                                          }
                                        ]
                                }
                              }),
                              200);
                        }
                        expect(r.method, 'POST');
                        expect(
                            r.url.path,
                            anyOf('/uapi/chat/completions',
                                '/uapi/chat/completions/stream'));
                        expect(
                            r.headers['Authorization'], 'Bearer synthetic-jwt');
                        final data = jsonDecode(r.body) as Map<String, dynamic>;
                        posts.add(data);
                        if (postEntered?.isCompleted == false) {
                          postEntered!.complete();
                        }
                        if (postGate != null) await postGate!.future;
                        if (!r.url.path.endsWith('/stream')) {
                          return http.Response(
                              jsonEncode({
                                'code': 0,
                                'data': {
                                  'content': schedulerIds == null
                                      ? 'SYNTHETIC'
                                      : jsonEncode(
                                          {'speakerIds': schedulerIds}),
                                  'usage': {
                                    'prompt_tokens': 2,
                                    'completion_tokens': 3
                                  }
                                }
                              }),
                              200);
                        }
                        final firstTool = tools &&
                            data['tools'] != null &&
                            !(data['messages'] as List)
                                .any((m) => m['role'] == 'tool');
                        final delta = firstTool
                            ? {
                                'tool_calls': [
                                  {
                                    'index': 0,
                                    'id': 'tool-1',
                                    'type': 'function',
                                    'function': {
                                      'name': 'calculator',
                                      'arguments': '{"expression":"2+2"}'
                                    }
                                  }
                                ]
                              }
                            : {'content': 'SYNTHETIC'};
                        return http.Response(
                            'data: ${jsonEncode({
                                  'choices': [
                                    {'delta': delta}
                                  ],
                                  'usage': {
                                    'prompt_tokens': 2,
                                    'completion_tokens': 3
                                  }
                                })}\n\ndata: [DONE]\n\n',
                            200,
                            headers: {'content-type': 'text/event-stream'});
                      })),
          _OwnedLoopbackHTTP());
  Future<void> init(WidgetTester t,
      {BackendSelection? r,
      BackendSelection? p,
      bool legacyR = false,
      bool legacyP = false,
      bool tool = false,
      bool workbench = false,
      bool automatic = false}) async {
    active = t;
    await t.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((r) async {
        expect(r.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, dynamic>;
        posts.add({...body, 'fixturePath': r.uri.path});
        if (postEntered?.isCompleted == false) postEntered!.complete();
        if (postGate != null) await postGate!.future;
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
        } else if (toolReply &&
            body['stream'] == true &&
            !(body['messages'] as List).any((m) => m['role'] == 'tool')) {
          r.response.headers.contentType = ContentType('text', 'event-stream');
          r.response.write('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_calc',
                          'type': 'function',
                          'function': {
                            'name': 'calculator',
                            'arguments': jsonEncode({'expression': '2+2'})
                          }
                        }
                      ]
                    },
                    'finish_reason': 'tool_calls'
                  }
                ]
              })}\n\ndata: [DONE]\n\n');
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
          for (final code in ['A', 'B'])
            AiProvider(
                id: code,
                name: 'Service $code',
                type: 'openai',
                enabled: true,
                apiHost: 'http://127.0.0.1:${server!.port}/$code/v1',
                apiKey: 'synthetic-$code',
                models: [AiModel(id: 'plain')],
                selectedModelId: 'plain')
        ];
      await HiCache.getInstance().setString(
          AISettingsDao.keyFor('account-a'), jsonEncode(global.toJson()));
      settings = AISettingsProvider();
      theme = ThemeProvider();
      storage = await HiDBManager.instance(dbName: 'account-a');
      dao = await StoryRoomDao.create(storage);
      room = StoryRoomModel(
          title: 'Story',
          backendSelection: null,
          modelId: 'plain',
          modelProviderId: 'A',
          topP: 0.6);
      if (automatic) {
        room
          ..mode = StoryRoomMode.tavern
          ..replyMode = StoryReplyMode.autoMulti
          ..maxAutoReplies = 2;
      }
      room.id = await dao.saveRoom(room);
      int? assistant;
      if (tool) {
        assistant = await (await AssistantDao.create(storage)).saveAssistant(
            AssistantModel(
                name: 'TOOLS',
                prompt: 'SYNTHETIC',
                useTools: true,
                toolIds: ['calculator']));
      }
      actor = StoryParticipantModel(
          roomId: room.id!,
          participantKey: 'actor',
          role: StoryParticipantRole.assistant,
          name: 'Actor',
          prompt: 'SYNTHETIC',
          assistantId: assistant,
          backendSelection: null,
          modelProviderId: 'A',
          modelId: 'plain',
          topP: 0.4);
      actor.id = await dao.saveParticipant(actor);
      if (automatic) {
        final other = StoryParticipantModel(
            roomId: room.id!,
            participantKey: 'actor2',
            role: StoryParticipantRole.assistant,
            name: 'Actor2',
            prompt: 'SYNTHETIC',
            backendSelection: pair('B'),
            sortOrder: 1);
        other.id = await dao.saveParticipant(other);
        schedulerIds = [actor.id!, other.id!];
      }

      tools = tool;
    });
    await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme)
        ],
        child: MaterialApp(
            home: workbench
                ? StoryWorkbenchPage(room: room)
                : StoryRoomPage(
                    room: room,
                    readAloudService: const NoopReadAloudService()))));
    await until(
        t, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await pump(t, 6);
  }

  Future<void> send(WidgetTester t) async {
    await t.enterText(
        find
            .descendant(
                of: find.byType(MessageInputWidget),
                matching: find.byType(TextField))
            .first,
        'SYNTHETIC INPUT');
    await t.pump();
    await t.tap(find.descendant(
        of: find.byType(MessageInputWidget),
        matching: find.byIcon(Icons.send)));
    await pump(t, 3);
  }

  Future<void> finish(WidgetTester t) => until(
      t,
      () =>
          find.byType(MessageInputWidget).evaluate().isNotEmpty &&
          t.widget<MessageInputWidget>(find.byType(MessageInputWidget)).enable);
  Future<Map<String, Object?>> roomRow(WidgetTester t) async =>
      (await t.runAsync(() => storage.db.query(StoryRoomDao.roomTable)))!
          .single;
  tearDown(() async {
    if (probeGate?.isCompleted == false) probeGate!.complete();
    if (postGate?.isCompleted == false) postGate!.complete();
    if (HiCache.getInstance().prefs != null) {
      await HiCache.getInstance().prefs!.clear();
    }
    await server?.close(force: true);
    server = null;
    settings.dispose();
    theme.dispose();
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    AISettingsDao.resetSecureStateForTest();
    ModelCatalog.resetExecutionForTest();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    databaseFactory = oldFactory;
    expect(storage.db.isOpen, isFalse);
    cleanups.add({
      'case': caseRoot.path,
      'sqliteClosed': !storage.db.isOpen,
      'modelPosts': posts.length,
      'probes': probes
    });
  });
  tearDownAll(
      () => File('${root.path}/cleanup.json').writeAsStringSync(jsonEncode({
            'cases': cleanups,
            'allClosed': cleanups.every((x) => x['sqliteClosed'] == true),
            'network':
                'Actual local DirectChatService to owned loopback HTTP; unrelated backend via MockClient; private SQLite/page'
          })));

  Future<void> selectB(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('direct_recovery_choice')));
    await pump(t, 12);
    await t.tap(find.text('Service B · plain').last);
    await pump(t, 12);
    expect(posts.where((p) => p['fixturePath'].toString().contains('/B/')),
        isEmpty);
    await t.tap(find.byKey(const ValueKey('direct_recovery_confirm')));
    await pump(t, 12);
  }

  testWidgets(
      'story direct failure cancel is one POST and preserves configured A',
      (t) async => mocked(() async {
            await init(t);
            final row = await roomRow(t);
            await send(t);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('direct_recovery_cancel'))
                    .evaluate()
                    .isNotEmpty);
            expect(posts.length, 1);
            expect(probes, 0);
            expect(find.textContaining('synthetic raw secret'), findsNothing);
            await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
            await pump(t, 20);
            expect(posts.length, 1);
            expect(
                (await roomRow(t))['modelProviderId'], row['modelProviderId']);
          }));
  testWidgets(
      'story partial stays in SQLite; explicit B emits one new request without global edit',
      (t) async => mocked(() async {
            await init(t);
            partial = true;
            await send(t);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('direct_recovery_cancel'))
                    .evaluate()
                    .isNotEmpty);
            final before = (await t.runAsync(() => dao.getMessages(room.id!)))!;
            expect(before.any((m) => m.content == 'OLD PARTIAL'), true);
            await selectB(t);
            await finish(t);
            await pump(t, 15);
            expect(posts.length, 2);
            expect(posts.last['fixturePath'], contains('/B/'));
            final after = (await t.runAsync(() => dao.getMessages(room.id!)))!;
            expect(after.any((m) => m.content == 'OLD PARTIAL'), true);
            expect(after.any((m) => m.content == 'NEW SUCCESS'), true);
            expect(settings.settings.activeProviderId, 'A');
            expect(probes, 0);
          }));
  for (final change in ['origin', 'configuration']) {
    testWidgets(
        'story late $change dialog cannot emit B',
        (t) async => mocked(() async {
              await init(t);
              await send(t);
              await until(
                  t,
                  () => find
                      .byKey(const ValueKey('direct_recovery_cancel'))
                      .evaluate()
                      .isNotEmpty);
              if (change == 'origin') {
                BackendConfig.host = 'other.synthetic.invalid';
              } else {
                settings.settings.providers.first.enabled = false;
              }
              await t
                  .tap(find.byKey(const ValueKey('direct_recovery_original')));
              await pump(t, 10);
              expect(posts.length, 1);
              await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
              await pump(t, 10);
            }));
  }
  testWidgets(
      'workbench local failure opens confirm without probe; cancel leaves one POST',
      (t) async => mocked(() async {
            await init(t, workbench: true);
            await t.tap(find.text('剧情导演审阅'));
            await pump(t, 12);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('direct_recovery_cancel'))
                    .evaluate()
                    .isNotEmpty);
            expect(posts.length, 1);
            expect(probes, 0);
            await t.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
            await pump(t, 15);
            expect(posts.length, 1);
            expect(settings.settings.activeProviderId, 'A');
          }));
  testWidgets(
      'workbench explicit B retries fixed prompt once; global remains A',
      (t) async => mocked(() async {
            await init(t, workbench: true);
            await t.tap(find.text('剧情导演审阅'));
            await pump(t, 12);
            await until(
                t,
                () => find
                    .byKey(const ValueKey('direct_recovery_cancel'))
                    .evaluate()
                    .isNotEmpty);
            await selectB(t);
            await until(t, () => posts.length == 2);
            await pump(t, 20);
            expect(posts.last['fixturePath'], contains('/B/'));
            expect(posts.first['messages'], posts.last['messages']);
            expect(settings.settings.activeProviderId, 'A');
            expect(probes, 0);
          }));
  for (final workbench in [false, true]) {
    for (final change in ['origin', 'configuration', 'token', 'account']) {
      testWidgets(
          '${workbench ? "workbench" : "room"} confirmed B POST then $change cannot publish successful result',
          (t) async => mocked(() async {
                await init(t, workbench: workbench);
                if (workbench) {
                  await t.tap(find.text('剧情导演审阅'));
                } else {
                  await send(t);
                }
                await until(
                    t,
                    () => find
                        .byKey(const ValueKey('direct_recovery_cancel'))
                        .evaluate()
                        .isNotEmpty);
                postGate = Completer<void>();
                postEntered = Completer<void>();
                await selectB(t);
                await until(t, () => posts.length == 2);
                expect(postEntered!.isCompleted, true);
                final before = await roomRow(t);
                if (change == 'origin') {
                  BackendConfig.host = 'other.synthetic.invalid';
                } else if (change == 'token') {
                  tokens.token = 'synthetic-new-token';
                } else if (change == 'account') {
                  tokens.account = 'account-b';
                } else {
                  settings.settings.providers.first.enabled = false;
                }
                postGate!.complete();
                await pump(t, 28);
                final after = await roomRow(t);
                expect(after['worldBookState'], before['worldBookState']);
                expect(after['activeMessageKey'], before['activeMessageKey']);
                final messages =
                    (await t.runAsync(() => dao.getMessages(room.id!)))!;
                expect(
                    messages.where((m) =>
                        m.content == 'NEW SUCCESS' &&
                        !m.speakerName.contains('请求未完成')),
                    isEmpty);
                expect(find.text('保存为资料'), findsNothing);
                if (workbench && change == 'configuration') {
                  expect(find.text('预览已生成内容'), findsOneWidget);
                  expect(find.widgetWithText(TextField, 'NEW SUCCESS'),
                      findsOneWidget);
                  await t.tap(find.text('关闭'));
                  await pump(t, 8);
                }
                if (!workbench && change == 'configuration') {
                  expect(
                      messages.any((m) =>
                          m.content == 'NEW SUCCESS' &&
                          m.speakerName.contains('请求未完成')),
                      true);
                }
                expect(posts.length, 2);
                expect(probes, 0);
              }));
    }
  }
  testWidgets(
      'workbench confirmed B preview loses original permit before save and writes no artifact',
      (t) async => mocked(() async {
            await init(t, workbench: true);
            await t.tap(find.text('剧情导演审阅'));
            await until(
                t,
                () => find
                    .byKey(const ValueKey('direct_recovery_cancel'))
                    .evaluate()
                    .isNotEmpty);
            await selectB(t);
            await until(t, () => find.text('保存为资料').evaluate().isNotEmpty);
            settings.settings.providers.first.enabled = false;
            await t.tap(find.text('保存为资料'));
            await pump(t, 20);
            final rows = (await t
                .runAsync(() => storage.db.query('tb_story_artifact')))!;
            expect(rows, isEmpty);
            expect(posts.length, 2);
            expect(probes, 0);
          }));
  for (final revoke in [true, false]) {
    testWidgets(
        'actual direct story tool result after confirmed POST ${revoke ? 'revoked' : 'unchanged'} permit',
        (t) async => mocked(() async {
              await init(t, tool: true);
              final local = settings.settings.clone()..activeProviderId = 'B';
              for (final p in local.providers) {
                p.models = [AiModel(id: 'gpt-4o')];
                p.selectedModelId = 'gpt-4o';
              }
              final recovery = DirectFailureRecovery(
                  original: local,
                  scope: ConversationGenerationScope(account: 'account-a'),
                  currentSettings: () => local,
                  sourceCurrent: () => true,
                  requiredInput: const ModelCapabilities.none(),
                  mayHaveBeenProcessed: true,
                  failureCode: 'timeout');
              final permit =
                  recovery.confirm(DirectFailureRecovery.key('B', 'gpt-4o'))!;
              final selected = permit.claim()!;
              final events = <StreamEvent>[];
              toolReply = true;
              final runner =
                  StoryRoomToolRunner(openStorage: () async => storage);
              Object? error;
              await t.runAsync(() async {
                postGate = Completer<void>();
                postEntered = Completer<void>();
                final completed = () async {
                  try {
                    await for (final e in runner.run(
                        speakerAssistantId: actor.assistantId,
                        settings: selected,
                        prompt: 'SYNTHETIC',
                        history: const [],
                        requestOptions: ChatRequestOptions(
                            dispatchIsCurrent: () => permit.current,
                            beforeDispatch: (_) async => permit.verify()))) {
                      events.add(e);
                    }
                  } catch (e) {
                    error = e;
                  }
                }();
                await postEntered!.future.timeout(const Duration(seconds: 3));
                if (revoke) local.providers.first.enabled = false;
                postGate!.complete();
                await completed.timeout(const Duration(seconds: 3));
              });
              expect(error, revoke ? isNotNull : isNull);
              expect(
                  events
                      .where((e) => e.type == StreamEventType.toolResult)
                      .length,
                  revoke ? 0 : 1);
              expect(posts.length, revoke ? 1 : 2);
              expect(probes, 0);
            }));
  }

  testWidgets(
      'workbench unchanged confirmed B saves received result once in original account',
      (t) async => mocked(() async {
            await init(t, workbench: true);
            await t.tap(find.text('剧情导演审阅'));
            await until(
                t,
                () => find
                    .byKey(const ValueKey('direct_recovery_cancel'))
                    .evaluate()
                    .isNotEmpty);
            await selectB(t);
            await until(t, () => find.text('保存为资料').evaluate().isNotEmpty);
            await t.tap(find.text('保存为资料'));
            await pump(t, 20);
            final rows = (await t
                .runAsync(() => storage.db.query('tb_story_artifact')))!;
            expect(rows.length, 1);
            expect(rows.single['content'], 'NEW SUCCESS');
            expect(posts.length, 2);
            expect(probes, 0);
          }));
  for (final change in ['configuration', 'stop', 'none']) {
    testWidgets(
        'first local failure save transaction barrier $change without retry permit',
        (t) async => mocked(() async {
              await init(t);
              partial = true;
              failureSaveGate.armed = true;
              await send(t);
              await until(t, () => failureSaveGate.entered.isCompleted);
              expect(posts.length, 1);
              expect(find.byKey(const ValueKey('direct_recovery_cancel')),
                  findsNothing);
              expect(failureSaveGate.beforeActive, isNotNull);
              if (change == 'configuration') {
                settings.settings.providers.first.enabled = false;
              }
              if (change == 'stop') {
                final widget = t.widget<MessageInputWidget>(
                    find.byType(MessageInputWidget));
                expect(widget.onStop, isNotNull);
                widget.onStop!();
              }
              failureSaveGate.release.complete();
              await finish(t);
              await pump(t, 10);
              final row = await roomRow(t);
              final messages =
                  (await t.runAsync(() => dao.getMessages(room.id!)))!;
              final partials =
                  messages.where((m) => m.content == 'OLD PARTIAL').toList();
              expect(partials.length, 1);
              expect(partials.single.speakerName, contains('请求未完成'));
              if (change == 'none') {
                expect(failureSaveGate.failedAttemptCommitted, true);
                expect(failureSaveGate.failedAttemptRolledBack, false);
                expect(row['activeMessageKey'], partials.single.nodeKey);
                expect(find.byKey(const ValueKey('direct_recovery_cancel')),
                    findsOneWidget);
              } else {
                expect(failureSaveGate.failedAttemptRolledBack, true);
                expect(failureSaveGate.failedAttemptCommitted, false);
                expect(row['activeMessageKey'], failureSaveGate.beforeActive);
                expect(row['activeMessageKey'], isNot(partials.single.nodeKey));
              }
              expect(posts.length, 1);
              expect(probes, 0);
              expect(tokens.clears, 0);
              if (find
                  .byKey(const ValueKey('direct_recovery_cancel'))
                  .evaluate()
                  .isNotEmpty) {
                await t
                    .tap(find.byKey(const ValueKey('direct_recovery_cancel')));
                await pump(t, 5);
              }
            }));
  }
}

// 只在真实私有 SQLite 的未完成助手插入后、活动节点 UPDATE 前挂起一次。
// 持锁屏障仅为 fixture，production 不等待 UI；finally 始终释放。
class _FailureSaveGate {
  bool armed = false,
      failedAttemptCommitted = false,
      failedAttemptRolledBack = false;
  String? beforeActive;
  final entered = Completer<void>(), release = Completer<void>();
}

class _FailureSaveFactory extends StoryP2Factory {
  final _FailureSaveGate failure;
  _FailureSaveFactory(DatabaseFactory native, this.failure)
      : super(native, StoryP2Gate());
  @override
  Future<Database> openDatabase(String path,
          {OpenDatabaseOptions? options}) async =>
      _FailureSaveDatabase(
          await native.openDatabase(path, options: options), failure);
}

class _FailureSaveDatabase extends StoryP2Database {
  final _FailureSaveGate failure;
  _FailureSaveDatabase(Database native, this.failure)
      : super(native, StoryP2Gate());
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    if (!failure.armed) return native.transaction(action, exclusive: exclusive);
    bool matched = false;
    try {
      final value = await native.transaction(
          (tx) => action(
              _FailureSaveTransaction(tx, failure, () => matched = true)),
          exclusive: exclusive);
      if (matched) failure.failedAttemptCommitted = true;
      return value;
    } catch (_) {
      if (matched) failure.failedAttemptRolledBack = true;
      rethrow;
    }
  }
}

class _FailureSaveTransaction implements Transaction {
  final Transaction native;
  final _FailureSaveGate failure;
  final void Function() matched;
  _FailureSaveTransaction(this.native, this.failure, this.matched);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    final id = await native.insert(table, values,
        nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
    if (failure.armed &&
        table == StoryRoomDao.messageTable &&
        (values['speakerName'] as String? ?? '').contains('请求未完成')) {
      failure.armed = false;
      matched();
      final room = await native.query(StoryRoomDao.roomTable,
          columns: ['activeMessageKey'],
          where: 'id=?',
          whereArgs: [values['roomId']]);
      failure.beforeActive = room.single['activeMessageKey'] as String?;
      failure.entered.complete();
      await failure.release.future;
    }
    return id;
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      native.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);
  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      native.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused failure-save fixture transaction');
}
