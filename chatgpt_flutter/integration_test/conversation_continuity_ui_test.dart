// 独立合成账号/数据库的原生切页验收；普通模型为stub，不访问真实服务。
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_draft_store.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/read_aloud_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/composer_reference.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/ui/conversation_generation_routes.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/message_reference_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
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
import 'package:integration_test/integration_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'personal_memory_ui_test.dart' show initializeSemantics;

const account = 'ordinary_continuity_native_isolated';
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeSemantics(binding));
  testWidgets('普通聊天双布局真实切页、确认停止、引用新草稿与进程恢复', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    SharedPreferences.setPrefix('chatai_continuity_native.');
    final cache = (await tester.runAsync(() => HiCache.preInit()))!;
    final restoring = cache.get('restart_prepared') == true;
    if (!restoring) await tester.runAsync(() => cache.prefs!.clear());
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'example.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: _Login(),
        onLogoutNavigate: () {}));
    final priorNetwork = HttpOverrides.current, network = _NoNetwork();
    HttpOverrides.global = network;
    // 输入组件会预初始化语音；本fixture不申请权限，显式模拟不可用。
    const speech = MethodChannel('plugin.csdcorp.com/speech_to_text');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            speech, (call) async => call.method == 'initialize' ? false : null);
    final storage =
        (await tester.runAsync(() => HiDBManager.instance(dbName: account)))!;
    final generation = ConversationGenerationService();
    await tester.runAsync(() => FavoriteDao.create(storage));
    final theme = ThemeProvider();
    final navigator = GlobalKey<NavigatorState>();
    final transport = _Transport();
    final ai = AISettings.defaults()
      ..mode = AIMode.local
      ..streamEnabled = true
      ..composerPredictionsEnabled = false
      ..webSearchEnabled = false
      ..activeProviderId = 'fixture'
      ..providers = [
        AiProvider(
            id: 'fixture',
            name: '隔离模型stub',
            type: 'openai',
            enabled: true,
            apiKey: 'synthetic',
            apiHost: 'https://example.invalid',
            selectedModelId: 'gpt-4o',
            models: [AiModel(id: 'gpt-4o')])
      ];
    await tester.runAsync(() => AISettingsDao.saveFor(account, ai));
    final settings = AISettingsProvider();
    await tester.runAsync(settings.load);
    expect(settings.accountHash, account);
    Future<T> io<T>(Future<T> Function() action) async => (await tester
        .runAsync(() => action().timeout(const Duration(seconds: 15)))) as T;
    Future<List<Map<String, Object?>>> rows(String table, int cid) =>
        io(() => storage.db
            .query(table, where: 'cid=?', whereArgs: [cid], orderBy: 'id'));
    ConversationDraftStore store(int cid) =>
        ConversationDraftStore(conversationId: '$cid', accountHash: account);
    MessageInputWidget input() =>
        tester.widget<MessageInputWidget>(find.byElementPredicate((e) =>
            e.widget is MessageInputWidget &&
            (ModalRoute.of(e)?.isCurrent ?? false)));
    Finder field() => find
        .descendant(
            of: find.byElementPredicate((e) =>
                e.widget is MessageInputWidget &&
                (ModalRoute.of(e)?.isCurrent ?? false)),
            matching: find.byType(TextField))
        .last;
    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.runAsync(() => tester.tap(target));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    }

    Future<void> screen(String name) async {
      await tester.pump(const Duration(milliseconds: 100));
      debugPrint('CONTINUITY_UI_SCREEN:$name');
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    }

    Future<void> mount(AppVisualStyle style) async {
      theme.setVisualStyle(style);
      await tester.runAsync(() => tester.pumpWidget(MultiProvider(
              providers: [
                ChangeNotifierProvider<ThemeProvider>.value(value: theme),
                ChangeNotifierProvider<AISettingsProvider>.value(
                    value: settings)
              ],
              child: Center(
                  child: SizedBox(
                      width: 320,
                      child: MaterialApp(
                          key: ValueKey(style),
                          navigatorKey: navigator,
                          navigatorObservers: [
                            ConversationGenerationRoutes.instance
                          ],
                          themeAnimationDuration: Duration.zero,
                          theme: style == AppVisualStyle.anime
                              ? AppThemeFactory.anime()
                              : AppThemeFactory.classic(Colors.blue),
                          home: const Scaffold(
                              body: SafeArea(
                                  child: Center(
                                      child: Text(
                                          '隔离合成会话列表\n普通模型stub；网络禁止'))))))))));
      await _idle(tester);
    }

    Future<void> open(int cid) async {
      final index = (await io(() => storage.db
              .query('tb_conversation_list', where: 'cid=?', whereArgs: [cid])))
          .single;
      final model = ConversationModel.fromJson(index);
      await tester.runAsync(() async {
        unawaited(navigator.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => ConversationPage(
                conversationModel: model,
                expectedAccountHash: account,
                generationService: generation,
                chatService: transport.chat(cid),
                draftStore: store(cid),
                readAloudService: const NoopReadAloudService()))));
        await tester.pump();
      });
      await _until(
          tester,
          () =>
              find.byType(MessageInputWidget).evaluate().isNotEmpty &&
              (input().enable || input().isStreaming));
      expect(tester.getSize(find.byType(ConversationPage)).width, 320);
      await _idle(tester);
    }

    Future<void> pop() async {
      await tester.runAsync(() async {
        navigator.currentState!.pop();
        await tester.pump();
      });
      await _idle(tester);
    }

    Future<void> keyboard(String text, String name) async {
      // 引用选择会主动focus；先关闭真实connection，再为输入注入建立新client。
      FocusManager.instance.primaryFocus?.unfocus();
      binding.focusedEditable = null;
      await _idle(tester);
      tester.testTextInput.register();
      await tester.enterText(field(), text);
      expect(input().controller!.text, text);
      FocusManager.instance.primaryFocus?.unfocus();
      binding.focusedEditable = null;
      tester.testTextInput.unregister();
      await _idle(tester);
      await tester.tap(field());
      // 先结算真实EditableText的focus/setClient，再请求系统键盘。
      await _idle(tester);
      final editable =
          find.descendant(of: field(), matching: find.byType(EditableText));
      tester.state<EditableTextState>(editable).requestKeyboard();
      await _idle(tester);
      debugPrint('CONTINUITY_UI_KEYBOARD_FOCUS:$name;focus='
          '${tester.widget<EditableText>(editable).focusNode.hasFocus};'
          'mock=${tester.testTextInput.isRegistered};inset=${tester.view.viewInsets.bottom}');
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      await _until(tester, () => tester.view.viewInsets.bottom > 0,
          seconds: 20);
      expect(tester.testTextInput.isRegistered, isFalse);
      expect(input().controller!.text, text);
      debugPrint(
          'CONTINUITY_UI_KEYBOARD:$name;width=320;inset=${tester.view.viewInsets.bottom};mock=false');
      await screen(name);
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await _until(tester, () => tester.view.viewInsets.bottom == 0);
    }

    Future<ConversationGenerationRun> send(String text) async {
      // 引用选择会主动focus；先关闭真实connection，再为输入注入建立新client。
      FocusManager.instance.primaryFocus?.unfocus();
      binding.focusedEditable = null;
      await _idle(tester);
      tester.testTextInput.register();
      await tester.enterText(field(), text);
      expect(input().controller!.text, text);
      FocusManager.instance.primaryFocus?.unfocus();
      tester.testTextInput.unregister();
      await _idle(tester);
      // 经典布局是MaterialButton图标，二次元布局才有tooltip。
      await tap(find.byTooltip('发送消息').evaluate().isNotEmpty
          ? find.byTooltip('发送消息')
          : find.ancestor(
              of: find.byIcon(Icons.send),
              matching: find.byType(MaterialButton)));
      final page =
          tester.widget<ConversationPage>(find.byType(ConversationPage));
      return generation.lookup(account, page.conversationModel.cid)!;
    }

    Future<void> finished(ConversationGenerationRun run,
        ConversationGenerationStage stage) async {
      var done = false;
      final future = run.finished.then((_) => done = true);
      await _until(tester, () => done);
      await future;
      expect(run.stage, stage);
      expect(run.ticket.released, isTrue);
      expect(run.retired, isFalse);
      expect(run.record!.state, stage.name);
    }

    Future<ComposerReference> reference() async =>
        ComposerReference.history((await io(() async {
          final candidates =
              await storage.db.query('tb_messages', where: 'cid=20999');
          return MessageReferenceDao(storage, accountHash: account)
              .snapshot(candidates.single['id'] as int);
        }))!);
    addTearDown(() async {
      transport.releaseAll();
      await tester.runAsync(() async {
        await Future.wait(generation.runs
                .where((r) => !r.retired)
                .map((r) => r.retire('native fixture completion')))
            .timeout(const Duration(seconds: 8));
        expect(generation.runs.every((r) => r.ticket.released), isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        generation.dispose();
        settings.dispose();
        theme.dispose();
        await HiDBManager.closeAll().timeout(const Duration(seconds: 5));
      });
      HttpOverrides.global = priorNetwork;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(speech, null);
      LoginSdkConfig.reset();
    });
    if (!restoring) {
      await io(() async {
        final index = await ConversationListDao.create(storage);
        for (final style in AppVisualStyle.values) {
          for (var i = 0; i < 3; i++) {
            final m = ConversationModel(
                cid: 21000 + style.index * 10 + i,
                title: '${style.name} ${['A', 'B', '确认停止'][i]}',
                icon: '',
                speechInputEnabled: false,
                readAloudEnabled: false,
                toolIds: i == 2 ? ['save_favorite'] : []);
            m.id = await index.saveConversation(m);
          }
        }
        await index.saveConversation(
            ConversationModel(cid: 20999, title: '合成引用资料', icon: ''));
        await (await MessageDao.create(storage, cid: 20999))
            .saveMessageWithBlocks(MessageModel(
                ownerType: OwnerType.receiver,
                content: '独立合成历史引用',
                createdAt: 1));
      });
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        final a = 21000 + style.index * 10, b = a + 1, c = a + 2;
        await mount(style);
        await open(a);
        await keyboard('A_NATIVE_${style.name}', '${style.name}-A-keyboard');
        input().onReferencePicked!(await reference());
        await _idle(tester);
        transport.hold(a);
        final runA = await send('A_NATIVE_${style.name}');
        await _until(
            tester,
            () =>
                transport.count(a) == 1 &&
                runA.dispatcher.mainText.contains('合成进度'));
        final source = runA.acceptedSourceRow!['memorySourceId'];
        await screen('${style.name}-A-generating');
        await pop();
        expect(runA.busy, isTrue);
        await open(b);
        await keyboard('B_NATIVE_${style.name}', '${style.name}-B-keyboard');
        final runB = await send('B_NATIVE_${style.name}');
        await finished(runB, ConversationGenerationStage.complete);
        expect(runA.busy, isTrue);
        expect(await rows('tb_messages', b), hasLength(2));
        expect(await rows('tb_usage', b), hasLength(1));
        input().onReferencePicked!(await reference());
        await keyboard(
            '未发送的新草稿 ${style.name}', '${style.name}-new-draft-keyboard');
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)));
        await _idle(tester);
        await pop();
        await open(a);
        expect(identical(generation.lookup(account, a), runA), isTrue);
        expect(runA.acceptedSourceRow!['memorySourceId'], source);
        expect(transport.count(a), 1);
        transport.release(a);
        await finished(runA, ConversationGenerationStage.complete);
        final saved = await rows('tb_messages', a);
        expect(saved, hasLength(2));
        expect(saved.first['memorySourceId'], source);
        expect(saved.last['content'], '合成进度 · 合成最终回复 $a');
        expect(await rows('tb_usage', a), hasLength(1));
        await screen('${style.name}-A-reconnected-complete');
        await pop();
        await open(b);
        expect(transport.count(b), 1);
        expect(input().controller!.text, '未发送的新草稿 ${style.name}');
        expect(input().references, hasLength(1));
        expect(input().references.single.available, isTrue);
        final newDraft = await io(store(b).load);
        expect(newDraft!.text, '未发送的新草稿 ${style.name}');
        expect(newDraft.references, hasLength(1));
        await screen('${style.name}-new-draft-restored');
        await pop();
        await open(c);
        final favoriteBefore =
            (await io(() => storage.db.query('tb_favorite'))).length;
        final tool = await send('TOOL_NATIVE_${style.name}');
        await _until(
            tester,
            () => find
                .byKey(const ValueKey('ordinary_confirm_action'))
                .evaluate()
                .isNotEmpty);
        expect(tool.stage, ConversationGenerationStage.awaitingConfirmation);
        expect((await io(() => storage.db.query('tb_favorite'))).length,
            favoriteBefore);
        await screen('${style.name}-visible-confirmation');
        await tap(find.byKey(const ValueKey('ordinary_confirm_action')));
        await finished(tool, ConversationGenerationStage.complete);
        expect((await io(() => storage.db.query('tb_favorite'))).length,
            favoriteBefore + 1);
        expect(transport.count(c), 2);
        expect(transport.requests.last['extra'], isNotEmpty);
        await screen('${style.name}-confirmed-tool-result');
        transport.hold(c);
        final stopped = await send('STOP_NATIVE_${style.name}');
        await _until(
            tester,
            () =>
                transport.count(c) == 3 &&
                stopped.dispatcher.mainText.contains('合成进度'));
        await tap(find.byTooltip('停止生成').evaluate().isNotEmpty
            ? find.byTooltip('停止生成')
            : find.ancestor(
                of: find.byIcon(Icons.stop),
                matching: find.byType(MaterialButton)));
        transport.release(c);
        await finished(stopped, ConversationGenerationStage.interrupted);
        expect(stopped.dispatcher.mainText, isNot(contains('合成最终回复')));
        expect((await rows('tb_messages', c)).last['content'],
            isNot(contains('合成最终回复')));
        expect(await rows('tb_usage', c), hasLength(2));
        await screen('${style.name}-stopped');
        debugPrint(
            'CONTINUITY_UI_VERIFIED:${style.name};A=1;B=1;tool=2;stop=1;requests=${transport.requests.length};network=${network.attempts};source=$source;runA=${runA.runId};stopRun=${stopped.runId};stopBeforeRestart=true');
        await pop();
      }
      final snapshot = <String, dynamic>{};
      for (final cid in [21000, 21001, 21002, 21010, 21011, 21012]) {
        snapshot['$cid'] = {
          'messages': await rows('tb_messages', cid),
          'usage': await rows('tb_usage', cid)
        };
      }
      await io(
          () => cache.prefs!.setString('saved_rows', jsonEncode(snapshot)));
      await io(() => cache.prefs!.setBool('restart_prepared', true));
      expect(transport.requests, hasLength(10));
      expect(network.attempts, 0);
      expect(tester.takeException(), isNull);
      debugPrint(
          'CONTINUITY_UI_RESTART_PREPARED:requests=10;network=0;allRunsSettled=true;inflightKill=false');
    } else {
      final expected = jsonDecode(cache.get('saved_rows') as String) as Map;
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        final a = 21000 + style.index * 10, b = a + 1, c = a + 2;
        await mount(style);
        await open(a);
        expect(transport.requests, isEmpty);
        for (final cid in [a, b, c]) {
          expect(await rows('tb_messages', cid), expected['$cid']['messages']);
          expect(await rows('tb_usage', cid), expected['$cid']['usage']);
        }
        await screen('${style.name}-reopened-complete');
        await pop();
        await open(b);
        expect(input().controller!.text, '未发送的新草稿 ${style.name}');
        expect(input().references, hasLength(1));
        expect(input().references.single.available, isTrue);
        await screen('${style.name}-reopened-new-draft');
        await pop();
        await open(c);
        expect((await rows('tb_messages', c)).last['content'], '合成进度');
        expect(transport.requests, isEmpty);
        await screen('${style.name}-reopened-interrupted');
        await pop();
      }
      debugPrint(
          'CONTINUITY_UI_REOPENED:requests=0;network=${network.attempts};rowsAndUsageUnchanged=true;interruptedNotReplayed=true');
      await mount(AppVisualStyle.anime);
      await open(21012);
      final fresh = await send('EXPLICIT_AFTER_RESTART');
      await finished(fresh, ConversationGenerationStage.complete);
      expect(transport.requests, hasLength(1));
      expect(await rows('tb_messages', 21012), hasLength(6));
      expect(await rows('tb_usage', 21012), hasLength(3));
      expect(network.attempts, 0);
      await screen('anime-explicit-after-restart');
      expect(tester.takeException(), isNull);
      debugPrint(
          'CONTINUITY_UI_RESTART_VERIFIED:reopened=0;explicit=1;network=0;inflightKill=false');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _idle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready,
    {int seconds = 15}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    if (ready()) {
      expect(tester.takeException(), isNull);
      return;
    }
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 40));
  }
  fail(
      'CONTINUITY_UI_TIMEOUT:${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join('|')}');
}

