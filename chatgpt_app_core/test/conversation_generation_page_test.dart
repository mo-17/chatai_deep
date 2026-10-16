import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/pages/conversation_list_page.dart';
import 'package:chatgpt_app_core/widget/conversation_widget.dart';
import 'package:chatgpt_app_core/chat/application/composer_prediction_service.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/widget/chat_list.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/ui/conversation_generation_routes.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/fake_composer_chat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late DatabaseFactory? oldFactory;
  late HiDBManager storage;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late ConversationGenerationService service;
  late GlobalKey<NavigatorState> navigator;
  late Map<int, ConversationModel> models;
  WidgetTester? activeTester;
  final chats = <int, FakeComposerChat>{};
  final stores = <int, ConversationDraftStore>{};
  bool globalServiceUsed = false, listHome = false;
  ComposerPredictionService? pagePrediction;
  ReadAloudService? pageVoice;
  final transportEvidence = <Object>[];
  tearDownAll(() async {
    final path = Platform.environment['CHATAI_PAGE_TRANSPORT_EVIDENCE'];
    if (path != null) {
      await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert(transportEvidence));
    }
  });
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    LoginDao.resetHooksForTest();
    ModelCatalog.resetExecutionForTest();
    temp = await Directory.systemTemp.createTemp('chatai_continuity_page_');
    oldFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath('${temp.path}/db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => temp.path);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs!.clear();
    AISettingsDao.resetSecureStateForTest();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: _Guest(),
        onLogoutNavigate: () {}));
    final ai = AISettings.defaults()
      ..mode = AIMode.local
      ..activeProviderId = 'fixture'
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '合成',
            type: 'openai',
            enabled: true,
            apiKey: 'fixture-key',
            apiHost: 'http://127.0.0.1:1',
            selectedModelId: 'gpt-4o',
            models: [AiModel(id: 'gpt-4o')])
      ];
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor('guest'), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    theme = ThemeProvider();
    storage = await HiDBManager.instance(dbName: 'guest');
    final dao = await ConversationListDao.create(storage);
    models = {
      for (final cid in [301, 302, 303])
        cid: ConversationModel(
            cid: cid, title: '会话$cid', icon: '', speechInputEnabled: false)
    };
    for (final m in models.values) {
      m.id = await dao.saveConversation(m);
    }
    stores.clear();
    globalServiceUsed = false;
    listHome = false;
    chats.clear();
    pagePrediction = null;
    pageVoice = null;
    service = ConversationGenerationService(
        registry: ConversationExecutionRegistry.instance,
        observeApplication: false);
    navigator = GlobalKey<NavigatorState>();
  });
  Future<void> cleanup() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(service.runs.every((r) => r.ticket.released), isTrue,
        reason: 'test-body cleanup must release every owner ticket');
    if (!globalServiceUsed) service.dispose();
    LoginDao.resetHooksForTest();
    await HiDBManager.closeAll();
    settings.dispose();
    theme.dispose();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    databaseFactory = oldFactory;
    await temp.delete(recursive: true);
  }

  tearDown(() async {
    if (activeTester != null) {
      final cleaned = await activeTester!.runAsync(() async {
        await cleanup().timeout(const Duration(seconds: 8));
        return true;
      });
      expect(cleaned, true,
          reason: 'fixture cleanup must complete, including on failure');
    } else {
      await cleanup();
    }
    activeTester = null;
  });
  Future<void> io(WidgetTester t, [int n = 1]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> until(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await io(t);
    }
    expect(done(), isTrue, reason: '有界等待真实 SQLite / transport 完成');
    expect(t.takeException(), isNull);
  }

  MessageInputWidget input(WidgetTester t) =>
      t.widget(find.byElementPredicate((e) =>
          e.widget is MessageInputWidget &&
          (ModalRoute.of(e)?.isCurrent ?? false)));
  Future<void> mount(WidgetTester t, {bool anime = false}) async {
    activeTester = t;
    await t.runAsync(() async {
      await t.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
            ChangeNotifierProvider<ThemeProvider>.value(value: theme)
          ],
          child: MaterialApp(
              navigatorKey: navigator,
              navigatorObservers: [ConversationGenerationRoutes.instance],
              themeAnimationDuration: Duration.zero,
              theme: anime
                  ? ThemeData(extensions: const [AppVisualTheme.anime])
                  : ThemeData(),
              home: listHome
                  ? const ConversationListPage()
                  : const Scaffold(body: Text('fixture list')))));
    });
  }

  Future<void> open(WidgetTester t, int cid,
      {bool fake = true, bool waitReady = true, int? initialTarget}) async {
    final chat = chats[cid];
    await t.runAsync(() async {
      unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
          settings: RouteSettings(name: 'fixture_$cid'),
          builder: (_) => ConversationPage(
              key: ValueKey('fixture_page_$cid'),
              conversationModel: models[cid]!,
              initialTargetCreatedAt: initialTarget,
              generationService: service,
              chatService: fake ? chat : null,
              predictionService: pagePrediction,
              readAloudService: pageVoice ?? const NoopReadAloudService(),
              draftStore: stores[cid] ??
                  ConversationDraftStore(
                      conversationId: '$cid',
                      accountHash: LoginDao.getAccountHash() ?? 'guest',
                      directoryResolver: () async => temp)))));
      await t.pump();
    });
    if (!waitReady) return;
    final target = find.descendant(
        of: find.byKey(ValueKey('fixture_page_$cid')),
        matching: find.byElementPredicate((e) =>
            e.widget is MessageInputWidget &&
            (ModalRoute.of(e)?.isCurrent ?? false)));
    await until(
        t,
        () =>
            target.evaluate().isNotEmpty &&
            (t.widget<MessageInputWidget>(target).enable ||
                t.widget<MessageInputWidget>(target).isStreaming));
    await io(t, 3);
  }

  Future<void> send(WidgetTester t, String text) async {
    input(t).controller!.text = text;
    await t.pump();
    await t.runAsync(() async {
      input(t).onSend?.call();
    });
    await io(t);
  }

  Future<List<Map<String, Object?>>> rows(
          WidgetTester t, String table, int cid) async =>
      (await t.runAsync(() => storage.db.query(table,
          where: 'cid=?', whereArgs: [cid], orderBy: 'createdAt asc')))!;
  Future<void> close(WidgetTester t) async {
    var settled = false;
    final stopping = Future.wait(service.runs
        .where((r) => !r.retired && identical(r.dao.storage.db, storage.db))
        .map((r) => r.retire('fixture completion')));
    stopping.then((_) => settled = true);
    await until(t, () => settled);
    await stopping;
    await t.runAsync(() => t.pumpWidget(const SizedBox.shrink()));
    await io(t, 4);
    var idle = false;
    final waiting = ConversationDraftStore(
        conversationId: '0',
        accountHash: 'guest',
        directoryResolver: () async => temp).whenIdle();
    waiting.then((_) => idle = true);
    await until(t, () => idle);
    await waiting;
  }

  void pageTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      try {
        await body(t);
      } finally {
        await close(t);
      }
    });
  }

  pageTest('review P2-1 preparing pop consumes original file draft', (t) async {
    final file = File('${temp.path}/original.txt');
    await t.runAsync(() => file.writeAsString('合成文件事实'));
    final draft = ConversationDraftStore(
        accountHash: 'guest',
        conversationId: '301',
        directoryResolver: () async => temp);
    stores[301] = draft;
    await t.runAsync(() => draft.save(text: 'CONSUMED', files: [file.path]));
    chats[301] = FakeComposerChat(content: 'FILE_SAVED');
    await mount(t);
    await open(t, 301);
    final entered = Completer<void>(), release = Completer<void>();
    late Future<void> lease;
    await t.runAsync(() async {
      lease = LoginDao.runWithStableAccount(
          expectedAccountHash: 'guest',
          action: () async {
            entered.complete();
            await release.future;
          });
    });
    try {
      await until(t, () => entered.isCompleted);
      input(t).onSend!.call();
      final run = service.lookup('guest', 301)!;
      expect(run.input.user.content, 'CONSUMED');
      navigator.currentState!.pop();
      await io(t, 15);
      expect(find.byType(ConversationPage), findsNothing);
      expect(run.acceptedUser, isNull);
      release.complete();
      await t.runAsync(() => lease);
      await until(t, () => !run.busy);
      await open(t, 301);
      expect(input(t).controller!.text, isEmpty);
      expect(input(t).pendingFiles, isEmpty);
      expect(chats[301]!.calls, 1);
      expect(await rows(t, 'tb_messages', 301), hasLength(2));
      final owned =
          run.acceptedUserBlocks.whereType<FileBlock>().single.file.path;
      expect(await t.runAsync(() => File(owned!).exists()), true);
    } finally {
      if (!release.isCompleted) release.complete();
      await t.runAsync(() => lease);
    }
  });

  for (final outcome in ['pop', 'stay', 'new-slot', 'failure']) {
    pageTest('followup 1b reopen original slot $outcome', (t) async {
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = (await t
          .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
      final entered = Completer<void>(), release = Completer<void>();
      var lists = 0;
      await t.runAsync(() async {
        server.listen((r) async {
          final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
          if (body['method'] == 'notifications/initialized') {
            r.response.statusCode = 202;
          } else {
            if (body['method'] == 'tools/list') {
              lists++;
              entered.complete();
              await release.future;
            }
            r.response.headers.contentType = ContentType.json;
            r.response.write(jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': body['method'] == 'initialize'
                  ? {
                      'protocolVersion': '2024-11-05',
                      'capabilities': {'tools': {}},
                      'serverInfo': {'name': 'fixture', 'version': '1'}
                    }
                  : {'tools': []}
            }));
          }
          await r.response.close();
        });
        await settings.update(settings.settings.clone()
          ..streamEnabled = true
          ..mcpServers = [
            McpServerConfig(
                id: 'fixture',
                name: 'fixture',
                url: 'http://127.0.0.1:${server.port}/',
                trusted: true)
          ]);
      });
      final file = File('${temp.path}/submitted.txt');
      await t.runAsync(() => file.writeAsString('SUBMITTED_FILE'));
      final draft = ConversationDraftStore(
          accountHash: 'guest',
          conversationId: '301',
          directoryResolver: () async => temp);
      stores[301] = draft;
      await t.runAsync(
          () => draft.save(text: 'REOPEN_SUBMITTED', files: [file.path]));
      chats[301] = FakeComposerChat(content: 'FINAL_AFTER_REOPEN');
      await mount(t, anime: outcome == 'stay' || outcome == 'failure');
      await open(t, 301);
      expect(input(t).controller!.text, 'REOPEN_SUBMITTED');
      expect(input(t).pendingFiles, hasLength(1));
      try {
        await t.runAsync(() async => input(t).onSend!.call());
        await until(
            t,
            () =>
                entered.isCompleted ||
                service.lookup('guest', 301)?.ticket.released == true);
        expect(entered.isCompleted, true,
            reason:
                '${service.lookup('guest', 301)?.stage} ${service.lookup('guest', 301)?.notice}');
        final run = service.lookup('guest', 301)!;
        expect(run.inputConsumed, false);
        navigator.currentState!.pop();
        await io(t, 15);
        await open(t, 301);
        await t.pump(const Duration(milliseconds: 450));
        await io(t, 5);
        expect(run.inputConsumed, false);
        if (outcome == 'new-slot') {
          navigator.currentState!.pop();
          await io(t, 15);
          final newer = File('${temp.path}/newer.txt');
          await t.runAsync(() => newer.writeAsString('NEW_SLOT_FILE'));
          await t.runAsync(
              () => draft.save(text: 'REOPEN_SUBMITTED', files: [newer.path]));
          await open(t, 301);
          await t.pump(const Duration(milliseconds: 450));
          await io(t, 4);
        } else if (outcome == 'pop') {
          navigator.currentState!.pop();
          await io(t, 15);
        }
        if (outcome == 'failure') {
          await t.runAsync(() => run.stop('用户停止未接受提交'));
        }
        release.complete();
        await until(t, () => run.ticket.released);
        await io(t, 4);
        if (outcome == 'pop') await open(t, 301);
        if (outcome == 'new-slot' || outcome == 'failure') {
          expect(input(t).controller!.text, 'REOPEN_SUBMITTED');
          expect(input(t).pendingFiles, hasLength(1));
          expect(
              await t.runAsync(
                  () => File(input(t).pendingFiles.single).readAsString()),
              outcome == 'new-slot' ? 'NEW_SLOT_FILE' : 'SUBMITTED_FILE');
        } else {
          expect(input(t).controller!.text, isEmpty);
          expect(input(t).pendingFiles, isEmpty);
        }
        expect(chats[301]!.calls, outcome == 'failure' ? 0 : 1);
        expect(lists, 1);
        expect(await rows(t, 'tb_messages', 301),
            hasLength(outcome == 'failure' ? 0 : 2));
        if (outcome != 'failure') {
          final owned =
              run.acceptedUserBlocks.whereType<FileBlock>().single.file.path!;
          expect(await t.runAsync(() => File(owned).readAsString()),
              'SUBMITTED_FILE');
        }
      } finally {
        if (!release.isCompleted) release.complete();
        await t.runAsync(() => server.close(force: true));
        HttpOverrides.global = oldOverrides;
      }
    });
  }

  pageTest(
      'followup 1b draft replaced during init never restores stale snapshot',
      (t) async {
    final gate = _LoadGate(temp, '301');
    stores[301] = gate;
    await t.runAsync(() => gate.save(text: 'OLD_READ'));
    chats[301] = FakeComposerChat();
    await mount(t);
    await open(t, 301, waitReady: false);
    await until(t, () => gate.started.isCompleted);
    await t.runAsync(
        () => gate.save(text: 'NEW_SLOT').timeout(const Duration(seconds: 3)));
    gate.release.complete();
    await until(t, () => input(t).enable);
    expect(input(t).controller!.text, 'NEW_SLOT');
    navigator.currentState!.pop();
    await io(t, 15);
    ConversationDraft? restored;
    await t.runAsync(() async {
      unawaited(gate.load().then((draft) => restored = draft));
    });
    await until(t, () => restored != null);
    expect(restored!.text, 'NEW_SLOT');
    expect(chats[301]!.calls, 0);
    expect(await rows(t, 'tb_messages', 301), isEmpty);
  });

  pageTest('followup 2b search target older than model1000 stays in UI',
      (t) async {
    await t.runAsync(() => MessageDao.create(storage, cid: 301));
    await t.runAsync(() => storage.db.transaction((tx) async {
          for (var i = 1; i <= 1010; i++) {
            await tx.insert('tb_messages', {
              'cid': 301,
              'createdAt': i,
              'ownerType': i.isOdd ? 'OwnerType.sender' : 'OwnerType.receiver',
              'ownerName': '合成',
              'avatar': '',
              'content': 'HISTORY_$i',
            });
          }
        }));
    chats[301] = FakeComposerChat();
    await mount(t);
    await open(t, 301, initialTarget: 1);
    final list = t.widget<ChatList>(find.byType(ChatList));
    expect(list.chatController.initialMessageList.map((m) => m.createdAt),
        contains(1));
    expect(list.chatController.initialMessageList, hasLength(1010));
    expect(chats[301]!.calls, 0);
    final bounded = await t.runAsync(() async =>
        (await MessageDao.create(storage, cid: 301)).loadContextCandidates());
    expect(bounded!.messages.length, lessThanOrEqualTo(1000));
    expect(bounded.messages.any((m) => m.createdAt == 1), false);
    await send(t, 'HISTORY_NEXT');
    await until(t, () => service.lookup('guest', 301)!.ticket.released);
    expect(jsonEncode(chats[301]!.histories.single),
        isNot(contains('HISTORY_1"')));
  });

  pageTest(
      'followup 2b target outside8MiB remains visible and model stays bounded',
      (t) async {
    await t.runAsync(() => MessageDao.create(storage, cid: 301));
    await t.runAsync(() => storage.db.transaction((tx) async {
          for (var i = 1; i <= 40; i++) {
            await tx.insert('tb_messages', {
              'cid': 301,
              'createdAt': i,
              'ownerType': i.isOdd ? 'OwnerType.sender' : 'OwnerType.receiver',
              'ownerName': '合成',
              'avatar': '',
              'content': 'BYTE_$i',
              if (i == 31)
                'blocks': jsonEncode([
                  {
                    'type': 'mainText',
                    'id': 'large',
                    'messageId': '31',
                    'createdAt': 31,
                    'status': 'success',
                    'content': 'BYTE_31',
                    'unmappedPadding': 'A' * (9 * 1024 * 1024)
                  }
                ])
            });
          }
        }));
    chats[301] = FakeComposerChat();
    await mount(t);
    await open(t, 301, initialTarget: 1);
    final list = t.widget<ChatList>(find.byType(ChatList));
    expect(list.chatController.initialMessageList, hasLength(40));
    expect(list.chatController.initialMessageList.map((m) => m.createdAt),
        contains(1));
    final bounded = await t.runAsync(() async =>
        (await MessageDao.create(storage, cid: 301)).loadContextCandidates());
    expect(bounded!.hasEarlierMessages, true);
    expect(bounded.messages.any((m) => m.createdAt == 1), false);
    expect(bounded.storedBytes, lessThanOrEqualTo(8 * 1024 * 1024));
    expect(chats[301]!.calls, 0);
  });

  pageTest(
      'followup 2b final insert and deletion while loading preserve cursor and directory',
      (t) async {
    await t.runAsync(() => MessageDao.create(storage, cid: 301));
    await t.runAsync(() => storage.db.transaction((tx) async {
          for (var i = 1; i <= 60; i++) {
            await tx.insert('tb_messages', {
              'cid': 301,
              'createdAt': i,
              'ownerType': i.isOdd ? 'OwnerType.sender' : 'OwnerType.receiver',
              'content': 'CURSOR_$i',
              'avatar': '',
              'ownerName': '合成'
            });
          }
        }));
    final gate = _LoadGate(temp, '301');
    stores[301] = gate;
    chats[301] = FakeComposerChat();
    await mount(t);
    await open(t, 301, waitReady: false);
    await until(t, () => gate.started.isCompleted);
    await t.runAsync(() => storage.db.transaction((tx) async {
          await tx.delete('tb_messages',
              where: 'cid=? and createdAt=?', whereArgs: [301, 60]);
          for (final i in [61, 62]) {
            await tx.insert('tb_messages', {
              'cid': 301,
              'createdAt': i,
              'ownerType': i.isOdd ? 'OwnerType.sender' : 'OwnerType.receiver',
              'content': 'CURSOR_$i',
              'avatar': '',
              'ownerName': '合成'
            });
          }
        }));
    gate.release.complete();
    await until(t, () => input(t).enable);
    final list = t.widget<ChatList>(find.byType(ChatList));
    expect(list.chatController.initialMessageList.map((m) => m.createdAt),
        contains(62));
    expect(list.chatController.initialMessageList.any((m) => m.createdAt == 60),
        false);
    await t.tap(find.byTooltip('更多'));
    await t.pumpAndSettle();
    await t.tap(find.text('对话目录'));
    await until(t, () => list.chatController.initialMessageList.length == 61);
    final ids =
        list.chatController.initialMessageList.map((m) => m.createdAt).toList();
    expect(ids.toSet(), hasLength(61));
    expect(ids, contains(1));
    expect(ids, contains(62));
    expect(ids, isNot(contains(60)));
    expect(t.takeException(), isNull);
    expect(chats[301]!.calls, 0);
  });

  pageTest(
      'review P2-2 completes after history read during draft initialization',
      (t) async {
    chats[301] = FakeComposerChat()..pending = Completer();
    await mount(t);
    await open(t, 301);
    await send(t, 'INIT_A');
    await until(t, () => chats[301]!.calls == 1);
    final run = service.lookup('guest', 301)!;
    navigator.currentState!.pop();
    await io(t, 4);
    final gate = _LoadGate(temp, '301');
    stores[301] = gate;
    await open(t, 301, waitReady: false);
    await until(t, () => gate.started.isCompleted);
    chats[301]!.pending!.complete(const ChatCompletionResult(
        content: 'FINAL_DURING_INIT', promptTokens: 5, completionTokens: 2));
    await until(t, () => !run.busy);
    gate.release.complete();
    await until(t, () => input(t).enable);
    final list = t.widget<ChatList>(find.byType(ChatList));
    expect(list.chatController.initialMessageList.map((m) => m.content),
        contains('FINAL_DURING_INIT'));
    chats[301]!.pending = null;
    chats[301]!.content = 'NEXT';
    await send(t, 'NEXT_INPUT');
    await until(t, () => !service.lookup('guest', 301)!.busy);
    expect(
        jsonEncode(chats[301]!.histories.last), contains('FINAL_DURING_INIT'));
    expect(chats[301]!.calls, 2);
    expect(await rows(t, 'tb_usage', 301), hasLength(2));
  });

  pageTest(
      'review P2-4 thinking-only role final retains continuation after reopen',
      (t) async {
    final assistant = AssistantModel(
        name: '合成角色', emoji: '', prompt: '受控角色', useTools: false);
    assistant.id = await t.runAsync<int?>(() async =>
        await (await AssistantDao.create(storage)).saveAssistant(assistant));
    models[301]!.assistantId = assistant.id;
    await t.runAsync(() async => (await ConversationListDao.create(storage))
        .saveConversation(models[301]!));
    await t.runAsync(
        () => settings.update(settings.settings.clone()..streamEnabled = true));
    chats[301] = _ThinkingOnlyChat();
    await mount(t);
    await open(t, 301);
    await send(t, 'ROLE_ONLY');
    await until(t, () => !service.lookup('guest', 301)!.busy);
    final run = service.lookup('guest', 301)!;
    final dbRows = await rows(t, 'tb_messages', 301);
    expect(
        MessageBlock.decodeList(dbRows.last['blocks'] as String?)
            .whereType<RoleContinuationBlock>(),
        hasLength(1));
    expect(run.completion!.currentRoleContinuationHistory[run.receiverAt],
        contains('心理状态'));
    navigator.currentState!.pop();
    await io(t, 4);
    chats[301] = FakeComposerChat(content: '开口');
    await open(t, 301);
    await send(t, '继续');
    await until(t, () => !service.lookup('guest', 301)!.busy);
    expect(jsonEncode(chats[301]!.histories.single), contains('心理状态'));
  });

  pageTest('review P2-3 actual list refreshes off-page final summary and count',
      (t) async {
    service.dispose();
    service = ConversationGenerationService.instance;
    globalServiceUsed = true;
    chats[301] = FakeComposerChat()..pending = Completer();
    listHome = true;
    await mount(t);
    await until(
        t, () => find.byType(ConversationWidget).evaluate().length == 3);
    await open(t, 301);
    await send(t, 'LIST_A');
    await until(t, () => chats[301]!.calls == 1);
    final run = service.lookup('guest', 301)!;
    navigator.currentState!.pop();
    await io(t, 5);
    chats[301]!.pending!.complete(const ChatCompletionResult(
        content: 'OFFPAGE_LIST_FINAL', promptTokens: 4, completionTokens: 3));
    await until(t, () => !run.busy);
    await io(t, 5);
    final tiles = t
        .widgetList<ConversationWidget>(find.byType(ConversationWidget))
        .toList();
    expect(tiles.first.model.cid, 301);
    final row = tiles.singleWhere((w) => w.model.cid == 301).model;
    expect(row.lastMessage, 'OFFPAGE_LIST_FINAL');
    expect(row.messageCount, 2);
  });
  pageTest(
      'review P2-1 accepted commit before UI host removal never returns input',
      (t) async {
    final gate = _ManifestGate(temp, '301');
    stores[301] = gate;
    await t.runAsync(() => gate.save(text: 'ACCEPTED_BEFORE_UI'));
    chats[301] = FakeComposerChat(content: 'ACCEPTED_FINAL');
    await mount(t);
    await open(t, 301);
    try {
      await t.runAsync(() async {
        input(t).onSend!.call();
        for (var i = 0;
            i < 150 && service.lookup('guest', 301)?.inputConsumed != true;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final run = service.lookup('guest', 301)!;
        expect(run.inputConsumed, true);
        expect(
            (await storage.db.query('tb_messages',
                where: 'ownerType=?', whereArgs: ['OwnerType.sender'])),
            hasLength(1));
        expect(input(t).controller!.text, 'ACCEPTED_BEFORE_UI');
        await t.pumpWidget(const SizedBox.shrink());
      });
      gate.release.complete();
      final run = service.lookup('guest', 301)!;
      await until(t, () => !run.busy);
      stores.remove(301);
      await mount(t);
      await open(t, 301);
      expect(input(t).controller!.text, isEmpty);
      expect(chats[301]!.calls, 1);
    } finally {
      if (!gate.release.isCompleted) gate.release.complete();
    }
  });

  pageTest('review P2-1 later text and attachment survive preparing pop',
      (t) async {
    chats[301] = FakeComposerChat(content: 'OLD_FINISHED');
    final file = File('${temp.path}/later.txt');
    await t.runAsync(() => file.writeAsString('LATER_FILE'));
    await mount(t);
    await open(t, 301);
    final entered = Completer<void>(), release = Completer<void>();
    late Future<void> lease;
    await t.runAsync(() async {
      lease = LoginDao.runWithStableAccount(
          expectedAccountHash: 'guest',
          action: () async {
            entered.complete();
            await release.future;
          });
    });
    try {
      await until(t, () => entered.isCompleted);
      input(t).controller!.text = 'SUBMITTED_NO_MANIFEST';
      input(t).onSend!.call();
      final run = service.lookup('guest', 301)!;
      input(t).controller!.text = 'LATER_DRAFT';
      input(t).onChanged?.call('LATER_DRAFT');
      // 生成期间附件选择被锁；新草稿由独立 draft writer 保存，不绕过 UI 锁。
      final draft = ConversationDraftStore(
          accountHash: 'guest',
          conversationId: '301',
          directoryResolver: () async => temp);
      navigator.currentState!.pop();
      await io(t, 15);
      late Future<ConversationDraft?> newer;
      await t.runAsync(() async {
        newer = draft.save(text: 'LATER_DRAFT', files: [file.path]);
      });
      release.complete();
      await t.runAsync(() => lease);
      await until(t, () => !run.busy);
      var draftSettled = false;
      newer.then((_) => draftSettled = true);
      await until(t, () => draftSettled);
      expect(await t.runAsync(() => newer), isNotNull);
      await open(t, 301);
      expect(input(t).controller!.text, 'LATER_DRAFT');
      expect(input(t).pendingFiles, hasLength(1));
      expect(
          await t.runAsync(
              () => File(input(t).pendingFiles.single).readAsString()),
          'LATER_FILE');
      expect(run.input.user.content, 'SUBMITTED_NO_MANIFEST');
      expect(chats[301]!.calls, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      await t.runAsync(() => lease);
    }
  });

  pageTest(
      'review P2-2 terminal reply deleted during init never resurrects cache',
      (t) async {
    chats[301] = FakeComposerChat()..pending = Completer();
    final predictionChat = FakeComposerChat(content: '不应请求');
    pagePrediction =
        ComposerPredictionService(chatFactory: (_) => predictionChat);
    final voice = _Voice();
    pageVoice = voice;
    await mount(t);
    await open(t, 301);
    await send(t, 'DELETE_DURING_INIT');
    await until(t, () => chats[301]!.calls == 1);
    final run = service.lookup('guest', 301)!;
    navigator.currentState!.pop();
    await io(t, 15);
    final gate = _LoadGate(temp, '301');
    stores[301] = gate;
    await open(t, 301, waitReady: false);
    try {
      await until(t, () => gate.started.isCompleted);
      chats[301]!.pending!.complete(const ChatCompletionResult(
          content: 'DELETED_FINAL', promptTokens: 1, completionTokens: 1));
      await until(t, () => !run.busy);
      await t.runAsync(() => storage.db.delete('tb_messages',
          where: 'id=?', whereArgs: [run.record!.receiverRowId]));
      gate.release.complete();
      await until(t, () => input(t).enable);
      expect(
          t
              .widget<ChatList>(find.byType(ChatList))
              .chatController
              .initialMessageList
              .map((m) => m.content),
          isNot(contains('DELETED_FINAL')));
      expect(voice.calls, 0);
      expect(predictionChat.calls, 0);
      expect(chats[301]!.calls, 1);
      expect(await rows(t, 'tb_usage', 301), hasLength(1));
      chats[301]!.pending = null;
      await send(t, 'NEXT');
      await until(t, () => !service.lookup('guest', 301)!.busy);
      expect(jsonEncode(chats[301]!.histories.last),
          isNot(contains('DELETED_FINAL')));
    } finally {
      if (!gate.release.isCompleted) gate.release.complete();
    }
  });

  pageTest(
      'review P2-3 actual list birth after pop and awaiting confirmation stop',
      (t) async {
    service.dispose();
    service = ConversationGenerationService.instance;
    globalServiceUsed = true;
    listHome = true;
    models[304] = ConversationModel(
        cid: 304, title: '新建', icon: '', speechInputEnabled: false);
    chats[304] = FakeComposerChat()..pending = Completer();
    await mount(t);
    await until(
        t, () => find.byType(ConversationWidget).evaluate().length == 3);
    await open(t, 304);
    final entered = Completer<void>(), release = Completer<void>();
    late Future<void> lease;
    await t.runAsync(() async {
      lease = LoginDao.runWithStableAccount(
          expectedAccountHash: 'guest',
          action: () async {
            entered.complete();
            await release.future;
          });
    });
    try {
      await until(t, () => entered.isCompleted);
      input(t).controller!.text = 'BIRTH_AFTER_POP';
      await t.runAsync(() async {
        input(t).onSend!.call();
      });

      final run = service.lookup('guest', 304)!;
      navigator.currentState!.pop();
      await io(t, 15);
      expect(find.byType(ConversationWidget), findsNWidgets(3));

      release.complete();
      await t.runAsync(() => lease.timeout(const Duration(seconds: 2)));

      await until(
          t,
          () =>
              chats[304]!.calls == 1 &&
              find.byType(ConversationWidget).evaluate().length == 4);
      late Future<Object> answer;
      await t.runAsync(() async {
        answer = run
            .confirm('仅A可见确认', '合成')
            .then<Object>((v) => v, onError: (Object e) => e);
      });

      await until(t, () => find.text('等待确认').evaluate().isNotEmpty);

      expect(find.byType(AlertDialog), findsNothing);
      await t.runAsync(() async {
        await t.tap(find.text('停止'));
      });

      await until(t, () => run.ticket.released);

      expect(await t.runAsync(() => answer.timeout(const Duration(seconds: 2))),
          isA<ChatTransportException>());

      expect(chats[304]!.calls, 1);
      expect(run.executionStopped, true);
      expect(find.text('等待确认'), findsNothing);
    } finally {
      if (!release.isCompleted) release.complete();
      await t.runAsync(() => lease);
    }
  });

  pageTest(
      'review P2-3 actual list retry saved response updates count with zero new request',
      (t) async {
    service.dispose();
    service = ConversationGenerationService.instance;
    globalServiceUsed = true;
    listHome = true;
    chats[301] = FakeComposerChat(content: 'SAVED_FROM_LIST');
    await t.runAsync(() => storage.db.execute(
        "create trigger failed_reply before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'synthetic disk'); end"));
    await mount(t);
    await until(
        t, () => find.byType(ConversationWidget).evaluate().length == 3);
    await open(t, 301);
    await send(t, 'SAVE_RETRY');
    final run = service.lookup('guest', 301)!;
    await until(t, () => run.persistencePending);
    navigator.currentState!.pop();
    await io(t, 15);
    await until(t, () => find.text('回复待保存').evaluate().isNotEmpty);
    await t.runAsync(() => storage.db.execute('drop trigger failed_reply'));
    await t.runAsync(() async {
      await t.tap(find.text('重试保存'));
    });
    await until(t, () => run.ticket.released);
    await until(
        t,
        () => t
            .widgetList<ConversationWidget>(find.byType(ConversationWidget))
            .any((w) => w.model.lastMessage == 'SAVED_FROM_LIST'));
    final model = t
        .widgetList<ConversationWidget>(find.byType(ConversationWidget))
        .singleWhere((w) => w.model.cid == 301)
        .model;
    expect(model.messageCount, 2);
    expect(chats[301]!.calls, 1);
    expect(await rows(t, 'tb_usage', 301), hasLength(1));
  });
  for (final anime in [false, true]) {
    pageTest(
        'dual pages ${anime ? "anime" : "classic"}: two runs, third rejected, pop/reopen same identity',
        (t) async {
      chats[301] = FakeComposerChat()..pending = Completer();
      chats[302] = FakeComposerChat()..pending = Completer();
      chats[303] = FakeComposerChat(content: 'THIRD');
      await mount(t, anime: anime);
      await open(t, 301);
      await send(t, 'TASK_A');
      await until(t, () => chats[301]!.calls == 1);
      final a = service.lookup('guest', 301)!;
      final id = a.runId;
      navigator.currentState!.pop();
      await io(t, 3);
      expect(a.current, isTrue);
      expect(a.executionStopped, isFalse);
      await open(t, 302);
      await send(t, 'TASK_B');
      await until(t, () => chats[302]!.calls == 1);
      final b = service.lookup('guest', 302)!;
      navigator.currentState!.pop();
      await io(t, 3);
      await open(t, 303);
      await send(t, 'THIRD_DRAFT');
      await io(t, 8);
      expect(chats[303]!.calls, 0);
      expect(input(t).controller!.text, 'THIRD_DRAFT');
      expect(service.lookup('guest', 303), isNull);
      navigator.currentState!.pop();
      await io(t, 3);
      await open(t, 301);
      expect(service.lookup('guest', 301)!.runId, id);
      expect(chats[301]!.calls, 1);
      chats[301]!.pending!.complete(const ChatCompletionResult(
          content: 'ANSWER_A', promptTokens: 11, completionTokens: 3));
      chats[302]!.pending!.complete(const ChatCompletionResult(
          content: 'ANSWER_B', promptTokens: 12, completionTokens: 4));
      await until(t, () => !a.busy && !b.busy);
      expect((await rows(t, 'tb_messages', 301)).map((r) => r['content']),
          ['TASK_A', 'ANSWER_A']);
      expect((await rows(t, 'tb_messages', 302)).map((r) => r['content']),
          ['TASK_B', 'ANSWER_B']);
      expect(await rows(t, 'tb_usage', 301), hasLength(1));
      expect(await rows(t, 'tb_usage', 302), hasLength(1));
      expect(
          t
              .widget<ChatList>(find.byElementPredicate((e) =>
                  e.widget is ChatList &&
                  (ModalRoute.of(e)?.isCurrent ?? false)))
              .chatController
              .initialMessageList
              .map((m) => m.content),
          contains('ANSWER_A'));
      expect(chats[301]!.calls, 1);
      expect(chats[302]!.calls, 1);
      navigator.currentState!.pop();
      await io(t, 3);
      await open(t, 302);
      expect(chats[302]!.calls, 1);
      expect(
          t
              .widget<ChatList>(find.byElementPredicate((e) =>
                  e.widget is ChatList &&
                  (ModalRoute.of(e)?.isCurrent ?? false)))
              .chatController
              .initialMessageList
              .map((m) => m.content),
          contains('ANSWER_B'));
    });
  }
  pageTest(
      'visible host confirmation stays with original cid, pop/reopen and late answer refused',
      (t) async {
    chats[301] = FakeComposerChat()..pending = Completer();
    chats[302] = FakeComposerChat();
    await mount(t);
    await open(t, 301);
    await send(t, 'CONFIRM_A');
    await until(t, () => chats[301]!.calls == 1);
    final a = service.lookup('guest', 301)!;
    final asking = a.confirm('合成写入确认', '仅原会话可确认');
    // 失败清理也会终止等待，仍由下面的 await 验证最终结果。
    asking.ignore();
    await until(
        t,
        () => find
            .byKey(const ValueKey('ordinary_confirm_action'))
            .evaluate()
            .isNotEmpty);
    final confirmationId = a.confirmation!.id;
    await open(t, 302);
    await io(t, 4);
    await until(
        t,
        () => find
            .byKey(const ValueKey('ordinary_confirm_action'))
            .evaluate()
            .isEmpty);
    expect(find.byKey(const ValueKey('ordinary_confirm_action')), findsNothing);
    expect(a.confirmation!.id, confirmationId);
    expect(
        await t.runAsync(() => a.answerConfirmation(
            host: Object(), confirmationId: confirmationId, accepted: true)),
        false);
    navigator.currentState!.pop();
    await io(t, 4);
    await until(
        t,
        () => find
            .byKey(const ValueKey('ordinary_confirm_action'))
            .evaluate()
            .isNotEmpty);
    await t.tap(find.byKey(const ValueKey('ordinary_confirm_action')));
    await io(t, 5);
    expect(await t.runAsync(() => asking), true);
    chats[301]!
        .pending!
        .complete(const ChatCompletionResult(content: 'CONFIRMED'));
    await until(t, () => !a.busy);
    expect(chats[301]!.calls, 1);
    expect(chats[302]!.calls, 0);
  });
  pageTest(
      'ordinary response completes while page disposed; reopen does not send or duplicate usage',
      (t) async {
    chats[301] = FakeComposerChat()..pending = Completer();
    await mount(t);
    await open(t, 301);
    await send(t, 'OFFSCREEN');
    await until(t, () => chats[301]!.calls == 1);
    final run = service.lookup('guest', 301)!;
    navigator.currentState!.pop();
    await io(t, 4);
    chats[301]!.pending!.complete(const ChatCompletionResult(
        content: 'SAVED_OFFSCREEN', promptTokens: 10, completionTokens: 2));
    await until(t, () => !run.busy);
    expect(run.stage, ConversationGenerationStage.complete);
    await open(t, 301);
    expect(chats[301]!.calls, 1);
    expect(await rows(t, 'tb_messages', 301), hasLength(2));
    expect(await rows(t, 'tb_usage', 301), hasLength(1));
  });
  pageTest(
      'failed final save: explicit save retry is zero model requests and personal candidate once',
      (t) async {
    final personal = (await t.runAsync(
        () => PersonalMemoryDao.create(storage, accountHash: 'guest')))!;
    final prefs = (await t.runAsync(personal.preferences))!;
    await t.runAsync(() => personal.setPreferences(
        revision: prefs.revision, enabled: true, suggestionsEnabled: true));
    chats[301] = FakeComposerChat()..pending = Completer();
    await mount(t);
    await open(t, 301);
    await send(t, '我希望回答简短清楚');
    await until(t, () => chats[301]!.calls == 1);
    final run = service.lookup('guest', 301)!;
    await t.runAsync(() => storage.db.execute(
        "create trigger fixture_reply_fail before insert on tb_messages when new.ownerType='OwnerType.receiver' begin select raise(abort,'fixture disk failure'); end"));
    chats[301]!.pending!.complete(const ChatCompletionResult(
        content: 'CANDIDATE_REPLY', promptTokens: 13, completionTokens: 3));
    await until(
        t,
        () =>
            run.persistencePending &&
            find
                .byKey(const ValueKey('ordinary_retry_save'))
                .evaluate()
                .isNotEmpty);
    expect(find.byKey(const ValueKey('ordinary_retry_save')), findsOneWidget);
    expect(await rows(t, 'tb_messages', 301), hasLength(1));
    expect((await t.runAsync(() => storage.db.query('tb_personal_memory')))!,
        isEmpty);
    await t
        .runAsync(() => storage.db.execute('drop trigger fixture_reply_fail'));
    await t.tap(find.byKey(const ValueKey('ordinary_retry_save')));
    await until(t, () => run.stage == ConversationGenerationStage.complete);
    await io(t, 5);
    expect(chats[301]!.calls, 1);
    expect(await rows(t, 'tb_messages', 301), hasLength(2));
    expect(await rows(t, 'tb_usage', 301), hasLength(1));
    final memories =
        (await t.runAsync(() => storage.db.query('tb_personal_memory')))!;
    expect(memories, hasLength(1));
    expect(memories.single['status'], 'pending');
    await t.runAsync(run.retryPersistence);
    await io(t, 4);
    navigator.currentState!.pop();
    await io(t, 4);
    await open(t, 301);
    expect(chats[301]!.calls, 1);
    expect((await t.runAsync(() => storage.db.query('tb_personal_memory')))!,
        hasLength(1));
  });
  pageTest(
      'only original fully visible completion starts prediction/read aloud once; reopening does neither',
      (t) async {
    final ai = settings.settings.clone()..composerPredictionsEnabled = true;
    await t.runAsync(() => settings.update(ai));
    models[301]!.readAloudEnabled = true;
    final prediction = FakeComposerChat();
    final voice = _Voice();
    pagePrediction = ComposerPredictionService(chatFactory: (_) => prediction);
    pageVoice = voice;
    chats[301] = FakeComposerChat()..pending = Completer();
    await mount(t);
    await open(t, 301);
    await send(t, 'VISIBLE_TURN');
    await until(t, () => chats[301]!.calls == 1);
    final run = service.lookup('guest', 301)!;
    chats[301]!
        .pending!
        .complete(const ChatCompletionResult(content: 'VISIBLE_REPLY'));
    await until(
        t, () => !run.busy && prediction.calls == 1 && voice.calls == 1);
    navigator.currentState!.pop();
    await io(t, 4);
    await open(t, 301);
    await io(t, 4);
    expect(prediction.calls, 1);
    expect(voice.calls, 1);
    // 第二轮离页后完成，不追加前台辅助请求。
    chats[301]!.pending = Completer();
    await send(t, 'HIDDEN_TURN');
    await until(t, () => chats[301]!.calls == 2);
    final hidden = service.lookup('guest', 301)!;
    navigator.currentState!.pop();
    await io(t, 4);
    chats[301]!
        .pending!
        .complete(const ChatCompletionResult(content: 'HIDDEN_REPLY'));
    await until(t, () => !hidden.busy);
    await open(t, 301);
    await io(t, 4);
    expect(prediction.calls, 1);
    expect(voice.calls, 1);
    expect(chats[301]!.calls, 2);
  });
  pageTest(
      'real regenerate action uses captured source/reply, keeps one sender and does not replay deleted terminal cache',
      (t) async {
    chats[301] = FakeComposerChat(content: 'ORIGINAL_REPLY');
    await mount(t);
    await open(t, 301);
    await send(t, 'ORIGINAL_USER');
    await until(
        t,
        () =>
            service.lookup('guest', 301)?.stage ==
            ConversationGenerationStage.complete);
    await io(t, 6);
    final list = t.widget<ChatList>(find.byElementPredicate(
        (e) => e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false)));
    final reply = list.chatController.initialMessageList.first;
    chats[301]!.pending = Completer();
    list.onBubbleLongPress!(
        reply,
        t.element(find.byElementPredicate((e) =>
            e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false))));
    await t.pumpAndSettle();
    await t.tap(find.text('重新生成'));
    await until(t, () => chats[301]!.calls == 2);
    expect(await rows(t, 'tb_messages', 301), hasLength(1));
    expect(
        t
            .widget<ChatList>(find.byElementPredicate((e) =>
                e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false)))
            .chatController
            .initialMessageList
            .map((m) => m.content),
        isNot(contains('ORIGINAL_REPLY')));
    chats[301]!
        .pending!
        .complete(const ChatCompletionResult(content: 'REGENERATED_REPLY'));
    await until(
        t,
        () =>
            service.lookup('guest', 301)!.stage ==
            ConversationGenerationStage.complete);
    await io(t, 6);
    final saved = await rows(t, 'tb_messages', 301);
    expect(
        saved.map((r) => r['content']), ['ORIGINAL_USER', 'REGENERATED_REPLY']);
    expect(saved.first['memorySourceId'], isNotNull);
    final regenerated = t
        .widget<ChatList>(find.byElementPredicate((e) =>
            e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false)))
        .chatController
        .initialMessageList
        .first;
    t
            .widget<ChatList>(find.byElementPredicate((e) =>
                e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false)))
            .onBubbleLongPress!(
        regenerated,
        t.element(find.byElementPredicate((e) =>
            e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false))));
    await t.pumpAndSettle();
    await t.tap(find.text('删除'));
    await io(t, 8);
    expect(await rows(t, 'tb_messages', 301), hasLength(1));
    expect(
        t
            .widget<ChatList>(find.byElementPredicate((e) =>
                e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false)))
            .chatController
            .initialMessageList
            .map((m) => m.content),
        isNot(contains('REGENERATED_REPLY')));
    navigator.currentState!.pop();
    await io(t, 4);
    await open(t, 301);
    expect(chats[301]!.calls, 2);
    expect(await rows(t, 'tb_messages', 301), hasLength(1));
    expect(
        t
            .widget<ChatList>(find.byElementPredicate((e) =>
                e.widget is ChatList && (ModalRoute.of(e)?.isCurrent ?? false)))
            .chatController
            .initialMessageList
            .map((m) => m.content),
        ['ORIGINAL_USER']);
    final index = (await t.runAsync(() => storage.db
            .query('tb_conversation_list', where: 'cid=?', whereArgs: [301])))!
        .single;
    expect(index['messageCount'], 1);
    expect(index['lastMessage'], 'ORIGINAL_USER');
  });
  for (final backend in [false, true]) {
    for (final kind in ['builtin', 'mcp']) {
      for (final outcome in ['late-reopen', 'stop']) {
        pageTest(
            'L2B3 tool $backend $kind $outcome actual model to page approval',
            (t) async {
          final oldOverrides = HttpOverrides.current;
          final oldHost = BackendConfig.host;
          final oldHttps = BackendConfig.useHttps;
          HttpOverrides.global = null;
          final toolName =
              kind == 'builtin' ? 'save_favorite' : 'mcp__s__write';
          final loop = (await t.runAsync(() => _PageToolLoop.open(toolName)))!;
          try {
            final ai = settings.settings.clone()..streamEnabled = true;
            BackendConfig.host = '127.0.0.1:${loop.server.port}';
            BackendConfig.useHttps = false;
            if (backend) {
              ai.mode = AIMode.backend;
              ai.backendModel = 'gpt-4o';
              final identity = LoginSdkConfig.instance.storage as _Guest;
              identity.token = 'synthetic-page-access-token';
              identity.profile!['guest'] = false;
              ai.backendSelection = BackendSelection.pair(
                  providerCode: 'openai',
                  modelId: 'gpt-4o',
                  accountHash: 'guest',
                  origin:
                      BackendConfig.buildUri('/uapi/chat/completions').origin);
            } else {
              ai.activeProvider.apiHost =
                  'http://127.0.0.1:${loop.server.port}/v1';
            }
            if (kind == 'mcp') {
              ai.mcpBackendEnabled = backend;
              ai.mcpBackendTrusted = false;
              ai.mcpServers = backend
                  ? []
                  : [
                      McpServerConfig(
                          id: 's',
                          name: '合成写工具',
                          url: 'http://127.0.0.1:${loop.server.port}/rpc',
                          headers: {'x-fixture': 'run-owned'},
                          trusted: false)
                    ];
            }
            models[301]!.toolIds = [toolName];
            await t.runAsync(() async {
              await settings.update(ai);
              await (await ConversationListDao.create(storage))
                  .saveConversation(models[301]!);
            });
            await mount(t, anime: backend);
            await open(t, 301, fake: false);
            await send(t, 'TOOL_PAGE_TASK');
            await until(
                t,
                () => find
                    .byKey(const ValueKey('ordinary_confirm_action'))
                    .evaluate()
                    .isNotEmpty);
            final run = service.lookup('guest', 301)!;
            expect(loop.posts, hasLength(1));
            expect(run.confirmation, isNotNull);
            expect(loop.toolCalls, isEmpty);
            expect(await t.runAsync(() => storage.db.query('tb_favorite')),
                isEmpty);
            if (outcome == 'stop') {
              await t.runAsync(() => run.stop('用户在真实工具确认中停止'));
              await until(t, () => run.ticket.released);
              await io(t, 5);
              expect(find.byKey(const ValueKey('ordinary_confirm_action')),
                  findsNothing);
              expect(loop.posts, hasLength(1));
              expect(loop.toolCalls, isEmpty);
              expect(await t.runAsync(() => storage.db.query('tb_favorite')),
                  isEmpty);
            } else {
              final oldButton = t.widget<FilledButton>(
                  find.byKey(const ValueKey('ordinary_confirm_action')));
              // 实际旧页面按钮先完成Dialog future，同步切B；回调恢复时B已是当前页。
              await t.runAsync(() async {
                oldButton.onPressed!();
                unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
                    builder: (_) => ConversationPage(
                        key: const ValueKey('tool_other_page'),
                        readAloudService: pageVoice ?? _Voice(),
                        conversationModel: models[302]!,
                        generationService: service,
                        draftStore: ConversationDraftStore(
                            accountHash: 'guest',
                            conversationId: '302',
                            directoryResolver: () async => temp)))));
              });
              await io(t, 4);
              await until(t, () => input(t).enable);
              await io(t, 5);
              expect(run.confirmation, isNotNull);
              expect(loop.posts, hasLength(1));
              expect(loop.toolCalls, isEmpty);
              expect(await t.runAsync(() => storage.db.query('tb_favorite')),
                  isEmpty);
              expect(find.byKey(const ValueKey('ordinary_confirm_action')),
                  findsNothing);
              navigator.currentState!.pop();
              await until(
                  t,
                  () => find
                      .byKey(const ValueKey('ordinary_confirm_action'))
                      .evaluate()
                      .isNotEmpty);
              expect(loop.posts, hasLength(1));
              await t
                  .tap(find.byKey(const ValueKey('ordinary_confirm_action')));
              await until(t, () => run.ticket.released);
              expect(run.stage, ConversationGenerationStage.complete);
              expect(loop.posts, hasLength(2));
              final second = loop.posts.last['messages'] as List;
              expect(second.where((m) => m['role'] == 'tool'), hasLength(1));
              expect(
                  second.any((m) =>
                      m['role'] == 'assistant' && m['tool_calls'] is List),
                  true);
              if (kind == 'builtin') {
                expect(
                    (await t.runAsync(() => storage.db.query('tb_favorite')))!
                        .single['content'],
                    'TOOL_CONTENT');
                expect(loop.toolCalls, isEmpty);
              } else {
                expect(loop.toolCalls, hasLength(1));
                expect(loop.toolCalls.single['arguments'],
                    {'content': 'TOOL_CONTENT'});
                final audits = (await t
                    .runAsync(() => storage.db.query('tb_tool_audit')))!;
                expect(
                    audits
                        .where((r) => r['approved'] == 1 && r['success'] == 1),
                    hasLength(1));
              }
              expect(await rows(t, 'tb_messages', 301), hasLength(2));
              expect(await rows(t, 'tb_usage', 301), hasLength(1));
            }
            transportEvidence.add({
              'case': 'L2B3-tool',
              'backend': backend,
              'kind': kind,
              'outcome': outcome,
              'posts': loop.posts,
              'toolCalls': loop.toolCalls,
              'mcpMethods': loop.methods
            });
          } finally {
            for (final r in service.runs.where(
                (r) => !r.retired && identical(r.dao.storage.db, storage.db))) {
              await t.runAsync(() => r.retire('tool-loop fixture cleanup'));
            }
            await t.runAsync(() => loop.server.close(force: true));
            HttpOverrides.global = oldOverrides;
            BackendConfig.host = oldHost;
            BackendConfig.useHttps = oldHttps;
          }
        });
      }
    }
  }

  Future<void> useSignedFixture(WidgetTester t) async {
    final saved = settings.settings.clone();
    await t.runAsync(() async {
      await LoginDao.saveAuthToken('synthetic-a',
          userName: '合成A', extras: const {'accountHash': 'a', 'avatar': ''});
      await HiCache.getInstance()
          .setString(AISettingsDao.keyFor('a'), jsonEncode(saved.toJson()));
      await settings.load();
      storage = await HiDBManager.instance(dbName: 'a');
      final dao = await ConversationListDao.create(storage);
      for (final m in models.values) {
        m.id = null;
        m.id = await dao.saveConversation(m);
      }
      service.dispose();
      service = ConversationGenerationService(observeApplication: true);
    });
  }

  for (final backend in [false, true]) {
    for (final control in [
      'login-ab',
      'login-aa',
      'restore',
      'restore-rollback',
      'profile',
      'source-delete',
      'conversation-delete',
      'stop',
      'save-retry'
    ]) {
      pageTest('L2B3 maintenance $backend $control actual page transport',
          (t) async {
        final previousOverrides = HttpOverrides.current;
        final oldHost = BackendConfig.host, oldHttps = BackendConfig.useHttps;
        HttpOverrides.global = null;
        final loop = (await t.runAsync(_PageHeldModel.open))!;
        final clientEnded = <bool>[];
        final clientErrors = <String>[];
        try {
          await useSignedFixture(t);
          final next = settings.settings.clone()..streamEnabled = true;
          next.mode = backend ? AIMode.backend : AIMode.local;
          next.backendModel = 'gpt-4o';
          next.providers.first.apiHost =
              'http://127.0.0.1:${loop.server.port}/v1';
          BackendConfig.host = '127.0.0.1:${loop.server.port}';
          BackendConfig.useHttps = false;
          if (backend) {
            next.backendSelection = BackendSelection.pair(
                providerCode: 'openai',
                modelId: 'gpt-4o',
                accountHash: 'a',
                origin:
                    BackendConfig.buildUri('/uapi/chat/completions').origin);
          }
          await t.runAsync(() => settings.update(next));
          service.dispose();
          service = ConversationGenerationService(
              observeApplication: true,
              createChat: (ai) {
                if (backend) {
                  return _PageObservedBackend(ai, clientEnded, clientErrors);
                }
                return _PageObservedDirect(ai, clientEnded, clientErrors);
              });
          List<int>? archive;
          final backup = BackupService(storage);
          BackupService.debugGeneratedImageDirectoryResolver = () async => temp;
          BackupService.debugRoleCardAssetsDirectoryResolver = () async => temp;
          if (control.startsWith('restore')) {
            archive = await t.runAsync(
                () => backup.exportArchive(settings: next, accountHash: 'a'));
          }
          await mount(t, anime: backend);
          await open(t, 301, fake: false);
          await send(t, 'HELD_PAGE_TASK');
          await until(
              t,
              () =>
                  loop.posts.length == 1 &&
                  service
                          .lookup('a', 301)
                          ?.dispatcher
                          .mainText
                          .contains('PARTIAL_HELD') ==
                      true);
          final run = service.lookup('a', 301)!;
          final source = run.record!.userRowId!;
          final oldStorage = storage;
          expect(run.acceptedUser, isNotNull);
          expect(run.ticket.released, false);
          expect(loop.release.isCompleted, false);
          var actionDone = false;
          Object? actionError;
          Future<void>? action;
          if (control == 'save-retry') {
            await t.runAsync(() => storage.db.execute(
                "create trigger page_reply_fail before insert on tb_messages when NEW.ownerType='OwnerType.receiver' begin select raise(abort,'synthetic disk failure'); end"));
            loop.release.complete();
            await until(
                t,
                () =>
                    run.persistencePending &&
                    find
                        .byKey(const ValueKey('ordinary_retry_save'))
                        .evaluate()
                        .isNotEmpty);
            expect(await rows(t, 'tb_messages', 301), hasLength(1));
            expect(await rows(t, 'tb_usage', 301), isEmpty);
            await t.runAsync(
                () => storage.db.execute('drop trigger page_reply_fail'));
            await t.tap(find.byKey(const ValueKey('ordinary_retry_save')));
            await until(t, () => run.ticket.released);
            expect(run.stage, ConversationGenerationStage.complete);
            expect(await rows(t, 'tb_messages', 301), hasLength(2));
            expect(await rows(t, 'tb_usage', 301), hasLength(1));
            await t.runAsync(run.retryPersistence);
            expect(loop.posts, hasLength(1));
          } else {
            await t.runAsync(() async {
              switch (control) {
                case 'login-ab':
                case 'login-aa':
                  action = LoginDao.saveAuthToken('synthetic-next',
                      userName: '合成下一身份',
                      extras: {
                        'accountHash': control == 'login-ab' ? 'b' : 'a'
                      });
                  break;
                case 'restore':
                case 'restore-rollback':
                  if (control.endsWith('rollback')) {
                    BackupService.debugImportFailureInjector = (point) async {
                      if (point ==
                          BackupImportFailurePoint.beforeResourceSwap) {
                        throw StateError('synthetic restore rollback');
                      }
                    };
                  }
                  action = LoginDao.runWithStableAccount(
                      expectedAccountHash: 'a',
                      action: () async {
                        await backup.importArchive(archive!, accountHash: 'a');
                      });
                  break;
                case 'profile':
                  if (backend) {
                    loop.catalogEnabled = false;
                    action = ModelCatalog.refreshFromBackend();
                    break;
                  }
                  final revoked = settings.settings.clone();
                  revoked.providers.first.enabled = false;
                  action = settings.update(revoked);
                  break;
                case 'source-delete':
                  action =
                      MessageDao.create(storage, cid: 301).then((dao) async {
                    await dao.deleteMessage(source);
                  });
                  break;
                case 'conversation-delete':
                  action = ConversationListDao.create(storage)
                      .then((dao) => dao.deleteConversation(models[301]!));
                  break;
                case 'stop':
                  // 调用实际输入控件的停止入口，不直接模拟Service停止。
                  input(t).onStop!();
                  action = run.finished;
                  break;
              }
              action!.then<void>((_) {
                actionDone = true;
              }, onError: (Object e) {
                actionError = e;
                actionDone = true;
              });
            });
            await until(
                t,
                () =>
                    actionDone &&
                    run.ticket.released &&
                    clientEnded.isNotEmpty);
            if (control.endsWith('rollback')) {
              expect(actionError, isA<StateError>());
            } else {
              expect(actionError, isNull);
            }
            expect(loop.release.isCompleted, false,
                reason: '真实HTTP仍被server挂起时身份/维护/撤权必须已结算');
            expect(run.executionStopped, true);
            expect(loop.posts, hasLength(1));
            final beforeLate = await t.runAsync(() => oldStorage.db
                .query('tb_messages', where: 'cid=?', whereArgs: [301]));
            final beforeUsage = await t.runAsync(() => oldStorage.db
                .query('tb_usage', where: 'cid=?', whereArgs: [301]));
            loop.release.complete();
            await until(t, () => loop.firstFinished);
            await io(t, 5);
            expect(
                await t.runAsync(() => oldStorage.db
                    .query('tb_messages', where: 'cid=?', whereArgs: [301])),
                beforeLate);
            expect(
                await t.runAsync(() => oldStorage.db
                    .query('tb_usage', where: 'cid=?', whereArgs: [301])),
                beforeUsage);
            expect(jsonEncode(beforeLate), isNot(contains('HELD_FINAL')));
            if (control == 'restore') {
              expect(beforeLate, isEmpty);
              expect(beforeUsage, isEmpty);
              expect(
                  await t.runAsync(
                      () => oldStorage.db.query('tb_conversation_generation')),
                  isEmpty);
            }
            if (control == 'restore-rollback') {
              expect(beforeLate, hasLength(1));
              expect(beforeUsage, isEmpty);
            }
            if (control == 'source-delete') {
              expect(beforeLate!.where((r) => r['id'] == source), isEmpty);
            }
            if (control == 'conversation-delete') {
              expect(beforeLate, isEmpty);
              expect(
                  await t.runAsync(() => storage.db.query(
                      'tb_conversation_list',
                      where: 'cid=?',
                      whereArgs: [301])),
                  isEmpty);
            }
          }
          transportEvidence.add({
            'case': 'L2B3-maintenance',
            'backend': backend,
            'control': control,
            'postsBeforeNext': loop.posts.length,
            'clientEndedWhileServerHeld':
                control != 'save-retry' && clientEnded.isNotEmpty,
            'clientErrors': clientErrors,
            'runId': run.runId,
            'stage': run.stage.name,
            'retired': run.retired,
            'oldTicketReleased': run.ticket.released,
            'oldRows': await t.runAsync(() => oldStorage.db
                .query('tb_messages', where: 'cid=?', whereArgs: [301])),
            'oldUsage': await t.runAsync(() => oldStorage.db
                .query('tb_usage', where: 'cid=?', whereArgs: [301]))
          });
          // 原票据撤销后明确打开新页并主动发送；同号源/账号不会被旧回调占用或补写。
          navigator.currentState!.pop();
          await io(t, 5);
          await t.runAsync(() async {
            BackupService.debugImportFailureInjector = null;
            if (control.startsWith('login')) {
              final account = LoginDao.getAccountHash()!;
              if (backend) {
                next.backendSelection = BackendSelection.pair(
                    providerCode: 'openai',
                    modelId: 'gpt-4o',
                    accountHash: account,
                    origin: BackendConfig.buildUri('/uapi/chat/completions')
                        .origin);
              }
              await HiCache.getInstance().setString(
                  AISettingsDao.keyFor(account), jsonEncode(next.toJson()));
              await settings.load();
              storage = await HiDBManager.instance(dbName: account);
            }
            if (control == 'profile') {
              if (backend) {
                loop.catalogEnabled = true;
                await ModelCatalog.refreshFromBackend();
              } else {
                await settings.update(next);
              }
            }
            final dao = await ConversationListDao.create(storage);
            final existing = await storage.db.query('tb_conversation_list',
                where: 'cid=?', whereArgs: [301]);
            if (existing.isEmpty) {
              models[301] = ConversationModel(
                  cid: 301,
                  title: '同号新会话',
                  icon: '',
                  speechInputEnabled: false);
              models[301]!.id = await dao.saveConversation(models[301]!);
            } else {
              models[301] = ConversationModel.fromJson(existing.single);
            }
          });
          await open(t, 301, fake: false);
          expect(loop.posts, hasLength(1), reason: '重接不自动发送');
          await send(t, 'EXPLICIT_NEW_TASK');
          await until(
              t,
              () =>
                  loop.posts.length == 2 &&
                  service
                          .lookup(LoginDao.getAccountHash()!, 301)
                          ?.ticket
                          .released ==
                      true);
          final fresh = service.lookup(LoginDao.getAccountHash()!, 301)!;
          expect(fresh.runId, isNot(run.runId));
          expect(fresh.acceptedSourceRow!['memorySourceId'],
              isNot(run.acceptedSourceRow!['memorySourceId']));
          if (control == 'login-ab') {
            expect(jsonEncode(loop.posts.last['messages']),
                isNot(contains('HELD_PAGE_TASK')));
            expect(jsonEncode(loop.posts.last['messages']),
                isNot(contains('PARTIAL_HELD')));
          }
          expect(fresh.stage, ConversationGenerationStage.complete);
          expect(fresh.dispatcher.mainText, 'NEW_FINAL');
          expect(
              await rows(t, 'tb_usage', 301),
              hasLength(control == 'save-retry' ||
                      control == 'stop' ||
                      control == 'profile'
                  ? 2
                  : 1));
          if (control == 'login-ab') {
            expect(
                await t.runAsync(() => oldStorage.db
                    .query('tb_usage', where: 'cid=?', whereArgs: [301])),
                isEmpty);
          }
          transportEvidence.add({
            'case': 'L2B3-maintenance-next',
            'backend': backend,
            'control': control,
            'posts': loop.posts,
            'account': LoginDao.getAccountHash(),
            'rows': await rows(t, 'tb_messages', 301),
            'usage': await rows(t, 'tb_usage', 301)
          });
        } finally {
          if (!loop.release.isCompleted) loop.release.complete();
          BackupService.debugImportFailureInjector = null;
          BackupService.debugGeneratedImageDirectoryResolver = null;
          BackupService.debugRoleCardAssetsDirectoryResolver = null;
          var settled = false;
          final retiring = Future.wait(service.runs
              .where((r) => !r.retired)
              .map((r) => r.retire('maintenance fixture cleanup')));
          retiring.then((_) => settled = true);
          await until(t, () => settled);
          await retiring;
          await t.runAsync(() => loop.server.close(force: true));
          HttpOverrides.global = previousOverrides;
          BackendConfig.host = oldHost;
          BackendConfig.useHttps = oldHttps;
        }
      });
    }
  }

  for (final backend in [false, true]) {
    for (final streaming in [false, true]) {
      pageTest(
          'real ${backend ? "backend" : "direct"} ${streaming ? "stream" : "nonstream"} A→B→A one POST/reply/usage per cid',
          (t) async {
        final oldOverrides = HttpOverrides.current;
        final previousHost = BackendConfig.host;
        final previousHttps = BackendConfig.useHttps;
        HttpOverrides.global = null;
        final server = (await t
            .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
        final payloads = <Map<String, dynamic>>[];
        final releaseA = Completer<void>();
        await t.runAsync(() async {
          server.listen((request) async {
            final body = jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
            payloads.add(body);
            final messages = (body['messages'] as List).cast<Map>();
            final task = messages
                .lastWhere((m) => m['role'] == 'user')['content']
                .toString();
            final a = task.contains('HTTP_A');
            final answer = a ? 'REAL_A' : 'REAL_B';
            if (streaming) {
              request.response.headers.contentType =
                  ContentType('text', 'event-stream');
              request.response.write('data: ${jsonEncode({
                    'choices': [
                      {
                        'index': 0,
                        'delta': {'content': 'PARTIAL_'}
                      }
                    ]
                  })}\n\n');
              await request.response.flush();
            }
            if (a) await releaseA.future;
            if (streaming) {
              request.response.write('data: ${jsonEncode({
                    'choices': [
                      {
                        'index': 0,
                        'delta': {'content': answer}
                      }
                    ]
                  })}\n\n');
              request.response.write('data: ${jsonEncode({
                    'choices': [],
                    'usage': {'prompt_tokens': 17, 'completion_tokens': 6}
                  })}\n\n');
              request.response.write('data: [DONE]\n\n');
            } else {
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode(backend
                  ? {
                      'code': 0,
                      'data': {
                        'content': answer,
                        'usage': {'prompt_tokens': 17, 'completion_tokens': 6}
                      }
                    }
                  : {
                      'choices': [
                        {
                          'message': {'content': answer}
                        }
                      ],
                      'usage': {'prompt_tokens': 17, 'completion_tokens': 6}
                    }));
            }
            await request.response.close();
          });
        });
        try {
          final ai = settings.settings.clone()..streamEnabled = streaming;
          if (backend) {
            BackendConfig.host = '127.0.0.1:${server.port}';
            BackendConfig.useHttps = false;
            ai.mode = AIMode.backend;
            ai.backendModel = 'gpt-4o';
            final identity = LoginSdkConfig.instance.storage as _Guest;
            identity.token = 'synthetic-page-access-token';
            identity.profile!['guest'] = false;
            ai.backendSelection = BackendSelection.pair(
                providerCode: 'openai',
                modelId: 'gpt-4o',
                accountHash: 'guest',
                origin:
                    BackendConfig.buildUri('/uapi/chat/completions').origin);
          } else {
            ai.providers.firstWhere((p) => p.id == 'fixture').apiHost =
                'http://127.0.0.1:${server.port}/v1';
          }
          await t.runAsync(() => settings.update(ai));
          await mount(t);
          await open(t, 301, fake: false);
          await send(t, 'HTTP_A');
          await until(t, () => payloads.length == 1);
          final a = service.lookup('guest', 301)!;
          final id = a.runId;
          navigator.currentState!.pop();
          await io(t, 4);
          expect(a.executionStopped, isFalse);
          await open(t, 302, fake: false);
          await send(t, 'HTTP_B');
          await until(
              t,
              () =>
                  payloads.length == 2 && !service.lookup('guest', 302)!.busy);
          navigator.currentState!.pop();
          await io(t, 4);
          await open(t, 301, fake: false);
          expect(service.lookup('guest', 301)!.runId, id);
          expect(payloads, hasLength(2));
          releaseA.complete();
          await until(t, () => !a.busy);
          final ar = await rows(t, 'tb_messages', 301),
              br = await rows(t, 'tb_messages', 302);
          expect(ar, hasLength(2));
          expect(br, hasLength(2));
          expect(ar.last['content'], streaming ? 'PARTIAL_REAL_A' : 'REAL_A');
          expect(br.last['content'], streaming ? 'PARTIAL_REAL_B' : 'REAL_B');
          expect(await rows(t, 'tb_usage', 301), hasLength(1));
          expect(await rows(t, 'tb_usage', 302), hasLength(1));
          expect(payloads, hasLength(2));
          transportEvidence.add({
            'backend': backend,
            'stream': streaming,
            'posts': payloads,
            'runId': id,
            'rowsA': ar.length,
            'rowsB': br.length,
            'usageA': 1,
            'usageB': 1
          });
        } finally {
          if (!releaseA.isCompleted) releaseA.complete();
          for (final r in service.runs) {
            await t.runAsync(() => r.retire('loopback cleanup'));
          }
          await t.runAsync(() => server.close(force: true));
          HttpOverrides.global = oldOverrides;
          BackendConfig.host = previousHost;
          BackendConfig.useHttps = previousHttps;
        }
      });
    }
  }
}

