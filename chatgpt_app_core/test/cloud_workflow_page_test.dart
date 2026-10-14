import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/pages/agent_task_center_page.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_center_service.dart';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_api.dart';
import 'package:chatgpt_app_core/chat/application/cloud_workflow_client.dart';
import 'package:chatgpt_app_core/chat/domain/cloud_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/cloud_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/cloud_workflow_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/cloud_workflow_fixture.dart';
import 'support/personal_memory_test_support.dart';

Future<void> until(WidgetTester t, FutureOr<bool> Function() done) async {
  for (var i = 0; i < 160; i++) {
    await t.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 20));
    if (await t.runAsync(() async => done()) == true) return;
  }
  fail('页面未在有界等待中完成');
}

class _NoRealNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('云页面fixture禁止真实网络');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = _NoRealNetwork();
  final evidence = <Map<String, Object?>>[];
  final previousNetwork = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = network);
  tearDownAll(() async {
    try {
      expect(network.attempts, 0);
      await File('/tmp/chatai-cloud-C2-page-receipt-fix-payload.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'realNetworkAttempts': network.attempts,
        'classification':
            'actual CloudWorkflowPage + MockClient HTTP (not real network/worker)',
        'cases': evidence
      }));
    } finally {
      HttpOverrides.global = previousNetwork;
    }
  });
  late HiDBManager storage;
  late CloudWorkflowDao dao;
  late int epoch;
  late String origin, state;
  late List<http.Request> requests;
  CloudFixtureResult? cloud;
  Future<http.Response?> Function(http.Request)? gate;
  final clients = <CloudWorkflowClient>[];
  final nav = GlobalKey<NavigatorState>();
  const task = '仅本次已保存本人任务';
  http.Response response(Object? value, [int status = 200]) =>
      http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json'});
  AgentWorkflowScope scope() =>
      AgentWorkflowScope(accountHash: 'a', currentLoginEpoch: () => epoch);
  CloudWorkflowClient client({bool enabled = true}) {
    final api = CloudWorkflowApi(
        scope: scope(),
        origin: cloudFixtureOrigin,
        currentOrigin: () => origin,
        token: 'synthetic-fixed-token',
        policy: enabled
            ? const CloudSubmissionPolicy.synthetic()
            : const CloudSubmissionPolicy.production(),
        client: MockClient((req) async {
          requests.add(req);
          if (gate != null) {
            final intercepted = await gate!(req);
            if (intercepted != null) return intercepted;
          }
          final path = req.url.path;
          if (path.endsWith('/capability')) {
            return response({
              'ownerId': 7,
              'available': true,
              'destination': 'cloud',
              'consentVersion': cloudConsentVersion
            });
          }
          if (path.endsWith('/profiles')) {
            return response([
              {
                'providerId': 1,
                'modelRowId': 2,
                'modelId': 'synthetic',
                'providerName': '合成服务',
                'modelName': '合成模型'
              }
            ]);
          }
          if (req.method == 'POST' && path.endsWith('/cloud-workflows')) {
            final p = jsonDecode(req.body) as Map<String, dynamic>;
            expect(await storage.db.query(dao.tableName), hasLength(1));
            expect(p['task'], task);
            expect(p['inputs'], hasLength(1));
            expect(p['inputs'][0]['text'], '明确选择的输入');
            expect(req.body.contains('NOT_SELECTED'), false);
            expect(req.body.contains('apiKey'), false);
            expect(req.body.contains('history'), false);
            expect(req.body.contains('/private/'), false);
            final payload = CloudConfirmedPayload(
                key: p['idempotencyKey'],
                clientInstanceId: p['clientInstanceId'],
                source: CloudLocalSource.fromJson(p['source']),
                task: p['task'],
                inputs: [const CloudTextSnapshot('input.txt', '明确选择的输入')],
                profiles: {for (final r in cloudRoles) r: cloudFixtureProfile},
                acceptance: p['acceptance'],
                budget: p['budget'],
                grantDurationMs: p['grantDurationMs']);
            cloud = CloudFixtureResult(payload);
            return response(cloud!.detail()['parent']);
          }
          if (path.contains('/by-idempotency/')) {
            return cloud == null
                ? response({}, 404)
                : response(cloud!.receipt());
          }
          if (path.endsWith('/stop')) {
            state = 'cancelled';
            return response({'state': state});
          }
          if (path.endsWith('/result')) return response([cloud!.result()]);
          if (path.endsWith(cloud?.taskId ?? 'unmatched')) {
            return response(cloud!.detail(state: state));
          }
          return response({
            'items':
                cloud == null ? [] : [cloud!.detail(state: state)['parent']],
            'nextCursor': null
          });
        }));
    final c = CloudWorkflowClient(api: api, dao: dao);
    clients.add(c);
    return c;
  }

  Future<void> setup() async {
    LoginDao.resetHooksForTest();
    PersonalMemoryTestAccount('a').install();
    epoch = 1;
    origin = cloudFixtureOrigin;
    state = 'complete';
    requests = [];
    cloud = null;
    gate = null;
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 1, title: '合成对话', icon: ''));
    await (await MessageDao.create(storage, cid: 1)).saveMessageWithBlocks(
        MessageModel(content: task, ownerType: OwnerType.sender, createdAt: 1));
    dao = await CloudWorkflowDao.create(storage, accountHash: 'a');
    final workspace = await AgentWorkspaceDao.create(storage, cid: 1);
    for (final text in ['明确选择的输入', 'NOT_SELECTED_PRIVATE_MEMORY']) {
      await workspace.saveInput(
          name: text.startsWith('NOT') ? 'unselected.txt' : 'input.txt',
          sourceKey: '/private/synthetic/$text',
          contentHash: cloudHash(text),
          content: text,
          pageTexts: [text],
          sizeBytes: utf8.encode(text).length);
    }
  }

  Future<void> open(WidgetTester t, CloudWorkflowClient c,
      {bool anime = false}) async {
    t.view.physicalSize = const Size(320, 900);
    t.view.devicePixelRatio = 1;
    await t.runAsync(() => t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        themeAnimationDuration: Duration.zero,
        theme: anime
            ? AppThemeFactory.anime()
            : AppThemeFactory.classic(Colors.blue),
        home: CloudWorkflowPage.synthetic(client: c, cid: 1))));
    await until(
        t, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(t.takeException(), isNull);
  }

  Future<void> tap(WidgetTester t, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await t.scrollUntilVisible(finder, 400,
          scrollable: find.byType(Scrollable).first, maxScrolls: 30);
    }
    await t.ensureVisible(finder);
    await t.pumpAndSettle();
    // SQLite/真实I/O从实际异步区启动，不让FakeAsync队尾和查询互相等待。
    await t.runAsync(() async {
      await t.tap(finder);
    });
    await t.pump();
  }

  Future<void> select(WidgetTester t, String key, String label) async {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await tap(t, f);
    await t.pumpAndSettle();
    await tap(t, find.text(label).last);
    await t.pumpAndSettle();
  }

  Future<void> configure(WidgetTester t) async {
    await select(t, 'cloud-source', task);
    await t.ensureVisible(find.widgetWithText(CheckboxListTile, 'input.txt'));
    await tap(t, find.widgetWithText(CheckboxListTile, 'input.txt'));
    await t.pump();
    for (final r in cloudRoles) {
      await select(t, 'cloud-profile-$r', '合成服务 · 合成模型');
    }
  }

  Future<void> preview(WidgetTester t) async {
    await configure(t);
    final f = find.byKey(const ValueKey('cloud-preview'));
    await t.ensureVisible(f);
    await tap(t, f);
    await until(t, () => find.text('确认本次上传').evaluate().isNotEmpty);
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text(task)),
        findsOneWidget);
    expect(find.text('NOT_SELECTED_PRIVATE_MEMORY'), findsNothing);
  }

  Future<void> submit(WidgetTester t) async {
    await preview(t);
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(t,
        () => find.byKey(const ValueKey('cloud-save')).evaluate().isNotEmpty);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    for (final c in clients) {
      c.dispose();
    }
    clients.clear();
    if (storage.db.isOpen) await t.runAsync(() => storage.db.close());
    LoginSdkConfig.reset();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    expect(t.takeException(), isNull);
  }

  void pageTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (t) async {
      await t.runAsync(setup);
      try {
        await body(t);
        evidence.add({
          'case': name,
          'requests': requests
              .map((r) => {
                    'method': r.method,
                    'path': r.url.path,
                    if (r.body.isNotEmpty) 'body': jsonDecode(r.body)
                  })
              .toList(),
          'receipts': await t.runAsync(() => storage.db.query(dao.tableName)),
          'publicationCount': (await t
                  .runAsync(() => storage.db.query('tb_cloud_publications')))!
              .length,
          'messageCount':
              (await t.runAsync(() => storage.db.query('tb_messages')))!.length
        });
      } finally {
        await close(t);
      }
    });
  }

  testWidgets('guest 生产入口不创建任何认证云请求或sidecar', (t) async {
    PersonalMemoryTestAccount('guest').install();
    await t.pumpWidget(const MaterialApp(home: CloudWorkflowPage()));
    await t.pumpAndSettle();
    expect(find.textContaining('请先登录'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    LoginSdkConfig.reset();
    expect(t.takeException(), isNull);
  });
  testWidgets('任务中心实际云入口不把guest升级为执行授权', (t) async {
    PersonalMemoryTestAccount('guest').install();
    await t.pumpWidget(MaterialApp(
        home: AgentTaskCenterPage(
            accountHash: () => 'guest',
            loadTasks: ({required offset, required limit}) async =>
                const AgentTaskCenterBatch(entries: []))));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('云任务'));
    await t.pumpAndSettle();
    expect(find.byType(CloudWorkflowPage), findsOneWidget);
    expect(find.textContaining('请先登录'), findsOneWidget);
    expect(network.attempts, 0);
    await t.pumpWidget(const SizedBox());
    LoginSdkConfig.reset();
    expect(t.takeException(), isNull);
  });
  for (final anime in [false, true]) {
    pageTest('320pt $anime 生产闸门即便server true预览也零POST', (t) async {
      final c = client(enabled: false);
      await open(t, c, anime: anime);
      await preview(t);
      expect(
          t
              .widget<FilledButton>(find.byKey(const ValueKey('cloud-confirm')))
              .onPressed,
          isNull);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      expect(await t.runAsync(() => storage.db.query(dao.tableName)), isEmpty);
      await tap(t, find.text('取消'));
      await t.pumpAndSettle();
    });
    pageTest('320pt $anime 实际页面确认一POST，手动追加幂等，重开只GET', (t) async {
      final c = client();
      await open(t, c, anime: anime);
      await submit(t);
      expect(await t.runAsync(() => storage.db.query('tb_cloud_publications')),
          isEmpty);
      final f = find.byKey(const ValueKey('cloud-save'));
      await t.ensureVisible(f);
      await tap(t, f);
      await until(
          t,
          () =>
              c.notice == '成果已追加到原对话' &&
              t.widget<FilledButton>(f).onPressed != null);
      t
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await t.pump();
      expect(find.text('成果已追加到原对话'), findsOneWidget);
      await tap(t, f);
      await until(t, () => t.widget<FilledButton>(f).onPressed != null);
      expect(await t.runAsync(() => storage.db.query('tb_messages')),
          hasLength(2));
      final before = requests.where((r) => r.method == 'POST').length;
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      final next = client();
      await open(t, next, anime: anime);
      final row = find.text('任务 ${cloud!.taskId}');
      await tap(t, row);
      await until(t,
          () => find.byKey(const ValueKey('cloud-save')).evaluate().isNotEmpty);
      expect(requests.where((r) => r.method == 'POST'), hasLength(before));
      expect(await t.runAsync(() => storage.db.query('tb_cloud_publications')),
          hasLength(1));
    });
  }
  pageTest('确认等待源编辑后改回0POST，旧preview不补签', (t) async {
    await open(t, client());
    await preview(t);
    await t.runAsync(() async {
      await storage.db.update('tb_messages', {'content': 'changed'});
      await storage.db.update('tb_messages', {'content': task});
    });
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(
        t,
        () =>
            t
                .widget<FilledButton>(
                    find.byKey(const ValueKey('cloud-preview')))
                .onPressed !=
            null);
    t.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await t.pump();
    expect(find.textContaining('原来源已变化'), findsOneWidget);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
    expect(await t.runAsync(() => storage.db.query(dao.tableName)), isEmpty);
  });
  pageTest('preview中epoch变化关闭旧弹窗清数据，迟到确认无POST', (t) async {
    await open(t, client());
    await preview(t);
    ++epoch;
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.text('确认本次上传'), findsNothing);
    expect(find.text(task), findsNothing);
    expect(find.textContaining('账号、后端或恢复状态已变化'), findsOneWidget);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
  pageTest('隐藏路由及App后台暂停GET，resume只查询，stop显式', (t) async {
    state = 'running';
    final c = client();
    await open(t, c);
    await preview(t);
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(t,
        () => find.byKey(const ValueKey('cloud-stop')).evaluate().isNotEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    final n = requests.length;
    await t.pump(const Duration(seconds: 40));
    expect(requests, hasLength(n));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(t, () => requests.length > n);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    final f = find.byKey(const ValueKey('cloud-stop'));
    await t.ensureVisible(f);
    await tap(t, f);
    await until(t, () => c.detail?.state == 'cancelled');
    expect(requests.where((r) => r.method == 'POST'), hasLength(2));
    expect(find.text('已停止'), findsWidgets);
  });
  pageTest('真实route遮挡与恢复生命周期不续轮询，pop只刷新GET', (t) async {
    state = 'running';
    final c = client();
    await open(t, c);
    await preview(t);
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(t, () => c.detail != null);
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('另一页面')))));
    await t.pumpAndSettle();
    final n = requests.length;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump(const Duration(seconds: 40));
    expect(requests, hasLength(n));
    nav.currentState!.pop();
    await t.pumpAndSettle();
    await until(t, () => requests.length > n);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
  });
  pageTest('提交ack未知重开只按原key查询，不以新preview重发', (t) async {
    gate = (r) async => r.method == 'POST' ? response({}, 503) : null;
    final c = client();
    await open(t, c);
    await preview(t);
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(t, () => c.receipts.length == 1);
    final receipt = c.receipts.single;
    expect(receipt.status, 'submission_unknown');
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    final next = client();
    await open(t, next);
    expect(next.receipts.single.key, receipt.key);
    await tap(t, find.text('查询'));
    await until(
        t,
        () =>
            t
                .widget<TextButton>(find.widgetWithText(TextButton, '查询'))
                .onPressed !=
            null);
    expect(requests.last.url.path.endsWith('/by-idempotency/${receipt.key}'),
        true);
    await configure(t);
    await tap(t, find.byKey(const ValueKey('cloud-preview')));
    await until(
        t,
        () =>
            t
                .widget<FilledButton>(
                    find.byKey(const ValueKey('cloud-preview')))
                .onPressed !=
            null);
    t.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await t.pump();
    expect(find.textContaining('该来源有未知提交'), findsOneWidget);
    expect(find.text('确认本次上传'), findsNothing);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    expect(
        await t.runAsync(() => storage.db.query(dao.tableName)), hasLength(1));
  });
  pageTest('review receipt 首次404重建后原key查询200同步页面且仅明确保存', (t) async {
    var discoverable = false;
    gate = (r) async {
      if (r.method == 'POST') {
        // 合成服务已经接受唯一POST，客户端只得到不可解析的ack。
        final p = jsonDecode(r.body) as Map<String, dynamic>;
        expect(await storage.db.query(dao.tableName), hasLength(1));
        cloud = CloudFixtureResult(CloudConfirmedPayload(
            key: p['idempotencyKey'],
            clientInstanceId: p['clientInstanceId'],
            source: CloudLocalSource.fromJson(p['source']),
            task: p['task'],
            inputs: [const CloudTextSnapshot('input.txt', '明确选择的输入')],
            profiles: {
              for (final role in cloudRoles) role: cloudFixtureProfile
            },
            acceptance: p['acceptance'],
            budget: p['budget'],
            grantDurationMs: p['grantDurationMs']));
        return http.Response('synthetic incomplete ack', 200);
      }
      if (r.url.path.contains('/by-idempotency/') && !discoverable) {
        return response({}, 404);
      }
      return null;
    };
    final first = client();
    await open(t, first);
    await preview(t);
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(t, () => first.receipts.length == 1);
    final original = first.receipts.single;
    expect(original.status, 'submission_unknown');
    expect(cloud, isNotNull);
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    dao = (await t
        .runAsync(() => CloudWorkflowDao.create(storage, accountHash: 'a')))!;
    final reopened = client();
    await open(t, reopened);
    expect(reopened.receipts.single.key, original.key);
    expect(reopened.receipts.single.status, 'submission_unknown');
    discoverable = true;
    await tap(t, find.text('查询'));
    await until(t, () => reopened.detail?.state == 'complete');
    expect(reopened.receipts.single.status, 'accepted');
    expect(reopened.receipts.single.key, original.key);
    expect(reopened.receipts.single.taskId, cloud!.taskId);
    expect(reopened.receipts.single.publicationId, cloud!.publicationId);
    expect(reopened.localReceipt?.bindingId, original.bindingId);
    expect(find.text('提交结果未知'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-save')), findsOneWidget);
    expect(await t.runAsync(() => storage.db.query('tb_cloud_publications')),
        isEmpty);
    expect(
        await t.runAsync(() => storage.db.query('tb_messages')), hasLength(1));
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    final save = find.byKey(const ValueKey('cloud-save'));
    await tap(t, save);
    await until(
        t,
        () =>
            reopened.notice == '成果已追加到原对话' &&
            t.widget<FilledButton>(save).onPressed != null);
    await tap(t, save);
    await until(t, () => t.widget<FilledButton>(save).onPressed != null);
    expect(await t.runAsync(() => storage.db.query('tb_cloud_publications')),
        hasLength(1));
    expect(
        await t.runAsync(() => storage.db.query('tb_messages')), hasLength(2));
    expect(requests.where((r) => r.method == 'POST'), hasLength(1));
    expect(
        requests
            .where((r) => r.url.path.contains('/by-idempotency/'))
            .every((r) => r.url.path.endsWith(original.key)),
        true);
  });
  pageTest('更换对话重建选择槽，不复用上一条本人输入', (t) async {
    await t.runAsync(() async {
      await (await ConversationListDao.create(storage))
          .saveConversation(ConversationModel(cid: 2, title: '第二对话', icon: ''));
      await (await MessageDao.create(storage, cid: 2)).saveMessageWithBlocks(
          MessageModel(
              content: '第二条本人输入', ownerType: OwnerType.sender, createdAt: 2));
    });
    await open(t, client());
    await select(t, 'cloud-source', task);
    await select(t, 'cloud-conversation', '第二对话');
    await until(
        t,
        () =>
            t
                .widget<FilledButton>(
                    find.byKey(const ValueKey('cloud-preview')))
                .onPressed !=
            null);
    expect(
        t
            .state<FormFieldState<int>>(
                find.byKey(const ValueKey('cloud-source')))
            .value,
        isNull);
    await select(t, 'cloud-source', '第二条本人输入');
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
    expect(t.takeException(), isNull);
  });
  pageTest('确认等待输入版本改变拒绝上传，不冻结另一版本', (t) async {
    await open(t, client());
    await preview(t);
    await t.runAsync(() async {
      // saveInput会创建独立快照；这里修改实际已选文件，验证原版本失效。
      await storage.db.update('tb_agent_workspace_files',
          {'currentRevision': 2, 'contentHash': cloudHash('新的输入')},
          where: 'name=?', whereArgs: ['input.txt']);
    });
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(
        t,
        () =>
            t
                .widget<FilledButton>(
                    find.byKey(const ValueKey('cloud-preview')))
                .onPressed !=
            null);
    t.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await t.pump();
    expect(find.textContaining('原来源已变化'), findsOneWidget);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
    expect(await t.runAsync(() => storage.db.query(dao.tableName)), isEmpty);
  });
  pageTest('恢复代次撤销preview且不能使用旧确认', (t) async {
    await open(t, client());
    await preview(t);
    ++BackupService.agentExecutionRevision;
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('账号、后端或恢复状态已变化'), findsOneWidget);
    expect(requests.where((r) => r.method == 'POST'), isEmpty);
  });
  pageTest('在途GET后origin变化，旧401不注销当前账号或刷新旧UI', (t) async {
    state = 'running';
    final c = client();
    await open(t, c);
    await preview(t);
    await tap(t, find.byKey(const ValueKey('cloud-confirm')));
    await until(t, () => c.detail != null);
    final held = Completer<http.Response>();
    gate = (r) async => r.url.path.endsWith(cloud!.taskId) ? held.future : null;
    await tap(t, find.byKey(const ValueKey('cloud-refresh')));
    final n = requests.length;
    origin = 'https://changed.synthetic.invalid';
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(() async => held.complete(response({}, 401)));
    await t.pumpAndSettle();
    expect(LoginDao.getAccountHash(), 'a');
    expect(find.textContaining('账号、后端或恢复状态已变化'), findsOneWidget);
    expect(find.text('登录认证已失效，请重新登录后查看云任务'), findsNothing);
    await t.pump(const Duration(seconds: 40));
    expect(requests, hasLength(n));
    expect(t.takeException(), isNull);
  });
}