class _Transport {
  final requests = <Map<String, dynamic>>[];
  final gates = <int, Completer<void>>{};
  int count(int cid) => requests.where((r) => r['cid'] == cid).length;
  void hold(int cid) => gates[cid] = Completer<void>();
  void release(int cid) {
    final g = gates.remove(cid);
    if (g != null && !g.isCompleted) g.complete();
  }

  void releaseAll() {
    for (final cid in gates.keys.toList()) {
      release(cid);
    }
  }

  ChatService chat(int cid) => _Stub(this, cid);
}

class _Stub
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  final _Transport transport;
  final int cid;
  _Stub(this.transport, this.cid);
  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    final messages = await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt},
      ...extraMessages
    ]);
    transport.requests.add({
      'cid': cid,
      'messages': messages,
      'extra': extraMessages,
      'tools': tools
    });
    debugPrint(
        'CONTINUITY_UI_STUB_REQUEST:cid=$cid;count=${transport.count(cid)};extra=${extraMessages.length}');
    if (prompt.startsWith('TOOL_NATIVE') && extraMessages.isEmpty) {
      expect(
          tools!.any((t) => t['function']['name'] == 'save_favorite'), isTrue);
      yield StreamEvent.toolCall(
          toolId: 'native_call_$cid',
          name: 'save_favorite',
          arguments: {'content': '独立合成收藏 $cid'});
      return;
    }
    yield StreamEvent.text('合成进度');
    final gate = transport.gates[cid];
    if (gate != null) {
      await Future.any([
        gate.future,
        if (options.abortTrigger != null)
          options.abortTrigger!.then<void>((_) =>
              throw const ChatTransportException(
                  safeCode: 'cancelled',
                  safeMessage: '合成已取消',
                  failureKind: ChatFailureKind.cancelled))
      ]);
    }
    yield StreamEvent.text(' · 合成最终回复 $cid');
    yield StreamEvent.usage(promptTokens: 20, completionTokens: 8);
  }

  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          required ChatRequestOptions options}) =>
      throw StateError('本轮原生fixture仅验收已配置的流式路径');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Login implements TokenStorage {
  @override
  Map<String, dynamic> readProfileSync() => {
        'accountHash': account,
        'userName': '隔离合成用户',
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
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('普通聊天原生fixture禁止网络');
  }
}