final class _Guest implements TokenStorage {
  String? token = 'guest-mode';
  Map<String, dynamic>? profile = {
    'userName': '游客',
    'accountHash': 'guest',
    'guest': true,
    'boardingPass': 'guest-mode',
    'avatar': ''
  };
  @override
  Future<void> clear() async {
    token = null;
    profile = null;
  }

  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() => profile;
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => token;
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    this.token = token;
    profile = {
      'userName': userName,
      'accountHash': userName.hashCode.toString(),
      'avatar': avatar ?? '',
      'boardingPass': token,
      ...extras
    };
  }
}

final class _Voice extends ReadAloudService {
  int calls = 0;
  @override
  Future<void> speak(ReadAloudRequest request) async {
    calls++;
  }
}

class _ManifestGate extends ConversationDraftStore {
  final release = Completer<void>();
  _ManifestGate(Directory root, String cid)
      : super(
            conversationId: cid,
            accountHash: 'guest',
            directoryResolver: () async => root);
  @override
  Future<DraftManifestToken?> captureManifest({void Function()? verify}) async {
    final token = await super.captureManifest(verify: verify);
    await release.future;
    return token;
  }
}

class _LoadGate extends ConversationDraftStore {
  final started = Completer<void>(), release = Completer<void>();
  _LoadGate(Directory root, String cid)
      : super(
            conversationId: cid,
            accountHash: 'guest',
            directoryResolver: () async => root);
  @override
  Future<ConversationDraft?> load() async {
    final draft = await super.load();
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return draft;
  }
}

