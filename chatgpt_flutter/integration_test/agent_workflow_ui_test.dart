// 专用合成账号的离线原生验收；不改真实配置/权限、不执行付费模型。
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_executor.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/agent_verification_dao.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/pages/agent_workflow_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'personal_memory_ui_test.dart' show initializeSemantics;

const account = 'agent_workflow_native_isolated_fixture';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeSemantics(binding));
  testWidgets('协作双布局原生配置/停止继续/同容器进程恢复', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    SharedPreferences.setPrefix('chatai_workflow_native.');
    final cache = await tester.runAsync(() => HiCache.preInit());
    final restoring = cache!.get('restart_prepared') == true;
    if (!restoring) await tester.runAsync(() => cache.prefs!.clear());
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'example.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: _Login(),
        onLogoutNavigate: () {}));
    final oldNetwork = HttpOverrides.current, network = _NoNetwork();
    HttpOverrides.global = network;
    final storage =
        (await tester.runAsync(() => HiDBManager.instance(dbName: account)))!;
    final dao = (await tester.runAsync(
        () => AgentWorkflowDao.create(storage, accountHash: account)))!;
    final transport = _Transport();
    final native = _NativeAudit(PlatformAgentBackgroundExecution.instance);
    final executor = AgentTaskExecutor.instance;
    final coordinator = AgentWorkflowCoordinator(
        channel: AgentExecutionChannel.instance,
        background: native,
        foreground: () => executor.foreground,
        serviceForProfile: transport.service,
        profileAvailable: (_) async => true);
    final settings = AISettings.defaults()
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '离线模型stub',
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
    AgentWorkflowScope scope() => AgentWorkflowScope(accountHash: account);
    Future<T> io<T>(Future<T> Function() action) async => (await tester
        .runAsync(() => action().timeout(const Duration(seconds: 20)))) as T;
    addTearDown(() async {
      transport.release();
      await tester.runAsync(() async {
        await coordinator.stopAll(scope()).timeout(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox.shrink());
        await HiDBManager.closeAll().timeout(const Duration(seconds: 5));
      });
      HttpOverrides.global = oldNetwork;
      LoginSdkConfig.reset();
    });
    Future<void> open(AppVisualStyle style, int cid, {String? id}) async {
      await tester.runAsync(() => tester.pumpWidget(Center(
          child: SizedBox(
              width: 320,
              child: MaterialApp(
                  key: UniqueKey(),
                  themeAnimationDuration: Duration.zero,
                  theme: style == AppVisualStyle.anime
                      ? AppThemeFactory.anime()
                      : AppThemeFactory.classic(Colors.blue),
                  home: AgentWorkflowPage(
                      conversation: id == null
                          ? ConversationModel(
                              cid: cid, title: '离线协作${style.name}', icon: '')
                          : null,
                      parentId: id,
                      expectedAccountHash: account,
                      storage: storage,
                      scope: scope(),
                      coordinator: coordinator,
                      loadSettings: () async => settings.clone()))))));
      await _until(tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expect(tester.getSize(find.byType(AgentWorkflowPage)).width, 320);
    }

    Future<void> tap(Finder f) async {
      await tester.ensureVisible(f);
      await _idle(tester);
      await tester.runAsync(() => tester.tap(f));
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> keyboard(Finder field, String content, String stage) async {
      tester.testTextInput.register();
      await tester.enterText(field, content);
      FocusManager.instance.primaryFocus?.unfocus();
      binding.focusedEditable = null;
      tester.testTextInput.unregister();
      await _idle(tester);
      await tester.ensureVisible(field);
      await tester.tap(field);
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      await _until(tester, () => tester.view.viewInsets.bottom > 0,
          seconds: 20);
      expect(tester.testTextInput.isRegistered, false);
      expect(tester.view.viewInsets.bottom, greaterThan(0));
      debugPrint(
          'WORKFLOW_UI_KEYBOARD:$stage;width=320;inset=${tester.view.viewInsets.bottom};mock=false');
      await _screen(tester, stage);
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await _until(tester, () => tester.view.viewInsets.bottom == 0);
    }

    Future<void> save(AppVisualStyle style, AgentWorkflow task) async {
      await tap(find.widgetWithText(OutlinedButton, '确认保存成果'));
      await _until(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      final field = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      await keyboard(
          field, '${style.name}-result.md', '${style.name}-save-keyboard');
      await tap(find.widgetWithText(TextButton, '确认保存'));
      await _until(
          tester,
          () =>
              find.byType(AlertDialog).evaluate().isEmpty &&
              find.text('任务：节点已完成').evaluate().isNotEmpty);
      expect(
          (await io(() => dao.read(task.id)))!.state, WorkflowState.complete);
      expect(
          await io(() => storage.db.query(AgentWorkflowDao.outputPublications,
              where: 'parentId=?', whereArgs: [task.id])),
          hasLength(1));
      expect(
          await io(() => storage.db.query(AgentWorkflowDao.publications,
              where: 'parentId=?', whereArgs: [task.id])),
          hasLength(1));
      await _screen(tester, '${style.name}-confirmed-result');
    }

    if (!restoring) {
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        final cid = 100 + style.index;
        await io(() async {
          await (await ConversationListDao.create(storage)).saveConversation(
              ConversationModel(
                  cid: cid, title: '离线协作${style.name}', icon: ''));
          await (await AgentVerificationDao.create(storage)).saveCriteria(
              cid,
              TaskAcceptanceCriteria(
                      expectedOutputNames: ['${style.name}-result.md'],
                      format: 'md',
                      requireFullRead: false)
                  .toJson());
        });
        await open(style, cid);
        expect(
            tester
                .widget<FilledButton>(
                    find.byKey(const ValueKey('workflow-start')))
                .onPressed,
            isNull);
        final before = transport.requests.length;
        await tap(find.widgetWithText(SwitchListTile, '本次启用三Agent协作'));
        await keyboard(find.byKey(const ValueKey('workflow-task')),
            '本次合成任务 ${style.name}', '${style.name}-task-keyboard');
        for (final role in [WorkflowRole.writing, WorkflowRole.review]) {
          await tap(find.byKey(ValueKey('workflow-profile-${role.name}')));
          await tester.pumpAndSettle();
          await tap(find.text('离线模型stub · 合成${workflowRoleLabel(role)}').last);
          await tester.pumpAndSettle();
        }
        await _screen(tester, '${style.name}-configuration');
        transport.holdWriter();
        await tap(find.byKey(const ValueKey('workflow-start')));
        await _until(tester, () => transport.waitingWriter);
        final task = (await io(() => dao.list(cid))).single;
        expect(transport.requests.length, before + 1);
        expect((await io(() => dao.steps(task.id))).first.state,
            WorkflowState.complete);
        await _screen(tester, '${style.name}-analysis-committed');
        await tester.pumpWidget(const MaterialApp(
            home: Scaffold(
                body: SafeArea(child: Text('切页后本机任务仍注册，合成writer等待')))));
        await _idle(tester);
        expect(coordinator.busy(account, task.id), true);
        expect(transport.requests.length, before + 1);
        await _screen(tester, '${style.name}-away');
        await open(style, cid, id: task.id);
        if (style == AppVisualStyle.classic) {
          debugPrint('WORKFLOW_UI_BACKGROUND_READY');
          await _until(tester, () => !executor.foreground, seconds: 20);
          if (!native.lastActive) {
            await _until(
                tester,
                () =>
                    coordinator.lookup(account, task.id)!.workflow.state ==
                    WorkflowState.paused);
            expect(transport.requests.length, before + 1);
            debugPrint(
                'WORKFLOW_UI_BACKGROUND_SAFE_PAUSE:requests=${transport.requests.length};native=false');
          } else {
            debugPrint('WORKFLOW_UI_BACKGROUND_GRANTED:duration-not-verified');
          }
          await _until(tester, () => executor.foreground, seconds: 20);
          await _screen(tester, 'classic-background-returned');
        }
        await tap(find.widgetWithText(OutlinedButton, '停止任务'));
        await _until(
            tester,
            () =>
                coordinator.lookup(account, task.id)!.workflow.state ==
                WorkflowState.paused);
        transport.release();
        await _until(tester, () => !coordinator.busy(account, task.id));
        expect(transport.requests.length, before + 1);
        expect(await io(() => dao.attemptHistory(task.id)), hasLength(1));
        await open(style, cid, id: task.id);
        await _screen(tester, '${style.name}-stopped');
        await tap(find.widgetWithText(FilledButton, '明确继续'));
        await _until(
            tester,
            () =>
                transport.requests.length == before + 3 &&
                !coordinator.busy(account, task.id));
        await open(style, cid, id: task.id);
        expect(find.text('任务：等待处理'), findsOneWidget);
        expect(transport.requests.sublist(before).map((p) => p['model']),
            ['analysis', 'writing', 'review']);
        await _screen(tester, '${style.name}-waiting-confirmation');
        await save(style, (await io(() => dao.read(task.id)))!);
        await tap(find.widgetWithText(TextButton, '复制稿件'));
        expect((await Clipboard.getData(Clipboard.kTextPlain))!.text,
            contains('writing-result'));
        expect(transport.requests.length, before + 3);
        await io(() => cache.prefs!.setString('${style.name}_id', task.id));
        debugPrint(
            'WORKFLOW_UI_LAYOUT_VERIFIED:${style.name};requests=3;network=${network.attempts}');
      }
      await io(() async {
        await (await ConversationListDao.create(storage)).saveConversation(
            ConversationModel(cid: 103, title: '待进程恢复任务', icon: ''));
      });
      final partial = await io(() => dao.createFromSource(scope(),
          cid: 103,
          newTask: '进程重开后只明确继续剩余两个节点',
          newUserCreatedAt: DateTime.now().millisecondsSinceEpoch,
          profiles: {
            for (final r in WorkflowRole.values)
              r: WorkflowModelProfile('local', 'fixture', r.name)
          },
          acceptance: const TaskAcceptanceCriteria(requireFullRead: false)));
      transport.holdWriter();
      unawaited(coordinator.start(dao, scope(), partial));
      await _until(tester, () => transport.waitingWriter);
      await io(() => coordinator.stop(dao, scope(), partial));
      transport.release();
      await _until(tester, () => !coordinator.busy(account, partial.id));
      expect(
          (await io(() => dao.read(partial.id)))!.state, WorkflowState.paused);
      expect((await io(() => dao.steps(partial.id))).first.state,
          WorkflowState.complete);
      expect(transport.requests.length, 7);
      await io(() => cache.prefs!.setString('partial_id', partial.id));
      await io(() => cache.prefs!.setBool('restart_prepared', true));
      await open(AppVisualStyle.anime, 103, id: partial.id);
      await _screen(tester, 'anime-restart-prepared');
      debugPrint(
          'WORKFLOW_UI_RESTART_PREPARED:parents=3;stubRequests=7;network=${network.attempts};native=${jsonEncode(native.events)}');
    } else {
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        final id = cache.get('${style.name}_id') as String;
        final task = (await io(() => dao.read(id)))!;
        expect(task.state, WorkflowState.complete);
        expect(
            (await io(() => dao.steps(id)))
                .every((n) => n.state == WorkflowState.complete),
            true);
        expect(
            await io(() => storage.db.query('tb_messages',
                where: 'cid=? AND ownerType=?',
                whereArgs: [task.cid, OwnerType.receiver.toString()])),
            hasLength(1));
        expect(
            await io(() => storage.db.query(AgentWorkspaceDao.filesTable,
                where: "cid=? AND kind='output'", whereArgs: [task.cid])),
            hasLength(1));
        await open(style, task.cid, id: id);
        expect(find.text('任务：节点已完成'), findsOneWidget);
        expect(transport.requests, isEmpty);
        await _screen(tester, '${style.name}-restored-complete');
      }
      final id = cache.get('partial_id') as String;
      await open(AppVisualStyle.anime, 103, id: id);
      expect(find.text('任务：已暂停'), findsOneWidget);
      expect(transport.requests, isEmpty);
      expect(
          (await io(() => dao.steps(id))).first.state, WorkflowState.complete);
      await _screen(tester, 'anime-restored-paused');
      debugPrint('WORKFLOW_UI_REOPENED:requests=0;network=${network.attempts}');
      await tap(find.widgetWithText(FilledButton, '明确继续'));
      await _until(
          tester,
          () =>
              !coordinator.busy(account, id) && transport.requests.length == 2);
      expect(transport.requests.map((r) => r['model']), ['writing', 'review']);
      expect((await io(() => dao.read(id)))!.state, WorkflowState.complete);
      expect(
          await io(() => storage.db.query(AgentWorkflowDao.publications,
              where: 'parentId=?', whereArgs: [id])),
          hasLength(1));
      await open(AppVisualStyle.anime, 103, id: id);
      await _screen(tester, 'anime-restored-explicit-continued');
      debugPrint(
          'WORKFLOW_UI_RESTART_VERIFIED:parents=3;reopened=0;explicitContinue=2;network=${network.attempts};native=${jsonEncode(native.events)}');
    }
    expect(network.attempts, 0);
    expect(tester.takeException(), isNull);
    debugPrint('WORKFLOW_UI_PAYLOADS:${jsonEncode(transport.requests)}');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _until(WidgetTester tester, bool Function() ready,
    {int seconds = 15}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 70)));
    await tester.pump(const Duration(milliseconds: 40));
    if (ready()) return;
  }
  fail(
      '离线协作状态超时：${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join('|')}');
}

