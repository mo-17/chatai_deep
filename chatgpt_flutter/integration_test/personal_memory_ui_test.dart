// 合成账号原生验收复用已有依赖，不新增插件或真实请求。
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'dart:ui' as ui;
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/personal_memory_model.dart';
import 'package:chatgpt_app_core/pages/personal_memory_page.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:chatgpt_app_core/widget/app_visual_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

const account = 'personal_memory_native_isolated_fixture';
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeSemantics(binding));
  testWidgets('个人记忆双布局原生 CRUD 与同容器进程恢复', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    SharedPreferences.setPrefix('chatai_personal_memory_native.');
    final cache = await HiCache.preInit();
    final restoring = cache.get('restart_prepared') == true;
    if (!restoring) await cache.prefs!.clear();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'example.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: FixtureLogin(),
        onLogoutNavigate: () {}));
    final previousNetwork = HttpOverrides.current;
    final network = NoNetwork();
    HttpOverrides.global = network;
    final storage = await HiDBManager.instance(dbName: account);
    final dao = await PersonalMemoryDao.create(storage, accountHash: account);
    await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 81, icon: '', title: '离线回答偏好来源'));
    final messages = await MessageDao.create(storage, cid: 81);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await HiDBManager.closeAll();
      LoginSdkConfig.reset();
      HttpOverrides.global = previousNetwork;
    });
    Future<void> open(AppVisualStyle style) async {
      await tester.pumpWidget(Center(
          child: SizedBox(
              width: 320,
              child: MaterialApp(
                  key: ValueKey(style),
                  themeAnimationDuration: Duration.zero,
                  theme: style == AppVisualStyle.anime
                      ? AppThemeFactory.anime()
                      : AppThemeFactory.classic(Colors.pink),
                  home: PersonalMemoryPage(dao: dao)))));
      await until(tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
      expect(tester.getSize(find.byType(PersonalMemoryPage)).width, 320);
    }

    Future<void> tap(Finder f) async {
      await tester.ensureVisible(f);
      await idle(tester);
      await tester.tap(f);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await until(tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    }

    Finder action(String content, String name) => find.descendant(
        of: find
            .ancestor(
                of: find.widgetWithText(SelectableText, content),
                matching: find.byType(AppVisualSurface))
            .first,
        matching: find.widgetWithText(TextButton, name));
    Future<void> edit(String content, String stage) async {
      final field = find.byKey(const ValueKey('personal-memory-editor'));
      tester.testTextInput.register();
      await tester.enterText(field, content);
      FocusManager.instance.primaryFocus?.unfocus();
      binding.focusedEditable = null;
      tester.testTextInput.unregister();
      await idle(tester);
      await tester.tap(field);
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      // Dialog 使用 AnimatedPadding 处理键盘后会移除正文的 viewInsets；
      // 与真实窗口一起检查其下方页面，而非误把弹窗正文的 0 当成键盘未出现。
      double pageInset() => MediaQuery.viewInsetsOf(
              tester.element(find.byType(PersonalMemoryPage)))
          .bottom;
      await until(
          tester, () => tester.view.viewInsets.bottom > 0 && pageInset() > 0,
          attempts: 450);
      final inset = pageInset();
      expect(inset, greaterThan(0));
      expect(tester.getSize(find.byType(AlertDialog)).width,
          lessThanOrEqualTo(320));
      debugPrint('PERSONAL_MEMORY_UI_KEYBOARD:$stage;inset=$inset;width=320;'
          'native-inset=${tester.view.viewInsets.bottom};'
          'mock=${tester.testTextInput.isRegistered}');
      await screen(tester, '$stage-keyboard');
      await tap(find.widgetWithText(FilledButton, '保存'));
      await idle(tester);
    }

    if (!restoring) {
      for (final row in await dao.list()) {
        await dao.delete(row);
      }
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        await open(style);
        final p = await dao.preferences();
        if (p.enabled) {
          await tap(find.byKey(const ValueKey('personal-memory-enabled')));
        }
        expect((await dao.preferences()).enabled, isFalse);
        await screen(tester, '${style.name}-scope-disabled');
        await tap(find.byTooltip('新增个人记忆'));
        await edit('合成个人偏好 ${style.name}', '${style.name}-new');
        await tap(action('合成个人偏好 ${style.name}', '编辑'));
        final content = '回答时优先给简短说明 ${style.name}';
        await edit(content, '${style.name}-edit');
        await tap(action(content, '停用'));
        expect(
            (await dao.list()).firstWhere((m) => m.content == content).status,
            PersonalMemoryStatus.archived);
        await screen(tester, '${style.name}-archived');
        await tap(action(content, '启用'));
        expect(
            (await dao.list()).firstWhere((m) => m.content == content).status,
            PersonalMemoryStatus.active);
        await tap(find.byKey(const ValueKey('personal-memory-enabled')));
        expect(find.textContaining('当前配置的模型服务'), findsOneWidget);
        await screen(tester, '${style.name}-model-disclosure');
        await tap(find.widgetWithText(FilledButton, '确认'));
        await tap(find.byKey(const ValueKey('personal-memory-suggestions')));
        expect(find.textContaining('固定的回答风格和语言偏好'), findsOneWidget);
        await screen(tester, '${style.name}-suggestion-disclosure');
        await tap(find.widgetWithText(FilledButton, '确认'));
        expect((await dao.preferences()).suggestionsEnabled, isTrue);
        await tap(action(content, '删除'));
        await tap(find.widgetWithText(FilledButton, '确认'));
        expect((await dao.list()).where((m) => m.content == content), isEmpty);
        final raw = style == AppVisualStyle.classic ? '我希望回答简短清楚' : '我希望回答详细';
        final time = DateTime.now().millisecondsSinceEpoch;
        final turn = (await dao.beginTurn(
            cid: 81,
            assistantId: null,
            taskMode: false,
            rawInput: raw,
            startedAt: time))!;
        await messages.saveMessageWithBlocks(MessageModel(
            ownerType: OwnerType.sender, content: raw, createdAt: time));
        await messages.saveMessageWithBlocks(MessageModel(
            ownerType: OwnerType.receiver,
            content: '已保存的离线合成回复',
            createdAt: time + 1));
        await dao.suggestAfterPersist(turn,
            userCreatedAt: time, replyCreatedAt: time + 1);
        await tap(find.byTooltip('刷新记忆'));
        final candidate = (await dao.list())
            .singleWhere((m) => m.status == PersonalMemoryStatus.pending);
        expect(candidate.content, raw);
        expect(find.textContaining(candidate.sourceMessageId), findsOneWidget);
        await screen(tester, '${style.name}-candidate-source');
        await tap(action(raw, '确认'));
        final confirmed = '确认后的回答偏好 ${style.name}';
        await edit(confirmed, '${style.name}-confirm');
        expect(
            (await dao.list())
                .singleWhere((m) => m.memoryId == candidate.memoryId)
                .confirmedByUser,
            isTrue);
        await screen(tester, '${style.name}-confirmed');
      }
      final rows = await dao.list();
      expect(rows, hasLength(2));
      await cache.setString(
          'restart_ids', rows.map((m) => m.memoryId).join('|'));
      await cache.setString(
          'restart_sources', rows.map((m) => m.sourceMessageId).join('|'));
      await cache.prefs!.setBool('restart_prepared', true);
      expect(network.attempts, 0);
      expect(tester.takeException(), isNull);
      debugPrint(
          'PERSONAL_MEMORY_UI_RESTART_PREPARED:rows=2;requests=0;network=0');
    } else {
      final p = await dao.preferences();
      expect(p.enabled, isTrue);
      expect(p.suggestionsEnabled, isTrue);
      final rows = await dao.list();
      expect(rows, hasLength(2));
      expect(rows.map((m) => m.memoryId).join('|'), cache.get('restart_ids'));
      expect(rows.map((m) => m.sourceMessageId).join('|'),
          cache.get('restart_sources'));
      expect(
          rows.every((m) =>
              m.status == PersonalMemoryStatus.active && m.confirmedByUser),
          isTrue);
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        await open(style);
        expect(find.text('确认后的回答偏好 classic'), findsOneWidget);
        expect(find.text('确认后的回答偏好 anime'), findsOneWidget);
        await screen(tester, '${style.name}-process-restored');
      }
      await tap(find.byKey(const ValueKey('personal-memory-enabled')));
      expect((await dao.preferences()).enabled, isFalse);
      expect(
          await dao.requestContext(cid: 81, assistantId: null, taskMode: false),
          isEmpty);
      await screen(tester, 'anime-restored-disabled');
      expect(network.attempts, 0);
      expect(tester.takeException(), isNull);
      debugPrint(
          'PERSONAL_MEMORY_UI_RESTART_VERIFIED:rows=2;flags-persisted=true;'
          'source-identity-persisted=true;requests=0;network=0');
    }
  }, timeout: const Timeout(Duration(minutes: 7)));
}