class _ThinkingOnlyChat extends FakeComposerChat {
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await super.chatWithUsageWithOptions(
        prompt: prompt,
        history: history,
        attachments: attachments,
        options: options);
    yield StreamEvent.reasoning('心理状态：<<<走向门口>>>，决定等待。');
    yield StreamEvent.usage(promptTokens: 5, completionTokens: 3);
  }
}

/// 本地合成模型+MCP回环；不替换真实Direct/Backend/ToolLoopRunner或确认链。
class _PageToolLoop {
  final HttpServer server;
  final String toolName;
  final posts = <Map<String, dynamic>>[], toolCalls = <Map<String, dynamic>>[];
  final methods = <String>[];
  _PageToolLoop(this.server, this.toolName);
  static Future<_PageToolLoop> open(String name) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final value = _PageToolLoop(s, name);
    s.listen(value.handle);
    return value;
  }

  Future<void> handle(HttpRequest r) async {
    final path = r.uri.path;
    if (path == '/rpc' || path.startsWith('/uapi/mcp/')) {
      final body = r.method == 'GET'
          ? <String, dynamic>{}
          : (jsonDecode(await utf8.decoder.bind(r).join()) as Map)
              .cast<String, dynamic>();
      final method = path == '/rpc'
          ? body['method'] as String
          : path.endsWith('/tools')
              ? 'tools/list'
              : 'tools/call';
      methods.add(method);
      if (method == 'notifications/initialized') {
        r.response.statusCode = 202;
        await r.response.close();
        return;
      }
      if (method == 'tools/call') {
        toolCalls.add(path == '/rpc'
            ? (body['params'] as Map).cast<String, dynamic>()
            : body);
      }
      r.response.headers.contentType = ContentType.json;
      final tool = {
        'name': 'write',
        'description': '合成写入',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'content': {'type': 'string'}
          }
        }
      };
      r.response.write(jsonEncode(path == '/rpc'
          ? {
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': method == 'initialize'
                  ? {
                      'protocolVersion': '2024-11-05',
                      'capabilities': {'tools': {}},
                      'serverInfo': {'name': 'fixture', 'version': '1'}
                    }
                  : method == 'tools/list'
                      ? {
                          'tools': [tool]
                        }
                      : {
                          'content': [
                            {'type': 'text', 'text': 'TOOL_RESULT'}
                          ]
                        }
            }
          : {
              'code': 0,
              'data': method == 'tools/list'
                  ? {
                      'tools': [
                        {
                          'name': toolName,
                          'serverId': 's',
                          'parameters': tool['inputSchema']
                        }
                      ]
                    }
                  : {'content': 'TOOL_RESULT'}
            }));
    } else {
      final body = (jsonDecode(await utf8.decoder.bind(r).join()) as Map)
          .cast<String, dynamic>();
      posts.add(body);
      r.response.headers.contentType = ContentType('text', 'event-stream');
      r.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': posts.length == 1
                    ? {
                        'tool_calls': [
                          {
                            'index': 0,
                            'id': 'call_page',
                            'type': 'function',
                            'function': {
                              'name': toolName,
                              'arguments':
                                  jsonEncode({'content': 'TOOL_CONTENT'})
                            }
                          }
                        ]
                      }
                    : {'content': 'TOOL_FINAL'}
              }
            ]
          })}\n\n');
      r.response.write('data: ${jsonEncode({
            'choices': [],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 3}
          })}\n\n');
      r.response.write('data: [DONE]\n\n');
    }
    await r.response.close();
  }
}

