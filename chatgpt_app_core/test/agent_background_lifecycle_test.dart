import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/conversation_page.dart';
import 'package:chatgpt_app_core/pages/agent_task_center_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/widget/message_input_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 使用真实 ConversationPage、SQLite 和本地 SSE，仅替换操作系统后台通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late _PageFixture fixture;

  setUp(() async {
    fixture = _PageFixture();
    await fixture.initialize();
  });

  tearDown(() async => fixture.dispose());

  testWidgets('普通旧对话发送不申请后台执行许可', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester, taskEnabled: false);
      final input = find.descendant(
          of: find.byType(MessageInputWidget),
          matching: find.byType(TextField));
      await tester.enterText(input, '普通对话不申请后台任务');
      tester
          .widget<MessageInputWidget>(find.byType(MessageInputWidget))
          .onSend!();
      await fixture.tick(tester, count: 20);
      await fixture.expectPartial(tester);
      expect(fixture.calls.where((call) => call.method == 'start'), isEmpty);
      fixture.stop(tester);
      await fixture.tick(tester);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('原生进度来自真实 todo 状态，不把工具轮数当作已完成比例', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester, withProgress: true);
      await fixture.expectPartial(tester);
      await fixture.tick(tester, count: 25);
      final updates = fixture.calls.where((call) => call.method == 'update');
      expect(updates, isNotEmpty);
      final latest = updates.last.arguments as Map;
      expect(latest['completed'], 1);
      expect(latest['total'], 3);
      expect(latest.toString(), isNot(contains('PRIVATE_TODO_BODY')),
          reason: '通知只显示计数与执行阶段，不上传任务正文');
      fixture.stop(tester);
      await fixture.tick(tester);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('后台许可有效时保留真实 SSE，完成落库后释放原生执行许可', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      expect(
          fixture.calls.where((call) => call.method == 'start'), hasLength(1));
      await fixture.expectPartial(tester);
      fixture.background(tester);
      await fixture.tick(tester);
      expect((await fixture.snapshot(tester))!['status'], 'running');
      expect(find.byType(AlertDialog), findsNothing);

      fixture.release.complete();
      await fixture.tick(tester, count: 30);
      expect((await fixture.snapshot(tester))!['status'], 'complete');
      final rows = await fixture.messages(tester);
      expect(
          rows.any((row) => (row['content'] as String? ?? '')
              .contains('BACKGROUND_FINISHED')),
          isTrue);
      expect(fixture.calls.where((call) => call.method == 'stop'), isNotEmpty);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  for (final failure in ['unsupported', 'permission', 'disabled']) {
    testWidgets('$failure 时后台安全暂停并保存部分回答', (tester) async {
      fixture.supported = failure != 'unsupported';
      fixture.startAllowed = failure != 'permission';
      await fixture.localNetwork(() async {
        await fixture.startHeldServer(tester);
        await fixture.open(tester, backgroundEnabled: failure != 'disabled');
        await fixture.expectPartial(tester);
        fixture.background(tester);
        await fixture.tick(tester);
        final snapshot = await fixture.snapshot(tester);
        expect(snapshot!['status'], 'paused');
        expect(snapshot['pauseReason'], contains('后台'));
        expect(
            (await fixture.messages(tester)).any((row) =>
                (row['content'] as String? ?? '')
                    .contains('BACKGROUND_PARTIAL')),
            isTrue);
        if (failure == 'disabled' || failure == 'unsupported') {
          expect(
              fixture.calls.where((call) => call.method == 'start'), isEmpty);
        }
        expect(tester.takeException(), isNull);
        await fixture.closePage(tester);
      });
    });
  }

  testWidgets('原生到期回调暂停当前任务，旧 runId 回调不影响当前 SSE', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      final start = fixture.calls.singleWhere((call) => call.method == 'start');
      final runId = (start.arguments as Map)['runId'];
      expect(runId, isA<String>());
      await fixture.interrupt(tester, 'old-run', 'expired');
      expect((await fixture.snapshot(tester))!['status'], 'running');
      fixture.background(tester);
      await fixture.tick(tester, count: 2);
      await fixture.interrupt(tester, runId as String, 'expired');
      expect((await fixture.snapshot(tester))!['status'], 'paused');
      expect(fixture.calls.where((call) => call.method == 'stop'), isNotEmpty);
      expect(
          (await fixture.messages(tester)).any((row) =>
              (row['content'] as String? ?? '').contains('BACKGROUND_PARTIAL')),
          isTrue);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('后台收到写工具时暂停，不显示不可见审批或写入文件', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester, writeAfterRelease: true);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      fixture.background(tester);
      await fixture.tick(tester, count: 3);
      expect((await fixture.snapshot(tester))!['status'], 'running');
      fixture.release.complete();
      await fixture.tick(tester, count: 30);
      expect((await fixture.snapshot(tester))!['status'], 'paused');
      expect(find.byType(AlertDialog), findsNothing);
      expect(await fixture.workspaceFiles(tester), isEmpty);
      expect(fixture.requestCount, 1, reason: '待审批必须立即暂停，不能继续模型调用或以拒绝当作完成');
      expect(fixture.calls.where((call) => call.method == 'stop'), isNotEmpty);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('待确认弹窗进入后台取消审批并释放许可，回前台不误写', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester, writeAfterRelease: true);
      await fixture.open(tester);
      fixture.release.complete();
      await fixture.tick(tester, count: 25);
      expect(find.byType(AlertDialog), findsOneWidget);
      fixture.background(tester);
      await fixture.tick(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect((await fixture.snapshot(tester))!['status'], 'paused');
      fixture.foreground(tester);
      await fixture.tick(tester);
      expect(await fixture.workspaceFiles(tester), isEmpty);
      expect(fixture.requestCount, 1);
      expect(fixture.calls.where((call) => call.method == 'stop'), isNotEmpty);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  for (final leavePage in [false]) {
    testWidgets(leavePage ? '离开对话保存断点并释放许可' : '用户停止保存断点并释放许可', (tester) async {
      await fixture.localNetwork(() async {
        await fixture.startHeldServer(tester);
        await fixture.open(tester);
        await fixture.expectPartial(tester);
        if (leavePage) {
          await fixture.closePage(tester);
        } else {
          fixture.stop(tester);
          await fixture.tick(tester);
        }
        expect((await fixture.snapshot(tester))!['status'], 'paused');
        expect(
            fixture.calls.where((call) => call.method == 'stop'), isNotEmpty);
        expect(tester.takeException(), isNull);
        await fixture.closePage(tester);
      });
    });
  }

  testWidgets('页面实际 dispose 后执行器仍收到完整 SSE 并独立落库', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      await fixture.closePage(tester);
      expect((await fixture.snapshot(tester))!['status'], 'running');
      expect(fixture.calls.where((call) => call.method == 'stop'), isEmpty);
      fixture.release.complete();
      await fixture.tick(tester, count: 30);
      expect((await fixture.snapshot(tester))!['status'], 'complete');
      final rows = await fixture.messages(tester);
      expect(
          rows
              .where((row) => row['ownerType'] == 'OwnerType.receiver')
              .single['content'],
          contains('BACKGROUND_FINISHED'));
      expect(fixture.requestCount, 1);
      expect(
          fixture.calls.where((call) => call.method == 'stop'), hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('不同会话串行排队，切换页面后按原 cid 保存两个完整结果', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      final firstKey = AgentTaskKey('guest', fixture.cid);
      fixture.cid = 874;
      await fixture.open(tester);
      expect(fixture.requestCount, 1, reason: '后一任务排队期间不得发送收费请求');
      expect(find.textContaining('等待执行'), findsWidgets);
      final secondKey = AgentTaskKey('guest', fixture.cid);
      expect(AgentTaskExecutor.instance.lookup(secondKey)!.queued, isTrue);
      fixture.release.complete();
      await fixture.tick(tester, count: 50);
      expect(fixture.requestCount, 2);
      expect(AgentTaskExecutor.instance.lookup(firstKey)!.phase,
          AgentRunPhase.complete);
      expect(AgentTaskExecutor.instance.lookup(secondKey)!.phase,
          AgentRunPhase.complete);
      final rows = (await tester.runAsync(() => fixture.storage.db.query(
          'tb_messages',
          where: 'ownerType = ?',
          whereArgs: ['OwnerType.receiver'])))!;
      expect(rows.map((row) => row['cid']).toSet(), {873, 874});
      expect(
          rows.every((row) =>
              (row['content'] as String).contains('BACKGROUND_FINISHED')),
          isTrue);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('取消排队不发送请求且保留用户原消息和可继续快照', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      fixture.cid = 875;
      await fixture.open(tester);
      await tester.tap(find.text('取消排队'));
      await fixture.tick(tester);
      expect((await fixture.snapshot(tester))!['status'], 'paused');
      expect(
          (await fixture.snapshot(tester))!['pauseReason'], contains('取消排队'));
      expect(
          (await fixture.messages(tester))
              .where((row) => row['ownerType'] == 'OwnerType.sender'),
          hasLength(1));
      fixture.release.complete();
      await fixture.tick(tester, count: 30);
      expect(fixture.requestCount, 1);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('首任务快照 RAISE ABORT 后释放许可，下一 FIFO 项仍可完成', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      fixture.cid = 876;
      await fixture.open(tester);
      await tester.runAsync(() => fixture.storage.db.execute(
          "create trigger fail_first_fifo_snapshot before insert on tb_agent_task_session "
          "when new.cid = 873 begin select raise(abort, 'TEST_STORAGE_FAILURE'); end"));
      try {
        fixture.release.complete();
        await fixture.tick(tester, count: 50);
        expect(fixture.requestCount, 2);
        expect(
            AgentTaskExecutor.instance
                .lookup(const AgentTaskKey('guest', 873))!
                .phase,
            AgentRunPhase.paused);
        expect(
            AgentTaskExecutor.instance
                .lookup(AgentTaskKey('guest', fixture.cid))!
                .phase,
            AgentRunPhase.complete);
        expect(fixture.calls.where((call) => call.method == 'start'),
            hasLength(2));
        expect(
            fixture.calls.where((call) => call.method == 'stop'), hasLength(2));
        expect((await fixture.snapshot(tester))!['status'], 'complete');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() => fixture.storage.db
            .execute('drop trigger fail_first_fifo_snapshot'));
      }
      await fixture.closePage(tester);
    });
  });

  testWidgets('任务中心显示执行中与排队，可取消排队后原任务继续完成', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      fixture.cid = 877;
      await fixture.open(tester);
      await fixture.closePage(tester);
      await tester.pumpWidget(const MaterialApp(home: AgentTaskCenterPage()));
      await fixture.tick(tester, count: 20);
      expect(find.text('执行中'), findsOneWidget);
      expect(find.text('排队中'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('stop_agent_task_${fixture.cid}')));
      await fixture.tick(tester);
      expect((await fixture.snapshot(tester))!['status'], 'paused');
      expect(fixture.requestCount, 1);
      fixture.release.complete();
      await fixture.tick(tester, count: 30);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('agent_task_873')),
              matching: find.text('已完成')),
          findsOneWidget);
      expect(find.text('待继续'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await fixture.closePage(tester);
    });
  });

  testWidgets('SQLite 快照写入失败仍释放后台许可和发送锁，保留旧持久化断点', (tester) async {
    await fixture.localNetwork(() async {
      await fixture.startHeldServer(tester);
      await fixture.open(tester);
      await fixture.expectPartial(tester);
      final durable = await fixture.snapshot(tester);
      await tester.runAsync(() => fixture.storage.db.execute(
          "create trigger fail_agent_background_snapshot before insert on "
          "tb_agent_task_session begin select raise(abort, 'TEST_STORAGE_FAILURE'); end"));
      try {
        fixture.stop(tester);
        await fixture.tick(tester, count: 30);
        expect(
            fixture.calls.where((call) => call.method == 'stop'), isNotEmpty);
        final input =
            tester.widget<MessageInputWidget>(find.byType(MessageInputWidget));
        expect(input.isStreaming, isFalse);
        expect(input.enable, isTrue);
        expect(await fixture.snapshot(tester), durable,
            reason: '失败的写入不能抹掉此前已有的任务快照');
        expect(find.textContaining('任务进度保存失败'), findsWidgets);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() => fixture.storage.db
            .execute('drop trigger if exists fail_agent_background_snapshot'));
      }
      await fixture.closePage(tester);
    });
  });
}