Future<void> initializeSemantics(
    IntegrationTestWidgetsFlutterBinding binding) async {
  final previous = binding.framePolicy;
  final owned = binding.ensureSemantics();
  debugPrint(
      'PERSONAL_MEMORY_UI_SEMANTICS_WARMUP:owned=${identityHashCode(owned)};'
      'count=${binding.debugOutstandingSemanticsHandles};'
      'native=${ui.PlatformDispatcher.instance.semanticsEnabled}');
  try {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    runApp(
        const MaterialApp(home: Scaffold(body: SafeArea(child: TextField()))));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ui.PlatformDispatcher.instance.semanticsEnabled &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ui.PlatformDispatcher.instance.semanticsEnabled, isTrue);
    expect(binding.platformDispatcher.semanticsEnabled, isTrue);
    runApp(const SizedBox.shrink());
    await binding.endOfFrame.timeout(const Duration(seconds: 3));
  } finally {
    owned.dispose();
    binding.framePolicy = previous;
    debugPrint('PERSONAL_MEMORY_UI_SEMANTICS_READY:count='
        '${binding.debugOutstandingSemanticsHandles};'
        'native=${ui.PlatformDispatcher.instance.semanticsEnabled}');
  }
}

Future<void> idle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> until(WidgetTester tester, bool Function() ready,
    {int attempts = 150}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  throw TestFailure('个人记忆离线验收状态超时');
}

Future<void> screen(WidgetTester tester, String stage) async {
  await idle(tester);
  debugPrint('PERSONAL_MEMORY_UI_SCREEN:$stage');
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
}

final class FixtureLogin implements TokenStorage {
  @override
  Map<String, dynamic> readProfileSync() => {
        'accountHash': account,
        'guest': true,
        'userName': '离线合成用户',
        'avatar': '',
        'boardingPass': 'guest-mode'
      };
  @override
  Future<Map<String, dynamic>?> readProfile() async => readProfileSync();
  @override
  String readTokenSync() => 'guest-mode';
  @override
  Future<String?> readToken() async => readTokenSync();
  @override
  Future<void> clear() async {}
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {}
}

final class NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('合成个人记忆验收禁止网络');
  }
}