/// 观察实际SDK流终止；不改变请求、取消、重试或错误语义。
class _PageObservedDirect extends DirectChatService {
  final List<bool> ended;
  final List<String> errors;
  _PageObservedDirect(AISettings ai, this.ended, this.errors)
      : super(ai.activeLocal,
            providerId: ai.activeProvider.id,
            providerCode: ChatService.providerCodeFor(ai),
            maxOutputTokens: ai.maxOutputTokens,
            deepSeekReasoningEffort: ai.deepSeekReasoningEffort,
            temperature: ai.temperature,
            topP: ai.topP);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    try {
      yield* super.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages,
          options: options);
    } catch (e) {
      errors.add(e.toString());
      rethrow;
    } finally {
      ended.add(true);
    }
  }
}

class _PageObservedBackend extends BackendChatService {
  final List<bool> ended;
  final List<String> errors;
  _PageObservedBackend(super.ai, this.ended, this.errors);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    try {
      yield* super.chatStreamEventsWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages,
          options: options);
    } catch (e) {
      errors.add(e.toString());
      rethrow;
    } finally {
      ended.add(true);
    }
  }
}

class _PageHeldModel {
  final HttpServer server;
  final release = Completer<void>();
  final posts = <Map<String, dynamic>>[];
  bool firstFinished = false, catalogEnabled = true;
  _PageHeldModel(this.server);
  static Future<_PageHeldModel> open() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final value = _PageHeldModel(s);
    s.listen(value.handle);
    return value;
  }

  Future<void> handle(HttpRequest r) async {
    if (r.uri.path == '/uapi/ai/catalog') {
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({
        'code': 0,
        'data': {
          'models': catalogEnabled
              ? [
                  {'modelId': 'gpt-4o', 'providerCode': 'openai'}
                ]
              : []
        }
      }));
      await r.response.close();
      return;
    }
    final body =
        jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
    posts.add(body);
    final first = posts.length == 1;
    try {
      r.response.bufferOutput = false;
      r.response.headers.contentType = ContentType('text', 'event-stream');
      if (first) {
        r.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': 'PARTIAL_HELD'}
                }
              ]
            })}\n\n'
            .replaceAll('\\n', '\n'));
        await r.response.flush();
        await release.future;
      }
      r.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': first ? 'HELD_FINAL' : 'NEW_FINAL'}
              }
            ]
          })}\n\n'
          .replaceAll('\\n', '\n'));
      r.response.write('data: ${jsonEncode({
            'choices': [],
            'usage': {'prompt_tokens': 11, 'completion_tokens': 4}
          })}\n\n'
          .replaceAll('\\n', '\n'));
      r.response.write('data: [DONE]\n\n'.replaceAll('\\n', '\n'));
      await r.response.close();
    } on SocketException {/* 已停止真实客户端。 */} on HttpException {
      /* 同上。 */
    } finally {
      if (first) firstFinished = true;
    }
  }
}