class _PageFixture {
  static const channel =
      MethodChannel('com.example.chatgpt_flutter/agent_background');
  static const paths = MethodChannel('plugins.flutter.io/path_provider');
  final calls = <MethodCall>[];
  final release = Completer<void>();
  late Directory temporary;
  late HiDBManager storage;
  late AISettingsProvider settings;
  late ThemeProvider theme;
  late PlatformAgentBackgroundExecution execution;
  late DatabaseFactory? previousFactory;
  HttpServer? server;
  bool supported = true;
  bool startAllowed = true;
  int requestCount = 0;
  int cid = 873;

  Future<void> initialize() async {
    temporary =
        await Directory.systemTemp.createTemp('agent-native-background-');
    previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath('${temporary.path}/database');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getCapabilities') {
        return {
          'supported': supported,
          'mode': 'androidForegroundService',
          'platform': 'android',
          'reason': supported ? null : 'unsupported'
        };
      }
      if (call.method == 'start') {
        return {
          'active': startAllowed,
          'reason': startAllowed ? null : 'notification_permission_denied'
        };
      }
      return true;
    });
    execution = PlatformAgentBackgroundExecution(
        channel: channel, operatingSystem: 'android');
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
    final ai = AISettings.defaults()..activeProviderId = 'deepseek';
    ai.setActiveModel('deepseek-flash');
    await HiCache.getInstance()
        .setString(AISettingsDao.keyFor('guest'), jsonEncode(ai.toJson()));
    settings = AISettingsProvider();
    theme = ThemeProvider();
    storage = await HiDBManager.instance(dbName: 'guest');
  }

  Future<void> dispose() async {
    if (!release.isCompleted) release.complete();
    await AgentTaskExecutor.instance.cancelAll('测试结束');
    await server?.close(force: true);
    foreground(TestWidgetsFlutterBinding.instance);
    await HiDBManager.closeAll();
    settings.dispose();
    theme.dispose();
    LoginSdkConfig.reset();
    AISettingsDao.resetSecureStateForTest();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(channel, null);
    databaseFactory = previousFactory;
    await temporary.delete(recursive: true);
  }

  Future<void> localNetwork(Future<void> Function() body) =>
      HttpOverrides.runZoned(body,
          createHttpClient: _LocalHttpOverrides().createHttpClient);

  Future<void> startHeldServer(WidgetTester tester,
      {bool writeAfterRelease = false}) async {
    server = await tester
        .runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server!.listen((request) async {
      try {
        await utf8.decoder.bind(request).join();
        requestCount++;
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.bufferOutput = false;
        request.response.write(
            'data: {"choices":[{"delta":{"content":"BACKGROUND_PARTIAL"}}]}\n\n');
        await request.response.flush();
        await release.future;
        if (writeAfterRelease) {
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
                              'content': 'BACKGROUND_MUST_NOT_WRITE'
                            })
                          }
                        }
                      ]
                    }
                  }
                ]
              })}\n\n');
        } else {
          request.response.write(
              'data: {"choices":[{"delta":{"content":" BACKGROUND_FINISHED"}}]}\n\n');
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      } on SocketException {
        // 许可失效、用户停止或离开对话均会关闭真实 SSE。
      } on HttpException {
        // 取消连接后不能再次提交响应头。
      }
    });
    await tester.runAsync(() async {
      final ai = settings.settings.clone()..mode = AIMode.local;
      ai.activeProvider.apiKey = 'local-test-only';
      ai.activeProvider.apiHost =
          'http://${server!.address.host}:${server!.port}/v1';
      await settings.update(ai);
    });
  }

  Future<void> tick(WidgetTester tester, {int count = 12}) async {
    for (var index = 0; index < count; index++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> open(WidgetTester tester,
      {bool backgroundEnabled = true,
      bool taskEnabled = true,
      bool withProgress = false}) async {
    foreground(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tick(tester, count: 2);
    final model = ConversationModel(
        cid: cid, icon: '', title: '后台任务验收', speechInputEnabled: false);
    await tester.runAsync(() async {
      await (await ConversationListDao.create(storage)).saveConversation(model);
      await (await MessageDao.create(storage, cid: cid))
          .saveMessageWithBlocks(MessageModel(
        ownerType: OwnerType.sender,
        ownerName: '游客',
        avatar: '',
        content: '后台读取并完成任务',
        createdAt: 101,
      ));
      if (taskEnabled) {
        final store = await AgentTaskDao.create(storage);
        final task = AgentTaskSession(cid: cid, store: store);
        await task.setEnabled(true);
        await task.begin(userAt: 101, input: '后台读取并完成任务');
        if (withProgress) {
          await task.todoTool.execute({
            'todos': [
              {'content': 'PRIVATE_TODO_BODY 已读取', 'status': 'completed'},
              {'content': 'PRIVATE_TODO_BODY 核对中', 'status': 'in_progress'},
              {'content': 'PRIVATE_TODO_BODY 待导出', 'status': 'pending'},
            ]
          });
        }
        await task.pause('上次中断');
        await store.write(
            cid, task.toJson()..['backgroundEnabled'] = backgroundEnabled);
        task.dispose();
      }
    });
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AISettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ],
        child: MaterialApp(
            home: ConversationPage(
          conversationModel: model,
          readAloudService: const NoopReadAloudService(),
          resumeAgentTask: taskEnabled,
          initialTargetCreatedAt: taskEnabled ? 101 : null,
          backgroundExecution: execution,
        ))));
    await tick(tester, count: 25);
    expect(tester.takeException(), isNull);
  }

  Future<void> expectPartial(WidgetTester tester) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      if (find
          .textContaining('BACKGROUND_PARTIAL', findRichText: true)
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tick(tester, count: 1);
    }
    expect(find.textContaining('BACKGROUND_PARTIAL', findRichText: true),
        findsWidgets);
    expect(requestCount, 1);
  }

  void background(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }

  void foreground(Object target) {
    final binding = target is WidgetTester
        ? target.binding
        : target as TestWidgetsFlutterBinding;
    if (binding.lifecycleState == AppLifecycleState.paused) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    }
    if (binding.lifecycleState == AppLifecycleState.hidden) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    }
    if (binding.lifecycleState != AppLifecycleState.resumed) {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  }

  Future<Map<String, dynamic>?> snapshot(WidgetTester tester) =>
      tester.runAsync<Map<String, dynamic>?>(
          () async => (await AgentTaskDao.create(storage)).read(cid));

  Future<List<Map<String, Object?>>> messages(WidgetTester tester) async =>
      (await tester.runAsync(() => storage.db
          .query('tb_messages', where: 'cid = ?', whereArgs: [cid])))!;

  Future<List<Map<String, Object?>>> workspaceFiles(
          WidgetTester tester) async =>
      (await tester.runAsync(() => storage.db.query('tb_agent_workspace_files',
          where: 'cid = ?', whereArgs: [cid])))!;

  Future<void> interrupt(
      WidgetTester tester, String runId, String reason) async {
    final done = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
            MethodCall('onInterrupted', {'runId': runId, 'reason': reason})),
        (_) => done.complete());
    // 原生 ACK 等待 Page 落库；widget test 中必须继续推进 SQLite 及 fake clock。
    for (var attempt = 0; attempt < 120 && !done.isCompleted; attempt++) {
      await tick(tester, count: 1);
    }
    expect(done.isCompleted, isTrue, reason: '中断 ACK 必须在有界时间内返回');
    await done.future;
    await tick(tester);
  }

  void stop(WidgetTester tester) {
    tester
        .widget<MessageInputWidget>(find.byType(MessageInputWidget))
        .onStop!();
  }

  Future<void> closePage(WidgetTester tester) async {
    foreground(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tick(tester);
  }
}

final class _GuestStorage implements TokenStorage {
  static const profile = <String, dynamic>{
    'userName': '游客',
    'accountHash': 'guest',
    'guest': true,
    'boardingPass': 'guest-mode',
    'avatar': ''
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
  String? readTokenSync() => 'guest-mode';
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}

final class _LocalHttpOverrides extends HttpOverrides {}
