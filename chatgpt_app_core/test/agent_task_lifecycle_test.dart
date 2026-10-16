import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('任务生命周期快照', () {
    late Directory directory;
    late Database db;
    late AgentTaskDao store;
    late AgentTaskSession task;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('agent-lifecycle-');
      db = await databaseFactoryFfi.openDatabase('${directory.path}/task.db');
      store = await AgentTaskDao.create(HiDBManager.test(db));
      task = AgentTaskSession(cid: 7, store: store);
      await task.setEnabled(true);
      await task.begin(userAt: 101, input: '读取资料并生成报告');
    });

    tearDown(() async {
      task.dispose();
      await db.close();
      await directory.delete(recursive: true);
    });

    test('暂停后 SQLite 重开保留已执行结果、执行中的工具和暂停原因', () async {
      final protocol = _partiallyExecutedProtocol();
      await task.checkpoint(protocol, 2, executing: 'pending-write');
      await task.pause('应用进入后台', expectedGeneration: task.generation);
      await task.finish(complete: false);
      await db.close();
      db = await databaseFactoryFfi.openDatabase('${directory.path}/task.db');
      store = await AgentTaskDao.create(HiDBManager.test(db));
      final reopened = AgentTaskSession(cid: 7, store: store);
      addTearDown(reopened.dispose);
      await reopened.load();

      expect(reopened.status, 'paused');
      expect(reopened.pauseReason, '应用进入后台');
      expect(reopened.canResume, isTrue);
      expect(reopened.messages, protocol);
      expect(reopened.executingToolId, 'pending-write');
      expect(reopened.nextRound, 2);
      expect(reopened.userCreatedAt, 101);
    });

    test('迟到的工具 checkpoint 保存结果但不能把暂停状态变回运行', () async {
      final generation = task.generation;
      await task.checkpoint(_partiallyExecutedProtocol(), 2,
          executing: 'pending-write');
      await task.pause('已离开对话', expectedGeneration: generation);
      final finishedProtocol = [
        ..._partiallyExecutedProtocol(),
        {
          'role': 'tool',
          'tool_call_id': 'pending-write',
          'content': '已完成且无需重做',
        },
      ];
      await task.checkpoint(finishedProtocol, 2,
          expectedGeneration: generation);
      await task.finish(complete: false);

      expect(task.status, 'paused');
      expect(task.pauseReason, '已离开对话');
      expect(task.messages.last['content'], '已完成且无需重做');
      expect(task.executingToolId, isNull);
      final saved = await store.read(7);
      expect(saved!['status'], 'paused');
      expect(saved['messages'], finishedProtocol);
    });

    test('显式继续保留工具协议并清空原因，新任务清空旧协议', () async {
      await task.checkpoint(_partiallyExecutedProtocol(), 2,
          executing: 'pending-write');
      await task.pause('应用进入后台');
      await task.begin(userAt: 101, input: '读取资料并生成报告', resume: true);
      expect(task.status, 'running');
      expect(task.pauseReason, isNull);
      expect(task.messages, _partiallyExecutedProtocol());
      expect(task.executingToolId, 'pending-write');

      await task.pause('已离开对话');
      await task.begin(userAt: 202, input: '下一项工作');
      expect(task.pauseReason, isNull);
      expect(task.messages, isEmpty);
      expect(task.nextRound, 0);
      expect(task.executingToolId, isNull);
      expect((await store.read(7))!['pauseReason'], isNull);
    });

    test('旧 generation 的迟到暂停和 checkpoint 不影响新任务', () async {
      final previous = task.generation;
      await task.begin(userAt: 202, input: '下一项工作');
      final before = jsonEncode(task.toJson());
      await task.pause('旧任务进入后台', expectedGeneration: previous);
      await task.checkpoint(_partiallyExecutedProtocol(), 2,
          executing: 'pending-write', expectedGeneration: previous);
      expect(jsonEncode(task.toJson()), before);
      expect(task.status, 'running');
      expect(task.userCreatedAt, 202);
      expect(task.pauseReason, isNull);
    });

    test('running 写入被阻塞时，后来的暂停按队列落库而不被旧状态覆盖', () async {
      final heldStore = _HeldTaskStore();
      final queued = AgentTaskSession(cid: 88, store: heldStore);
      addTearDown(queued.dispose);
      await queued.setEnabled(true);
      heldStore.blockNextWrite = true;
      final begin = queued.begin(userAt: 101, input: '串行保存任务');
      await heldStore.writeStarted.future;
      final pause = queued.pause('应用进入后台');
      await Future<void>.delayed(Duration.zero);
      expect(heldStore.startedStatuses, ['idle', 'running']);
      expect(heldStore.snapshot!['status'], 'idle');
      heldStore.releaseWrite.complete();
      await Future.wait([begin, pause]);
      expect(heldStore.startedStatuses, ['idle', 'running', 'paused']);
      expect(heldStore.snapshot!['status'], 'paused');
      expect(heldStore.snapshot!['pauseReason'], '应用进入后台');
    });

    test('完成任务清空暂停原因并禁止继续', () async {
      await task.pause('应用进入后台');
      await task.finish(complete: true);
      expect(task.status, 'complete');
      expect(task.pauseReason, isNull);
      expect(task.canResume, isFalse);
      expect((await store.read(7))!['pauseReason'], isNull);
    });

    test('旧 running 快照重开安全暂停，旧无原因字段兼容', () async {
      await task.checkpoint(_partiallyExecutedProtocol(), 1,
          executing: 'pending-write');
      final legacy = Map<String, dynamic>.of(task.toJson())
        ..remove('pauseReason');
      await store.write(7, legacy);
      final reopened = AgentTaskSession(cid: 7, store: store);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.status, 'paused');
      expect(reopened.canResume, isTrue);
      expect(reopened.messages, _partiallyExecutedProtocol());
      expect(reopened.executingToolId, 'pending-write');
    });

    test('损坏 JSON 和非对象快照不阻止旧对话打开', () async {
      for (final value in ['{broken', '[]', 'null', '"string"']) {
        await db.insert(
          store.tableName,
          {'cid': 99, 'snapshot': value, 'updatedAt': 1},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        expect(await store.read(99), isNull, reason: value);
        final legacyConversation = AgentTaskSession(cid: 99, store: store);
        await legacyConversation.load();
        expect(legacyConversation.enabled, isFalse);
        expect(legacyConversation.status, 'idle');
        expect(legacyConversation.canResume, isFalse);
        legacyConversation.dispose();
      }
      expect((await store.read(7))!['prompt'], '读取资料并生成报告');
    });

    test('合法 JSON 中错误字段类型安全降级，不恢复不完整工具协议', () async {
      await store.write(98, {
        'enabled': true,
        'status': 'running',
        'prompt': '不完整记录',
        'userCreatedAt': '101',
        'messages': _partiallyExecutedProtocol(),
      });
      final broken = AgentTaskSession(cid: 98, store: store);
      addTearDown(broken.dispose);
      await broken.load();
      expect(broken.status, 'idle');
      expect(broken.canResume, isFalse);
      expect(broken.messages, isEmpty);
      expect(broken.pauseReason, contains('不完整'));
    });
  });

  group('真实对话页恢复入口', () {
    late Directory temporary;
    late HiDBManager storage;
    late AISettingsProvider settings;
    late ThemeProvider theme;
    late DatabaseFactory? previousFactory;
    late String previousHost;
    late bool previousHttps;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      previousHost = BackendConfig.host;
      previousHttps = BackendConfig.useHttps;
      // 隔离每个 widget 用例的 FakeAsync 账号队尾，不重用已结束 zone。
      LoginDao.resetHooksForTest();
      temporary =
          await Directory.systemTemp.createTemp('agent-page-lifecycle-');
      previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.setDatabasesPath('${temporary.path}/database');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (_) async => temporary.path);
      SharedPreferences.setMockInitialValues({});
      await HiCache.preInit();
      await HiCache.getInstance().prefs?.clear();
      AISettingsDao.resetSecureStateForTest();
      LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => const {},
        syncHeaders: () => const {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: _GuestStorage(),
        onLogoutNavigate: () {},
      ));
      // 生命周期用已认证后端任务验证断点重放；直连恢复需要另行确认新请求。
      final ai = AISettings.defaults()
        ..activeProviderId = 'deepseek'
        ..mode = AIMode.backend
        ..backendSelection = BackendSelection.pair(
            providerCode: 'deepseek',
            modelId: 'deepseek-flash',
            accountHash: 'guest',
            origin: BackendConfig.buildUri('/uapi/chat/completions').origin);
      ai.setActiveModel('deepseek-flash');
      await HiCache.getInstance()
          .setString(AISettingsDao.keyFor('guest'), jsonEncode(ai.toJson()));
      settings = AISettingsProvider();
      theme = ThemeProvider();
      storage = await HiDBManager.instance(dbName: 'guest');
    });

    tearDown(() async {
      try {
        await AgentTaskExecutor.instance
            .cancelAll('测试结束')
            .timeout(const Duration(seconds: 5));
      } finally {
        await HiDBManager.closeAll();
        settings.dispose();
        theme.dispose();
        BackendConfig.host = previousHost;
        BackendConfig.useHttps = previousHttps;
        LoginSdkConfig.reset();
        AISettingsDao.resetSecureStateForTest();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathChannel, null);
        databaseFactory = previousFactory;
        await temporary.delete(recursive: true);
      }
    });

    Future<void> tick(WidgetTester tester, {int count = 12}) async {
      for (var index = 0; index < count; index++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    Future<void> finishFuture(WidgetTester tester, Future<void> future) async {
      var finished = false;
      Object? failure;
      future.then((_) {
        finished = true;
      }, onError: (Object error) {
        failure = error;
        finished = true;
      });
      for (var attempt = 0; attempt < 400 && !finished; attempt++) {
        await tick(tester, count: 1);
      }
      expect(finished, isTrue, reason: '任务结算必须同时推进真实 I/O 和页面时钟');
      if (failure != null) throw failure!;
      await tester.pump();
      await tester.pump();
    }

    Future<void> finishTask(WidgetTester tester, int cid,
        {AgentTaskRun? previous}) async {
      AgentTaskRun? run;
      for (var attempt = 0; attempt < 400; attempt++) {
        run = AgentTaskExecutor.instance.lookup(AgentTaskKey('guest', cid));
        if (run != null && !identical(run, previous)) break;
        await tick(tester, count: 1);
      }
      expect(run, isNotNull, reason: '显式恢复必须创建本次任务');
      expect(run, isNot(same(previous)), reason: '不能把上次暂停任务视为恢复完成');
      await finishFuture(tester, run!.finished);
    }

    void pageTest(String name, Future<void> Function(WidgetTester) body) {
      testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          // 失败时也在当前 FakeAsync 仍可推进时结算，不能留到 tearDown 再等。
          await tester
              .runAsync(() => tester.pumpWidget(const SizedBox.shrink()));
          await finishFuture(
              tester, AgentTaskExecutor.instance.cancelAll('测试结束'));
          await finishFuture(
              tester,
              ConversationDraftStore(
                  conversationId: '0',
                  accountHash: 'guest',
                  directoryResolver: () async => temporary).whenIdle());
        }
      });
    }

    Future<void> open(WidgetTester tester, ConversationModel model,
        {bool resume = false, int target = 101}) async {
      // 初始化/自动恢复使用真实 SQLite、HTTP。让其异步链留在真实 I/O zone，
      // 避免 testWidgets 结束后全局执行器还引用已停止推进的 FakeAsync 队列。
      await tester.runAsync(() async => tester.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
              ChangeNotifierProvider<ThemeProvider>.value(value: theme),
            ],
            child: MaterialApp(
              home: ConversationPage(
                key: ValueKey('task_${model.cid}_$resume'),
                conversationModel: model,
                readAloudService: const NoopReadAloudService(),
                resumeAgentTask: resume,
                initialTargetCreatedAt: resume ? target : null,
              ),
            ),
          )));
      for (var attempt = 0; attempt < 400; attempt++) {
        await tick(tester, count: 1);
        final input =
            tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
        if (input.enable || input.isStreaming) break;
      }
      final input =
          tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
      expect(input.enable || input.isStreaming, isTrue,
          reason: '等待初始化完成或显式恢复已开始');
      expect(tester.takeException(), isNull);
    }

    Future<ConversationModel> seedPausedTask(
        {required int cid,
        required List<Map<String, dynamic>> protocol}) async {
      final model = ConversationModel(
          cid: cid, icon: '', title: '任务恢复验收', speechInputEnabled: false);
      await (await ConversationListDao.create(storage)).saveConversation(model);
      await (await MessageDao.create(storage, cid: cid))
          .saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender,
        ownerName: '游客',
        avatar: '',
        content: '读取资料并生成报告',
        createdAt: 101,
      ));
      final session =
          AgentTaskSession(cid: cid, store: await AgentTaskDao.create(storage));
      await session.setEnabled(true);
      await session.begin(
          userAt: 101,
          input: '读取资料并生成报告',
          backendSelection: settings.settings.backendSelection);
      await session.checkpoint(protocol, 1);
      await session.pause('应用进入后台');
      session.dispose();
      return model;
    }

    Future<void> localNetwork(Future<void> Function() body) =>
        HttpOverrides.runZoned(body,
            createHttpClient: _LocalHttpOverrides().createHttpClient);

    Future<void> configureLocalServer(HttpServer server) async {
      BackendConfig.host = '${server.address.host}:${server.port}';
      BackendConfig.useHttps = false;
      final ai = settings.settings.clone()..mode = AIMode.backend;
      ai.backendSelection = BackendSelection.pair(
          providerCode: 'deepseek',
          modelId: 'deepseek-flash',
          accountHash: 'guest',
          origin: BackendConfig.buildUri('/uapi/chat/completions').origin);
      await settings.update(ai);
    }

    for (final leaveConversation in [false]) {
      pageTest(
          leaveConversation
              ? '真实 SSE 离开对话保存部分回复，普通重开不请求，显式恢复继续'
              : '真实 SSE 在后台暂停保存部分回复，普通重开不请求，显式恢复继续', (tester) async {
        await localNetwork(() async {
          final server = await tester
              .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0));
          addTearDown(() => server!.close(force: true));
          final requests = <Map<String, dynamic>>[];
          final releaseFirstResponse = Completer<void>();
          addTearDown(() {
            if (!releaseFirstResponse.isCompleted) {
              releaseFirstResponse.complete();
            }
          });
          server!.listen((request) async {
            try {
              requests.add(jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>);
              request.response.headers.contentType =
                  ContentType('text', 'event-stream', charset: 'utf-8');
              request.response.bufferOutput = false;
              if (requests.length == 1) {
                request.response.write(
                    'data: {"choices":[{"delta":{"content":"PARTIAL_BEFORE_BACKGROUND"}}]}\n\n');
                await request.response.flush();
                await releaseFirstResponse.future;
              } else {
                request.response.write(
                    'data: {"choices":[{"delta":{"content":"RESUMED_FINAL"}}]}\n\n'
                    'data: [DONE]\n\n');
              }
              await request.response.close();
            } on SocketException {
              // 后台主动关闭 SSE 连接是本测试要验证的行为。
            } on HttpException {
              // 已关闭的首个 SSE 连接不能继续输出。
            }
          });
          await tester.runAsync(() => configureLocalServer(server));
          final model = await tester
              .runAsync(() => seedPausedTask(cid: 73, protocol: const []));
          await open(tester, model!, resume: true);
          // 真实 SQLite 初始化和独立执行器提交不能由固定帧数代表完成。
          // 综合运行有 IO 争抢时，等待实际 HTTP 到达，再严格检查只发一次。
          for (var attempt = 0; attempt < 320 && requests.isEmpty; attempt++) {
            await tick(tester, count: 1);
          }
          expect(requests, hasLength(1));
          for (var attempt = 0; attempt < 400; attempt++) {
            if (find
                .textContaining('PARTIAL', findRichText: true)
                .evaluate()
                .isNotEmpty) {
              break;
            }
            await tick(tester, count: 1);
          }
          expect(
              find.textContaining('PARTIAL', findRichText: true), findsWidgets,
              reason: '必须先收到正文增量，才能验证后台保留部分回复');
          var snapshot = await tester.runAsync(
              () async => (await AgentTaskDao.create(storage)).read(73));
          expect(snapshot!['status'], 'running');

          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tick(tester, count: 3);
          snapshot = await tester.runAsync(
              () async => (await AgentTaskDao.create(storage)).read(73));
          expect(snapshot!['status'], 'running',
              reason: '系统弹窗和文件选择器只会短暂 inactive，不应中止任务');

          if (leaveConversation) {
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
            await tester.pumpWidget(const SizedBox.shrink());
          } else {
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.hidden);
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.paused);
          }
          await tick(tester);
          await finishFuture(
              tester,
              AgentTaskExecutor.instance
                  .lookup(const AgentTaskKey('guest', 73))!
                  .finished);
          snapshot = await tester.runAsync(
              () async => (await AgentTaskDao.create(storage)).read(73));
          expect(snapshot!['status'], 'paused');
          expect(snapshot['pauseReason'],
              contains(leaveConversation ? '离开对话' : '后台'));
          final partial = await tester.runAsync(() => storage.db
              .query('tb_messages', where: 'cid = ?', whereArgs: [73]));
          expect(
              partial!.any((row) => (row['content'] as String? ?? '')
                  .contains('PARTIAL_BEFORE_BACKGROUND')),
              isTrue);
          releaseFirstResponse.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          if (!leaveConversation) {
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.hidden);
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
            tester.binding
                .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          }
          await tick(tester);

          await open(tester, model);
          expect(requests, hasLength(1), reason: '查看任务不能自动再次计费');
          await tester.pumpWidget(const SizedBox.shrink());
          await tick(tester);
          final previous = AgentTaskExecutor.instance
              .lookup(const AgentTaskKey('guest', 73));
          await open(tester, model, resume: true);
          await finishTask(tester, 73, previous: previous);
          expect(requests, hasLength(2));
          snapshot = await tester.runAsync(
              () async => (await AgentTaskDao.create(storage)).read(73));
          expect(snapshot!['status'], 'complete');
          expect(snapshot['pauseReason'], isNull);
          final restored = await tester.runAsync(() => storage.db
              .query('tb_messages', where: 'cid = ?', whereArgs: [73]));
          expect(restored!.where((row) => row['content'] == 'RESUMED_FINAL'),
              hasLength(1));
          expect(restored.where((row) => row['content'] == '读取资料并生成报告'),
              hasLength(1),
              reason: '恢复不能重复插入原提问');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tick(tester);
        });
      });
    }

    pageTest('后台移除待确认写入弹窗，回到前台不能误写成果', (tester) async {
      await localNetwork(() async {
        final server = await tester
            .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0));
        addTearDown(() => server!.close(force: true));
        var requests = 0;
        server!.listen((request) async {
          await utf8.decoder.bind(request).join();
          requests++;
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          request.response.write('data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'background-write',
                          'type': 'function',
                          'function': {
                            'name': 'write_file',
                            'arguments': jsonEncode({
                              'name': 'blocked.txt',
                              'content': 'BLOCKED_ON_BACKGROUND',
                            }),
                          }
                        }
                      ]
                    }
                  }
                ]
              })}\n\ndata: [DONE]\n\n');
          await request.response.close();
        });
        await tester.runAsync(() => configureLocalServer(server));
        final model = await tester
            .runAsync(() => seedPausedTask(cid: 74, protocol: const []));
        await open(tester, model!, resume: true);
        for (var attempt = 0;
            attempt < 400 && find.byType(AlertDialog).evaluate().isEmpty;
            attempt++) {
          await tick(tester, count: 1);
        }
        expect(find.byType(AlertDialog), findsOneWidget);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tick(tester, count: 3);
        expect(find.byType(AlertDialog), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tick(tester);
        await finishFuture(
            tester,
            AgentTaskExecutor.instance
                .lookup(const AgentTaskKey('guest', 74))!
                .finished);
        expect(find.byType(AlertDialog), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tick(tester);
        expect(
            await tester.runAsync(() => storage.db.query(
                'tb_agent_workspace_files',
                where: 'cid = ?',
                whereArgs: [74])),
            isEmpty);
        final snapshot = await tester.runAsync(
            () async => (await AgentTaskDao.create(storage)).read(74));
        expect(snapshot!['status'], 'paused');
        expect(requests, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tick(tester);
      });
    });

    pageTest('普通重开和过期定位不执行；显式恢复可重放已完成回答且无需网络', (tester) async {
      final model = await tester.runAsync(() => seedPausedTask(
            cid: 71,
            protocol: [
              {
                'role': 'assistant',
                'content': '恢复验收已完成',
                'reasoning_content': '已核对保存的工具结果',
              }
            ],
          ));
      await open(tester, model!);
      var snapshot = await tester.runAsync(
          () async => (await AgentTaskDao.create(storage)).read(model.cid));
      expect(snapshot!['status'], 'paused');
      expect(snapshot['pauseReason'], '应用进入后台');
      expect(find.text('恢复验收已完成'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tick(tester);

      await open(tester, model, resume: true, target: 999);
      snapshot = await tester.runAsync(
          () async => (await AgentTaskDao.create(storage)).read(model.cid));
      expect(snapshot!['status'], 'paused', reason: '旧任务中心入口不能恢复已变更的任务');
      expect(find.text('恢复验收已完成'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tick(tester);

      await open(tester, model, resume: true);
      await finishTask(tester, model.cid);
      snapshot = await tester.runAsync(
          () async => (await AgentTaskDao.create(storage)).read(model.cid));
      expect(snapshot!['status'], 'complete');
      expect(snapshot['pauseReason'], isNull);
      final messages = await tester.runAsync(() =>
          storage.db.query('tb_messages', where: 'cid = ?', whereArgs: [71]));
      expect(
          messages!.where((row) => row['content'] == '恢复验收已完成'), hasLength(1));
      expect(
          messages.where((row) => row['content'] == '读取资料并生成报告'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tick(tester);
    });

    pageTest('没有任务的旧对话，即使请求恢复也不新增消息或启动请求', (tester) async {
      final model = ConversationModel(
          cid: 72, icon: '', title: '旧对话', speechInputEnabled: false);
      await tester.runAsync(() async {
        await (await ConversationListDao.create(storage))
            .saveConversation(model);
        await (await MessageDao.create(storage, cid: 72))
            .saveMessageWithBlocks(MessageModel(
          ownerType: OwnerType.sender,
          ownerName: '旧用户',
          avatar: '',
          content: '旧问题',
          createdAt: 100,
        ));
      });
      final before = await tester.runAsync(() => storage.db.query('tb_messages',
          where: 'cid = ?', whereArgs: [72], orderBy: 'id'));
      await open(tester, model, resume: true);
      expect(
          await tester.runAsync(() => storage.db.query('tb_messages',
              where: 'cid = ?', whereArgs: [72], orderBy: 'id')),
          before);
      expect(
          tester
              .widget<MessageInputWidget>(find.byType(MessageInputWidget))
              .enable,
          isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tick(tester);
    });
  });
}

List<Map<String, dynamic>> _partiallyExecutedProtocol() => [
      {
        'role': 'assistant',
        'content': '',
        'reasoning_content': '读取后生成报告',
        'tool_calls': [
          {
            'id': 'read-complete',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{"file_id":1}'}
          },
          {
            'id': 'pending-write',
            'type': 'function',
            'function': {
              'name': 'write_file',
              'arguments': '{"name":"report.txt","content":"资料比较"}'
            }
          },
        ],
      },
      {
        'role': 'tool',
        'tool_call_id': 'read-complete',
        'content': '完整资料，已执行的读取结果',
      },
    ];

final class _GuestStorage implements TokenStorage {
  static const profile = <String, dynamic>{
    'userName': '游客',
    'accountHash': 'guest',
    'guest': false,
    'boardingPass': 'synthetic-lifecycle-access-token',
    'avatar': '',
  };
  @override
  Future<void> clear() async {}
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  Map<String, dynamic>? readProfileSync() => Map.of(profile);
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  String? readTokenSync() => 'synthetic-lifecycle-access-token';
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}

final class _HeldTaskStore implements IAgentTaskStore {
  Map<String, dynamic>? snapshot;
  bool blockNextWrite = false;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  final startedStatuses = <String>[];

  @override
  Future<Map<String, dynamic>?> read(int cid) async => snapshot;

  @override
  Future<void> write(int cid, Map<String, dynamic> value) async {
    startedStatuses.add(value['status'] as String);
    if (blockNextWrite) {
      blockNextWrite = false;
      writeStarted.complete();
      await releaseWrite.future;
    }
    snapshot = (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();
  }
}

final class _LocalHttpOverrides extends HttpOverrides {}
