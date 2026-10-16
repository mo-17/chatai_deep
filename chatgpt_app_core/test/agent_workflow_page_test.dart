import 'dart:async';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/db/agent_verification_dao.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_workflow_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'agent_workflow_foundation_test.dart'
    show FakeWorkflowTransport, FakeWorkflowBackground;
import 'support/personal_memory_test_support.dart';

Future<void> _until(WidgetTester tester, FutureOr<bool> Function() done) async {
  for (var i = 0; i < 160; i++) {
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 30));
    if (await tester.runAsync(() async => done()) == true) return;
  }
  fail(
      '页面未在有界等待内到达预期状态：${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().join(' | ')}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late AgentWorkflowCoordinator coordinator;
  late FakeWorkflowTransport transport;
  late PersonalMemoryTestAccount auth;
  late AISettings settings;
  late int epoch, restore;
  final conversation = ConversationModel(cid: 1, title: '合成协作', icon: '');
  final profiles = {
    for (final r in WorkflowRole.values)
      r: WorkflowModelProfile('local', 'fixture', r.name)
  };
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'a',
      currentAccount: () => auth.account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => restore);
  Future<void> setup() async {
    LoginDao.resetHooksForTest();
    auth = PersonalMemoryTestAccount('a')..install();
    epoch = 1;
    restore = 0;
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel.fromJson(conversation.toJson()));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'a');
    settings = AISettings.defaults()
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '离线合成服务',
            type: 'openai',
            apiKey: 'synthetic',
            enabled: true,
            models: [
              for (final r in WorkflowRole.values)
                AiModel(id: r.name, name: '合成${workflowRoleLabel(r)}')
            ])
      ]
      ..activeProviderId = 'fixture';
    settings.setActiveModel('analysis');
    transport = FakeWorkflowTransport();
    coordinator = AgentWorkflowCoordinator(
        channel: AgentExecutionChannel(),
        background: FakeWorkflowBackground(),
        foreground: () => true,
        serviceForProfile: (p) async => transport.service(p),
        profileAvailable: (_) async => true);
  }

  Future<void> open(WidgetTester tester,
      {bool anime = false, String? parentId, bool config = true}) async {
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: anime
            ? AppThemeFactory.anime()
            : AppThemeFactory.classic(Colors.blue),
        home: AgentWorkflowPage(
            conversation: config ? conversation : null,
            parentId: parentId,
            expectedAccountHash: 'a',
            storage: storage,
            scope: scope(),
            coordinator: coordinator,
            loadSettings: () async => settings.clone()))));
    await _until(
        tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.runAsync(() async {
      transport.gate?.complete();
      await coordinator.stopAll(scope()).timeout(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await storage.db.close().timeout(const Duration(seconds: 5));
    });
    LoginSdkConfig.reset();
  }

  Future<void> configure(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(SwitchListTile, '本次启用三Agent协作'));
    await tester.enterText(
        find.byKey(const ValueKey('workflow-task')), '只处理本次合成任务');
    for (final role in [WorkflowRole.writing, WorkflowRole.review]) {
      final finder = find.byKey(ValueKey('workflow-profile-${role.name}'));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('离线合成服务 · 合成${workflowRoleLabel(role)}').last);
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.byKey(const ValueKey('workflow-start')));
  }

  for (final anime in [false, true]) {
    for (final input in [false, true]) {
      testWidgets(
          '${anime ? 'anime' : 'classic'} 不兼容${input ? '全文读取模型' : '多输出JSON条件'}开始前拒绝，零源行/任务/请求',
          (tester) async {
        tester.view.physicalSize = const Size(320, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.runAsync(setup);
        addTearDown(() => close(tester));
        await tester.runAsync(() async {
          final store = await AgentVerificationDao.create(storage);
          await store.saveCriteria(
              1,
              (input
                      ? const TaskAcceptanceCriteria(requireFullRead: true)
                      : const TaskAcceptanceCriteria(
                          expectedOutputNames: ['a.md', 'b.json'],
                          format: 'json'))
                  .toJson());
          if (input) {
            await (await AgentWorkspaceDao.create(storage, cid: 1)).saveInput(
                name: 'read-required.txt',
                sourceKey: 'fixture',
                contentHash: workflowHash('合成输入'),
                content: '合成输入',
                pageTexts: [],
                sizeBytes: 12);
          }
        });
        await open(tester, anime: anime);
        await configure(tester);
        if (input) {
          final f = find.widgetWithText(CheckboxListTile, 'read-required.txt');
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.runAsync(() => tester.tap(f));
          await _until(
              tester, () => tester.widget<CheckboxListTile>(f).value == true);
        }
        await tester
            .ensureVisible(find.byKey(const ValueKey('workflow-start')));
        await tester.pumpAndSettle();
        await _until(tester, () {
          final f = find.byKey(const ValueKey('workflow-start'));
          return f.evaluate().length == 1 &&
              tester.widget<FilledButton>(f).onPressed != null;
        });
        await tester.runAsync(
            () => tester.tap(find.byKey(const ValueKey('workflow-start'))));
        await _until(tester, () {
          final f = find.byKey(const ValueKey('workflow-start'));
          return f.evaluate().length == 1 &&
              tester.widget<FilledButton>(f).onPressed != null;
        });
        await tester.drag(find.byType(ListView).first, const Offset(0, 1800));
        await tester.pumpAndSettle();
        await _until(tester,
            () => find.textContaining('请回工作区调整验收条件或模型').evaluate().isNotEmpty);
        expect(await tester.runAsync(() => storage.db.query('tb_messages')),
            isEmpty);
        expect(
            await tester
                .runAsync(() => storage.db.query(AgentWorkflowDao.workflows)),
            isEmpty);
        expect(transport.requests, isEmpty);
        expect(tester.takeException(), null);
      });
    }
    testWidgets('${anime ? 'anime' : 'classic'} 320pt默认关闭，真实配置三模型→独立出站→只发布一次',
        (tester) async {
      tester.view.physicalSize = const Size(320, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.runAsync(setup);
      addTearDown(() => close(tester));
      await open(tester, anime: anime);
      final start = tester
          .widget<FilledButton>(find.byKey(const ValueKey('workflow-start')));
      expect(start.onPressed, null);
      expect(transport.requests, isEmpty);
      await configure(tester);
      await tester.runAsync(
          () => tester.tap(find.byKey(const ValueKey('workflow-start'))));
      await _until(
          tester,
          () =>
              transport.requests.length == 3 &&
              find.text('任务：节点已完成').evaluate().isNotEmpty);
      expect(transport.requests.map((r) => r['model']),
          ['analysis', 'writing', 'review']);
      final rows = await tester.runAsync(() => storage.db.query('tb_messages'));
      expect(
          rows!
              .where((r) => r['ownerType'] == OwnerType.sender.toString())
              .length,
          1);
      expect(
          rows
              .where((r) => r['ownerType'] == OwnerType.receiver.toString())
              .length,
          1);
      expect(find.textContaining('费用未知'), findsOneWidget);
      expect(tester.takeException(), null);
    });
  }
  testWidgets('冷启动unknown任务明确继续只打开确认，取消仍保留unknown且零请求', (tester) async {
    await tester.runAsync(setup);
    addTearDown(() => close(tester));
    final running = await tester.runAsync(() async {
      final user = await (await MessageDao.create(storage, cid: 1))
          .saveMessageWithBlocks(MessageModel(
              content: '中断任务', ownerType: OwnerType.sender, createdAt: 10));
      var w = await dao.createFromSource(scope(),
          cid: 1, userRowId: user, profiles: profiles);
      w = await dao.claim(scope(), w.id, w.revision);
      w = await dao.beginStep(
          scope(), WorkflowFence.of(w), (await dao.steps(w.id)).first.id,
          inputHash: workflowHash('x'));
      return (await dao.reserveDispatch(
              scope(), WorkflowFence.of(w), (await dao.steps(w.id)).first.id,
              inputHash: workflowHash('x'), estimatedInput: 10))
          .workflow;
    });
    await open(tester, parentId: running!.id, config: false);
    expect(find.text('任务：已暂停'), findsOneWidget);
    expect(transport.requests, isEmpty);
    await tester.ensureVisible(find.text('明确继续'));
    await tester.runAsync(() => tester.tap(find.text('明确继续')));
    await _until(
        tester,
        () => find
            .byKey(const ValueKey('direct_recovery_cancel'))
            .evaluate()
            .isNotEmpty);
    expect(find.textContaining('上游可能已处理或计费'), findsOneWidget);
    final before = (await tester.runAsync(() => dao.read(running.id)))!.toRow();
    await tester.tap(find.byKey(const ValueKey('direct_recovery_cancel')));
    await tester.pumpAndSettle();
    expect(
        (await tester.runAsync(() => dao.read(running.id)))!.toRow(), before);
    expect(transport.requests, isEmpty);
    final attempts =
        await tester.runAsync(() => dao.attemptHistory(running.id));
    expect(attempts!.single['state'], 'unknown');
  });
  testWidgets('restore/同账号重登在配置后使旧页面过期，0源行0请求', (tester) async {
    await tester.runAsync(setup);
    addTearDown(() => close(tester));
    await open(tester);
    await configure(tester);
    epoch++;
    restore++;
    await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('workflow-start'))));
    await _until(tester,
        () => find.textContaining('账号、登录或恢复状态已变化').evaluate().isNotEmpty);
    expect(transport.requests, isEmpty);
    expect((await tester.runAsync(() => storage.db.query('tb_messages'))),
        isEmpty);
    expect(find.textContaining('账号、登录或恢复状态已变化'), findsOneWidget);
  });
  testWidgets('源提交DB失败回滚用户行；不会先宣告启动或请求模型', (tester) async {
    await tester.runAsync(setup);
    addTearDown(() => close(tester));
    await tester.runAsync(() => storage.db.execute(
        "CREATE TRIGGER fail_workflow BEFORE INSERT ON tb_agent_workflow BEGIN SELECT RAISE(ABORT,'synthetic'); END"));
    await open(tester);
    await configure(tester);
    await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('workflow-start'))));
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 100));
    await _until(tester, () => find.text('操作未保存，请刷新后重试').evaluate().isNotEmpty);
    expect(transport.requests, isEmpty);
    expect((await tester.runAsync(() => storage.db.query('tb_messages'))),
        isEmpty);
  });
  testWidgets('切页不停止已提交任务；完成节点冷重开复用且不再次请求', (tester) async {
    await tester.runAsync(setup);
    addTearDown(() => close(tester));
    transport.gate = Completer<void>();
    await open(tester);
    await configure(tester);
    await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('workflow-start'))));
    await _until(tester, () => transport.requests.length == 1);
    final tasks = await tester.runAsync(() => dao.list(1));
    await tester.pumpWidget(const SizedBox());
    final gate = transport.gate!;
    transport.gate = null;
    gate.complete();
    await _until(tester, () => !coordinator.busy('a', tasks!.single.id));
    expect(transport.requests.length, 3);
    await open(tester, config: false, parentId: tasks!.single.id);
    expect(find.text('任务：节点已完成'), findsOneWidget);
    expect(transport.requests.length, 3);
  });
  for (final stale in [false, true]) {
    testWidgets('前台成果确认 ${stale ? '过期拒绝' : '取消与明确保存'}，不额外请求模型', (tester) async {
      await tester.runAsync(setup);
      addTearDown(() => close(tester));
      final task = await tester.runAsync(() async {
        final user = await (await MessageDao.create(storage, cid: 1))
            .saveMessageWithBlocks(MessageModel(
                content: '合成任务', ownerType: OwnerType.sender, createdAt: 10));
        final w = await dao.createFromSource(scope(),
            cid: 1, userRowId: user, profiles: profiles);
        await coordinator.start(dao, scope(), w);
        return (await dao.read(w.id))!;
      });
      expect(task!.backgroundEnabled, false);
      expect(task.state, WorkflowState.complete);
      expect(transport.requests.length, 3);
      await open(tester, parentId: task.id, config: false);
      final button = find.widgetWithText(OutlinedButton, '确认保存成果');
      await tester.ensureVisible(button);
      await tester.runAsync(() => tester.tap(button));
      await _until(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(
          await tester.runAsync(
              () => storage.db.query(AgentWorkflowDao.outputPublications)),
          isEmpty);
      await tester.runAsync(() => tester.tap(button));
      await _until(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'confirmed.md');
      if (stale) epoch++;
      await tester
          .runAsync(() => tester.tap(find.widgetWithText(TextButton, '确认保存')));
      await _until(
          tester,
          () =>
              find.byType(AlertDialog).evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty);
      if (!stale) {
        await _until(
            tester,
            () async =>
                (await storage.db.query(AgentWorkflowDao.outputPublications))
                    .isNotEmpty);
      }
      expect(
          await tester.runAsync(
              () => storage.db.query(AgentWorkflowDao.outputPublications)),
          stale ? isEmpty : hasLength(1));
      expect(
          await tester.runAsync(() => storage.db
              .query(AgentWorkspaceDao.filesTable, where: "kind='output'")),
          stale ? isEmpty : hasLength(1));
      expect(transport.requests.length, 3);
    });
  }
}
