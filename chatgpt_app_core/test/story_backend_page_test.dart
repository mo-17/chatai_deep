import 'support/owned_test_directory.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/chat/domain/backend_usage_identity.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
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

void main() {
  final ownedFixture = OwnedTestDirectory(
    rootKey: 'R3B3B_ROOT',
    nonceKey: 'R3B3B_NONCE',
    legacyPrefix: '/tmp/chatai-r3b3b-owned-',
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, caseRoot;
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
  List<int>? schedulerIds;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  BackendSelection pair(String code) => BackendSelection.pair(
      providerCode: code,
      modelId: 'plain',
      accountHash: 'account-a',
      origin: BackendConfig.buildUri('/uapi/ai/catalog').origin);
  setUpAll(() {
    root = ownedFixture.directory;
    sqfliteFfiInit();
  });
  setUp(() async {
    caseRoot = Directory('${root.path}/case-${serial++}')..createSync();
    oldFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
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
      http.runWithClient(() async {
        try {
          await body();
        } finally {
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
                            for (final code in ['G', 'R', 'P', 'B', 'Q'])
                              {'code': code, 'displayName': 'Synthetic $code'}
                          ],
                          'models': revoked
                              ? []
                              : [
                                  for (final code in ['G', 'R', 'P', 'B', 'Q'])
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
                expect(r.headers['Authorization'], 'Bearer synthetic-jwt');
                final data = jsonDecode(r.body) as Map<String, dynamic>;
                posts.add(data);
                if (postEntered?.isCompleted == false) postEntered!.complete();
                if (postGate != null) await postGate!.future;
                if (!r.url.path.endsWith('/stream')) {
                  return http.Response(
                      jsonEncode({
                        'code': 0,
                        'data': {
                          'content': schedulerIds == null
                              ? 'SYNTHETIC'
                              : jsonEncode({'speakerIds': schedulerIds}),
                          'usage': {'prompt_tokens': 2, 'completion_tokens': 3}
                        }
                      }),
                      200);
                }
                final firstTool = tools &&
                    data['tools'] != null &&
                    !(data['messages'] as List).any((m) => m['role'] == 'tool');
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
                          'usage': {'prompt_tokens': 2, 'completion_tokens': 3}
                        })}\n\ndata: [DONE]\n\n',
                    200,
                    headers: {'content-type': 'text/event-stream'});
              }));
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
      final global = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendSelection = pair('G')
        ..backendModel = 'plain';
      await HiCache.getInstance().setString(
          AISettingsDao.keyFor('account-a'), jsonEncode(global.toJson()));
      settings = AISettingsProvider();
      theme = ThemeProvider();
      storage = await HiDBManager.instance(dbName: 'account-a');
      dao = await StoryRoomDao.create(storage);
      room = StoryRoomModel(
          title: 'Story',
          backendSelection: legacyR ? null : r ?? pair('R'),
          modelId: ' local-original ',
          modelProviderId: 'local-id',
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
          backendSelection: legacyP ? null : p ?? pair('P'),
          modelProviderId: 'role-local',
          modelId: ' role-original ',
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
      await ModelCatalog.refreshFromBackend();
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
  Future<void> roomEditor(WidgetTester t) async {
    await t.tap(find.byTooltip('房间设置'));
    await pump(t, 12);
    await t.tap(find.text('模型与生成参数'));
    await pump(t, 12);
  }

  Future<void> choose(WidgetTester t, String code,
      {bool participant = false}) async {
    await t.ensureVisible(find.byKey(ValueKey(participant
        ? 'story_participant_backend_selection'
        : 'story_room_backend_selection')));
    await t.tap(find.byKey(ValueKey(participant
        ? 'story_participant_backend_selection'
        : 'story_room_backend_selection')));
    await pump(t, 12);
    await t.tap(find.byKey(code == 'FOLLOW'
        ? const ValueKey('backend_follow')
        : ValueKey(jsonEncode([code, 'plain']))));
    await pump(t, 12);
  }

  Future<void> save(WidgetTester t) async {
    await t.tap(find.widgetWithText(FilledButton, '保存').last);
    await pump(t, 16);
  }

  Future<Map<String, Object?>> roomRow(WidgetTester t) async =>
      (await t.runAsync(() => storage.db.query(StoryRoomDao.roomTable)))!
          .single;
  tearDown(() async {
    if (probeGate?.isCompleted == false) probeGate!.complete();
    if (postGate?.isCompleted == false) postGate!.complete();
    if (HiCache.getInstance().prefs != null) {
      await HiCache.getInstance().prefs!.clear();
    }
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
            'network': 'MockClient synthetic only; actual private SQLite/page'
          })));

  testWidgets(
      'page automatic scheduler and both speakers reuse original prepared choices across global and row changes',
      (t) async => mocked(() async {
            await init(t, automatic: true);
            postGate = Completer();
            postEntered = Completer();
            await send(t);
            await until(t, () => postEntered!.isCompleted);
            await t.runAsync(() => settings.update(
                settings.settings.clone()..backendSelection = pair('Q')));
            await t.runAsync(() => storage.db.update(
                StoryRoomDao.participantTable,
                {'backendSelection': pair('Q').toSqlValue()},
                where: 'participantKey=?',
                whereArgs: ['actor2']));
            postGate!.complete();
            await finish(t);
            expect(posts.map((p) => p['providerCode']), ['R', 'P', 'B']);
            expect(posts.every((p) => p['model'] == 'plain'), isTrue);
            expect(probes, 0);
            final rows = await t.runAsync(() => storage.db.query(
                StoryRoomDao.participantTable,
                where: 'participantKey=?',
                whereArgs: ['actor2']));
            expect(
                BackendSelection.fromStorage(rows!.single['backendSelection'])!
                    .providerCode,
                'Q');
          }));
  testWidgets(
      'page explicit stop prevents late completion and further dispatch without replacing selection',
      (t) async => mocked(() async {
            await init(t, tool: true);
            postGate = Completer();
            postEntered = Completer();
            await send(t);
            await until(t, () => postEntered!.isCompleted);
            t
                .widget<MessageInputWidget>(find.byType(MessageInputWidget))
                .onStop!();
            postGate!.complete();
            await finish(t);
            expect(posts.length, 1);
            final messages = await t.runAsync(() => dao.getMessages(room.id!));
            expect(messages!.where((m) => !m.isUser), isEmpty);
            final row = await roomRow(t);
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!
                    .providerCode,
                'R');
          }));
  testWidgets(
      'page participant pair, tool rounds and usage retain one prepared pair during global change',
      (t) async => mocked(() async {
            await init(t, tool: true);
            postGate = Completer();
            postEntered = Completer();
            await send(t);
            await until(t, () => postEntered!.isCompleted);
            await t.runAsync(() => settings.update(
                settings.settings.clone()..backendSelection = pair('Q')));
            postGate!.complete();
            await finish(t);
            expect(posts.length, 2);
            expect(
                posts.every(
                    (p) => p['providerCode'] == 'P' && p['model'] == 'plain'),
                isTrue);
            final usage = await t.runAsync(() => storage.db.query('tb_usage'));
            expect(
                usage!.single['providerId'], backendUsageProviderId(pair('P')));
          }));
  for (final globalFollow in [false, true]) {
    testWidgets(
        'page explicit follow participant -> ${globalFollow ? 'room follow -> global' : 'room pair'} ignores legacy local fields',
        (t) async => mocked(() async {
              await init(t,
                  r: globalFollow ? BackendSelection.follow() : pair('R'),
                  p: BackendSelection.follow());
              await send(t);
              await finish(t);
              expect(posts.single['providerCode'], globalFollow ? 'G' : 'R');
              expect(posts.single['model'], 'plain');
              expect(probes, 0);
            }));
  }
  testWidgets(
      'page NULL legacy participant resolves raw ID exactly once, does not borrow modern global',
      (t) async => mocked(() async {
            await init(t, legacyP: true);
            await send(t);
            await finish(t);
            expect(probes, 1);
            expect(posts.single['providerCode'], 'B');
            expect(posts.single['model'], ' role-original ');
          }));
  testWidgets(
      'page room pair save preserves local fields, numeric settings and authoritative reopened choice',
      (t) async => mocked(() async {
            await init(t);
            await roomEditor(t);
            await choose(t, 'B');
            await save(t);
            final row = await roomRow(t);
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!
                    .providerCode,
                'B');
            expect(row['modelProviderId'], 'local-id');
            expect(row['modelId'], ' local-original ');
            expect(row['topP'], 0.6);
            await roomEditor(t);
            expect(find.textContaining('B'), findsWidgets);
          }));
  testWidgets(
      'page room explicit follow is stored without clearing local legacy fields',
      (t) async => mocked(() async {
            await init(t);
            await roomEditor(t);
            await choose(t, 'FOLLOW');
            await save(t);
            final row = await roomRow(t);
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!.isFollow,
                isTrue);
            expect(row['modelId'], ' local-original ');
            expect(posts, isEmpty);
          }));
  testWidgets(
      'page save conflict reports failure and does not overwrite changed row',
      (t) async => mocked(() async {
            await init(t);
            await roomEditor(t);
            await choose(t, 'B');
            await t.runAsync(() => storage.db.update(StoryRoomDao.roomTable,
                {'title': 'CHANGED', 'updatedAt': room.updatedAt + 1},
                where: 'id=?', whereArgs: [room.id]));
            await save(t);
            final row = await roomRow(t);
            expect(row['title'], 'CHANGED');
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!
                    .providerCode,
                'R');
            expect(find.textContaining('保存失败'), findsWidgets);
          }));
  testWidgets(
      'page original same-account login epoch cannot save a late dialog choice',
      (t) async => mocked(() async {
            await init(t);
            await roomEditor(t);
            await choose(t, 'B');
            await t.runAsync(() => LoginDao.saveAuthToken('synthetic-jwt',
                userName: 'S', extras: {'accountHash': 'account-a'}));
            await save(t);
            final row = await roomRow(t);
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!
                    .providerCode,
                'R');
            expect(posts, isEmpty);
          }));
  testWidgets(
      'page participant pair editing uses original row CAS and preserves local fields',
      (t) async => mocked(() async {
            await init(t);
            await t.longPress(find.text('Actor').first);
            await pump(t, 12);
            await t.tap(find.text('编辑房间内角色'));
            await pump(t, 16);
            await choose(t, 'B', participant: true);
            await save(t);
            final row = (await t.runAsync(
                    () => storage.db.query(StoryRoomDao.participantTable)))!
                .single;
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!
                    .providerCode,
                'B');
            expect(row['modelProviderId'], 'role-local');
            expect(row['modelId'], ' role-original ');
          }));
  for (final revoke in [false, true]) {
    testWidgets(
        'page ${revoke ? 'directory revocation' : 'account switch'} during original legacy preparation blocks POST and message writes',
        (t) async => mocked(() async {
              await init(t, legacyP: true);
              probeGate = Completer();
              probeEntered = Completer();
              await send(t);
              await until(
                  t, () => probeEntered!.isCompleted || posts.isNotEmpty);
              if (!probeEntered!.isCompleted) {
                expect(posts, isEmpty,
                    reason:
                        'legacy must resolve original selection before first completion');
                return;
              }
              if (revoke) {
                revoked = true;
                await t.runAsync(() => ModelCatalog.refreshFromBackend());
              } else {
                tokens.account = 'account-b';
              }
              probeGate!.complete();
              await finish(t);
              expect(posts, isEmpty);
              final rows = await t
                  .runAsync(() => storage.db.query(StoryRoomDao.messageTable));
              expect(rows, isEmpty);
            }));
  }
  testWidgets(
      'page workbench keeps room pair across global and persisted room edits; generated context does not roll back selection',
      (t) async => mocked(() async {
            await init(t, workbench: true);
            postGate = Completer();
            postEntered = Completer();
            await t.tap(find.text('剧情导演审阅'));
            await pump(t, 3);
            await until(t, () => postEntered!.isCompleted);
            await t.runAsync(() => settings.update(
                settings.settings.clone()..backendSelection = pair('Q')));
            await t.runAsync(() => storage.db.update(StoryRoomDao.roomTable,
                {'backendSelection': pair('B').toSqlValue()},
                where: 'id=?', whereArgs: [room.id]));
            postGate!.complete();
            await until(t, () => find.text('保存为资料').evaluate().isNotEmpty);
            await t.tap(find.text('保存为资料'));
            await pump(t, 16);
            expect(posts.single['providerCode'], 'R');
            final row = await roomRow(t);
            expect(
                BackendSelection.fromStorage(row['backendSelection'])!
                    .providerCode,
                'B');
            final usage = await t.runAsync(() => storage.db.query('tb_usage'));
            expect(
                usage!.single['providerId'], backendUsageProviderId(pair('R')));
          }));
  testWidgets(
      'page workbench original origin prevents late generated preview save',
      (t) async => mocked(() async {
            await init(t, workbench: true);
            await t.tap(find.text('剧情导演审阅'));
            await until(t, () => find.text('保存为资料').evaluate().isNotEmpty);
            BackendConfig.host = 'other.synthetic.invalid';
            await t.tap(find.text('保存为资料'));
            await pump(t, 16);
            final rows =
                await t.runAsync(() => storage.db.query('tb_story_artifact'));
            expect(rows, isEmpty);
            expect(posts.length, 1);
          }));
}
