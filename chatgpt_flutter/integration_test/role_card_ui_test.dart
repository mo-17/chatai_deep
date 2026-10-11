import 'package:chatgpt_app_core/provider/theme_provider.dart';
// 合成账号验收：系统文件选择结果固定，解析/预览/真实DAO/页面/文件均走生产路径。
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_role_card_context.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_list_page.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../chatgpt_app_core/test/support/role_card_file_picker.dart';
import 'personal_memory_ui_test.dart' as harness
    show initializeSemantics, idle, until;

const account = 'role_card_native_isolated_fixture';
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => harness.initializeSemantics(binding));
  testWidgets('角色卡双布局320pt导入编辑世界书再导入及同容器恢复', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    SharedPreferences.setPrefix('chatai_role_card_native.');
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
    final previousPicker = FilePickerPlatform.instance;
    final picker = RoleCardFixtureFilePicker();
    FilePickerPlatform.instance = picker;
    final storage = await HiDBManager.instance(dbName: account);
    final dao = await AssistantDao.create(storage);
    final roomDao = await StoryRoomDao.create(storage);
    debugPrint('ROLE_CARD_UI_INIT:database-ready');
    final settings = AISettingsProvider();
    final theme = ThemeProvider();
    debugPrint('ROLE_CARD_UI_INIT:providers-ready');
    final temp = Directory.systemTemp.createTempSync('role-card-native-');
    debugPrint('ROLE_CARD_UI_INIT:temp-ready');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      theme.dispose();
      FilePickerPlatform.instance = previousPicker;
      await HiDBManager.closeAll();
      LoginSdkConfig.reset();
      HttpOverrides.global = previousNetwork;
      await tester.runAsync(() => temp.delete(recursive: true));
    });
    Future<void> open(AppVisualStyle style, Widget home) async {
      await tester.pumpWidget(Center(
          child: SizedBox(
              width: 320,
              child: ChangeNotifierProvider<AISettingsProvider>.value(
                  value: settings,
                  child: ChangeNotifierProvider<ThemeProvider>.value(
                      value: theme,
                      child: MaterialApp(
                          key: ValueKey('$style-${identityHashCode(home)}'),
                          themeAnimationDuration: Duration.zero,
                          theme: style == AppVisualStyle.anime
                              ? AppThemeFactory.anime()
                              : AppThemeFactory.classic(Colors.pink),
                          home: home))))));
      await harness.idle(tester);
    }

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await harness.idle(tester);
      await tester.tap(finder);
      await tester.pump();
      await harness.idle(tester);
    }

    Future<void> rowsReady(bool Function(List<AssistantModel>) ready) async {
      for (var i = 0; i < 300; i++) {
        final rows = await tester.runAsync(dao.getAssistants);
        if (ready(rows!)) return;
        await tester.pump(const Duration(milliseconds: 100));
      }
      throw TestFailure('角色卡数据库状态超时');
    }

    Future<void> screen(String stage) async {
      await harness.idle(tester);
      debugPrint('ROLE_CARD_UI_SCREEN:$stage');
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
    }

    Future<void> keyboard(Finder field, String text, String stage) async {
      await tester.ensureVisible(field);
      tester.testTextInput.register();
      await tester.enterText(field, text);
      FocusManager.instance.primaryFocus?.unfocus();
      binding.focusedEditable = null;
      tester.testTextInput.unregister();
      await harness.idle(tester);
      await tester.tap(field);
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      await harness.until(tester, () => tester.view.viewInsets.bottom > 0,
          attempts: 450);
      expect(tester.testTextInput.isRegistered, isFalse);
      debugPrint(
          'ROLE_CARD_UI_KEYBOARD:$stage;native=${tester.view.viewInsets.bottom};width=320;mock=false');
      await screen('$stage-keyboard');
      FocusManager.instance.primaryFocus?.unfocus();
      await harness.until(tester, () => tester.view.viewInsets.bottom == 0,
          attempts: 100);
    }

    Future<void> importFile(
        AppVisualStyle style, File file, String stage, int expectedRows) async {
      debugPrint('ROLE_CARD_UI_STAGE:$stage:before-open');
      await open(style, const AssistantListPage());
      debugPrint('ROLE_CARD_UI_STAGE:$stage:page-open');
      final button = find.byWidgetPredicate((w) =>
          w is IconButton && w.tooltip == '导入角色卡（.json/.png/.zip/.charx）');
      await harness.until(
          tester,
          () =>
              button.evaluate().isNotEmpty &&
              tester.widget<IconButton>(button).onPressed != null);
      picker.choose = () async => RoleCardFixtureFilePicker.selected(file.path);
      debugPrint('ROLE_CARD_UI_STAGE:$stage:button-ready');
      await tester.runAsync(() async {
        // 仅启动真实回调，不返回它等待用户确认的 Future。
        tester.widget<IconButton>(button).onPressed!();
      });
      debugPrint('ROLE_CARD_UI_STAGE:$stage:callback-started');
      await harness.until(
          tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
      debugPrint('ROLE_CARD_UI_STAGE:$stage:dialog-open');
      expect(picker.allowed, contains('charx'));
      await screen('$stage-preview');
      await tap(find.widgetWithText(FilledButton, '导入'));
      await rowsReady((rows) => rows.length == expectedRows);
      await screen('$stage-imported');
    }

    Future<void> route(AppVisualStyle style, Widget page) async {
      await open(
          style,
          Builder(
              builder: (ctx) => Scaffold(
                  body: SafeArea(
                      child: Center(
                          child: TextButton(
                              onPressed: () => Navigator.of(ctx).push(
                                  MaterialPageRoute(builder: (_) => page)),
                              child: const Text('打开验收页')))))));
      await tap(find.text('打开验收页'));
      await harness.idle(tester);
    }

    Future<T> real<T extends Object>(Future<T> Function() action) async =>
        (await tester
            .runAsync(() => action().timeout(const Duration(seconds: 20))))!;
    Future<List<AssistantModel>> assistants() => real(dao.getAssistants);
    Future<List<StoryRoomModel>> rooms() => real(roomDao.getRooms);
    debugPrint('ROLE_CARD_UI_INIT:branch=$restoring');
    if (!restoring) {
      for (final row in await assistants()) {
        await tester.runAsync(() => dao.deleteAssistant(row.id!));
      }
      debugPrint('ROLE_CARD_UI_STAGE:reset-complete');
      var count = 0;
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        final card = AssistantRoleCardService.importJson(jsonEncode({
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
          'data': {
            'name': '合成角色 ${style.name}',
            'description': '雨夜书店里安静观察的角色。',
            'creator': '本地合成作者',
            'character_version': '1.2',
            'tags': ['本地合成'],
            'creator_notes': '只用于展示的原卡说明。',
            'extensions': {
              'future_card': {'kept': true},
              'depth_prompt': {
                'prompt': '保持雨夜场景。',
                'depth': 1,
                'role': 'system'
              }
            },
            'character_book': {
              'name': '合成世界书',
              'extensions': {'future_book': true},
              'entries': [
                {
                  'id': 7,
                  'keys': ['钟声'],
                  'content': '原设定',
                  'enabled': true,
                  'insertion_order': 0,
                  'extensions': {'future_entry': true}
                }
              ]
            }
          }
        }));
        debugPrint('ROLE_CARD_UI_STAGE:${style.name}:codec-complete');
        final selected = File('${temp.path}/${style.name}.charx');
        selected.writeAsBytesSync(AssistantRoleCardService.exportCharx(card));
        await importFile(style, selected, '${style.name}-first', ++count);
        var loaded =
            (await assistants()).firstWhere((a) => a.name == card.name);
        final beforeJson = loaded.worldBookJson;
        await route(style, AssistantEditPage(assistant: loaded));
        await keyboard(find.widgetWithText(TextField, '名称'),
            '已编辑 ${style.name}', '${style.name}-edit');
        final save = find.byWidgetPredicate((w) =>
            w is FilledButton &&
            w.child is Text &&
            (w.child as Text).data == '保存修改');
        // FilledButton.icon 的 child 是内部组合，按可见文字寻找该原生按钮。
        final actualSave = find
            .ancestor(
                of: find.text('保存修改'),
                matching: find.byWidgetPredicate((w) => w is FilledButton))
            .first;
        if (save.evaluate().isNotEmpty) {
          await tap(save);
        } else {
          await tap(actualSave);
        }
        await rowsReady(
            (rows) => rows.any((a) => a.name == '已编辑 ${style.name}'));
        loaded = (await assistants())
            .firstWhere((a) => a.name == '已编辑 ${style.name}');
        expect(loaded.worldBookJson, beforeJson);
        await route(style, AssistantWorldBookPage(assistant: loaded));
        await harness.until(
            tester, () => find.text('原设定').evaluate().isNotEmpty);
        await tap(find.text('原设定'));
        await keyboard(find.widgetWithText(TextField, '设定内容'),
            '已编辑世界书 ${style.name}', '${style.name}-worldbook');
        await tap(find.widgetWithText(FilledButton, '保存'));
        await rowsReady((rows) => rows.any((a) =>
            WorldBookCodec.decode(structuredJson: a.worldBookJson)
                .any((e) => e.content == '已编辑世界书 ${style.name}')));
        await screen('${style.name}-worldbook-saved');
        loaded = (await assistants())
            .firstWhere((a) => a.name == '已编辑 ${style.name}');
        final raw = jsonDecode(
            AssistantRoleCardService.exportTavernV2Json(loaded))['data'];
        expect(raw['extensions']['future_card']['kept'], true);
        expect(raw['character_book']['extensions']['future_book'], true);
        expect(
            raw['character_book']['entries'][0]['extensions']['future_entry'],
            true);
        final exported = File('${temp.path}/${style.name}-export.charx');
        exported.writeAsBytesSync(AssistantRoleCardService.exportCharx(loaded));
        await importFile(style, exported, '${style.name}-roundtrip', ++count);
        final source = (await assistants())
            .firstWhere((a) => a.name == '已编辑 ${style.name}');
        await real(() => StoryRoomRoleCardImportService(roomDao)
            .importAsTavernRoom(source, title: '合成房间 ${style.name}'));
        debugPrint(
            'ROLE_CARD_UI_VERIFIED:${style.name};rows=$count;network=${network.attempts};requests=0;raw-preserved=true');
      }
      await cache.setBool('restart_prepared', true);
      expect((await assistants()).length, 4);
      expect((await rooms()).length, 2);
      expect(network.attempts, 0);
      debugPrint(
          'ROLE_CARD_UI_RESTART_PREPARED:rows=4;rooms=2;network=0;requests=0');
    } else {
      final rows = await assistants();
      expect(rows.length, 4);
      expect(picker.calls, 0);
      for (final style in [AppVisualStyle.classic, AppVisualStyle.anime]) {
        final row = rows.firstWhere((a) => a.name == '已编辑 ${style.name}');
        expect(
            WorldBookCodec.decode(structuredJson: row.worldBookJson)
                .single
                .content,
            '已编辑世界书 ${style.name}');
        expect(AssistantRoleCardService.exportTavernV2Json(row),
            contains('future_card'));
        await route(style, AssistantProfilePage(assistant: row));
        await screen('${style.name}-restored-profile');
        await route(style, AssistantWorldBookPage(assistant: row));
        await harness.until(tester,
            () => find.text('已编辑世界书 ${style.name}').evaluate().isNotEmpty);
        await screen('${style.name}-restored-worldbook');
        final room =
            (await rooms()).firstWhere((r) => r.title == '合成房间 ${style.name}');
        final participants =
            await real(() => roomDao.getParticipants(room.id!));
        expect(
            StoryRoleCardContext.read(room, participants: participants).valid,
            isTrue);
        await open(style, StoryRoomPage(room: room));
        await harness.until(tester,
            () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
        expect(find.text(StoryRoleCardContext.unavailableNotice), findsNothing);
        await screen('${style.name}-restored-room');
      }
      expect(network.attempts, 0);
      debugPrint(
          'ROLE_CARD_UI_RESTART_VERIFIED:rows=4;rooms=2;picker=0;network=0;requests=0');
    }
  }, timeout: const Timeout(Duration(minutes: 9)));
}

final class NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('角色卡合成验收禁止网络');
  }
}

final class FixtureLogin implements TokenStorage {
  @override
  Map<String, dynamic> readProfileSync() => {
        'accountHash': account,
        'guest': true,
        'userName': '角色卡合成用户',
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