Future<void> _idle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _screen(WidgetTester tester, String stage) async {
  await _idle(tester);
  debugPrint('WORKFLOW_UI_SCREEN:$stage');
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
}

class _Transport {
  final requests = <Map<String, dynamic>>[];
  Completer<void>? _writer;
  bool waitingWriter = false;
  void holdWriter() {
    _writer = Completer<void>();
    waitingWriter = false;
  }

  void release() {
    final gate = _writer;
    _writer = null;
    waitingWriter = false;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<ChatService> service(WorkflowModelProfile p) async {
    if (p.modelId == 'writing' && _writer != null) {
      waitingWriter = true;
      await _writer!.future;
    }
    return _Stub(this, p);
  }
}

class _Stub
    implements
        ChatService,
        OptionsAwareNonStreamingChatService,
        AttemptAwareChatService {
  final _Transport transport;
  final WorkflowModelProfile profile;
  _Stub(this.transport, this.profile);
  @override
  ModelCapabilities get capabilities => const ModelCapabilities();
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    final messages = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    expect(options.maxOutputTokensOverride, 2048);
    expect(options.maxAutoRetries, 0);
    transport.requests.add({
      'model': profile.modelId,
      'messages': jsonDecode(jsonEncode(messages)),
      'max_tokens': 2048
    });
    return ChatCompletionResult(
        content: profile.modelId == 'review'
            ? '{"decision":"accept","feedback":"离线合成意见"}'
            : '${profile.modelId}-result',
        promptTokens: 10,
        completionTokens: 5);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _NativeAudit implements AgentBackgroundExecution {
  final AgentBackgroundExecution inner;
  final events = <Map<String, dynamic>>[];
  bool lastActive = false;
  _NativeAudit(this.inner);
  @override
  Future<AgentBackgroundCapabilities> capabilities() => inner.capabilities();
  @override
  bool isActive(String id) => inner.isActive(id);
  @override
  Future<AgentBackgroundStartResult> start(
      {required String runId,
      required int cid,
      required String title,
      required Future<void> Function(String) onInterrupted}) async {
    final r = await inner.start(
        runId: runId, cid: cid, title: title, onInterrupted: onInterrupted);
    lastActive = r.active;
    events.add({
      'start': runId,
      'active': r.active,
      'mode': r.mode,
      'reason': r.reason
    });
    debugPrint('WORKFLOW_UI_NATIVE_START:${jsonEncode(events.last)}');
    return r;
  }

  @override
  Future<void> update(
      {required String runId,
      required int completed,
      required int total,
      required String status}) async {
    events.add({
      'update': runId,
      'completed': completed,
      'total': total,
      'status': status
    });
    await inner.update(
        runId: runId, completed: completed, total: total, status: status);
  }

  @override
  Future<void> stop({required String runId, bool success = false}) async {
    events.add({'stop': runId, 'success': success});
    await inner.stop(runId: runId, success: success);
  }
}

class _Login implements TokenStorage {
  @override
  Map<String, dynamic> readProfileSync() => {
        'accountHash': account,
        'userName': '离线合成用户',
        'avatar': '',
        'guest': true
      };
  @override
  Future<Map<String, dynamic>> readProfile() async => readProfileSync();
  @override
  String readTokenSync() => 'guest-mode';
  @override
  Future<String> readToken() async => readTokenSync();
  @override
  Future<void> clear() async {}
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}

class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? c) {
    attempts++;
    throw StateError('协作原生fixture禁止网络');
  }
}
