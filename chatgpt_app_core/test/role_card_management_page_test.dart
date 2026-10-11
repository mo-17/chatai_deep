import 'package:chatgpt_app_core/provider/theme_provider.dart';
import 'package:chatgpt_app_core/chat/application/story_role_card_context.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/pages/story_room_page.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/assistant_operation_scope.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:chatgpt_app_core/pages/assistant_edit_page.dart';
import 'package:chatgpt_app_core/pages/assistant_profile_page.dart';
import 'package:chatgpt_app_core/pages/assistant_world_book_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:chatgpt_app_core/theme/app_visual_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

AssistantModel card() => AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '合成角色',
        'description': '人设',
        'personality': '',
        'scenario': '',
        'first_mes': '',
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': [],
        'creator_notes': '',
        'tags': ['保留标签'],
        'creator': '合成作者',
        'character_version': '1',
        'extensions': {'future_card': 7},
        'character_book': {
          'name': '合成书',
          'extensions': {'future_book': true},
          'entries': [
            {
              'id': 1,
              'keys': ['钟声'],
              'content': '旧设定',
              'enabled': true,
              'insertion_order': 0,
              'extensions': {
                'future_entry': {
                  'tags': ['保留']
                }
              }
            }
          ]
        }
      }
    }))
      ..id = 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String account;
  late int restore;
  AssistantOperationScope scope() => AssistantOperationScope(
      accountHash: account,
      restoreRevision: restore,
      currentAccount: () => account,
      currentRestoreRevision: () => restore);
  setUp(() async {
    account = 'synthetic';
    restore = 0;
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });
  Future<void> edit(WidgetTester tester, AssistantModel source,
      Future<void> Function(AssistantModel) save,
      {bool anime = false}) async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (_) async => Directory.systemTemp.path);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ChangeNotifierProvider<AISettingsProvider>.value(
        value: AISettingsProvider(),
        child: MaterialApp(
            theme: anime ? AppThemeFactory.anime() : ThemeData.light(),
            themeAnimationDuration: Duration.zero,
            initialRoute: '/edit',
            routes: {
              '/': (_) => const Scaffold(body: Text('list')),
              '/edit': (_) => AssistantEditPage(
                  assistant: source,
                  operationScope: scope(),
                  saveAssistant: save),
            })));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'editor worldbook action catches expired restore scope without mutation',
      (tester) async {
    final source = card();
    final before = source.toJson();
    var saves = 0;
    await edit(tester, source, (_) async {
      saves++;
    });
    restore++;
    // 使用页面实际世界书入口，过期异常应显示而不是逃出 async 回调。
    final header = find.text('关键词记忆 / 世界书');
    await tester.scrollUntilVisible(header, 400,
        scrollable: find.byType(Scrollable).first);
    final tile =
        find.ancestor(of: header, matching: find.byType(ListTile)).first;
    tester.widget<ListTile>(tile).onTap!();
    await tester.pumpAndSettle();
    final entry = find.text('编辑结构化世界书');
    expect(entry, findsOneWidget);
    final action = find
        .ancestor(
            of: entry, matching: find.byWidgetPredicate((w) => w is TextButton))
        .first;
    tester.widget<TextButton>(action).onPressed!();
    await tester.pumpAndSettle();
    expect(find.textContaining('无法打开世界书'), findsOneWidget);
    expect(find.byType(AssistantWorldBookPage), findsNothing);
    expect(source.toJson(), before);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });
  Finder saveButton() => find.ancestor(
      of: find.text('保存修改'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton));

  for (final anime in [false, true]) {
    testWidgets(
        'rename preserves structured raw metadata ${anime ? 'anime' : 'classic'}',
        (tester) async {
      final source = card();
      final before = source.toJson();
      final gate = Completer<void>();
      AssistantModel? candidate;
      await edit(tester, source, (copy) async {
        candidate = copy;
        await gate.future;
      }, anime: anime);
      await tester.enterText(find.widgetWithText(TextField, '名称'), '新姓名');
      await tester.tap(saveButton());
      await tester.pump();
      expect(source.toJson(), before);
      expect(candidate!.worldBookJson, before['worldBookJson']);
      expect(candidate!.memoryBook, before['memoryBook']);
      expect(tester.widget<FilledButton>(saveButton()).onPressed, isNull);
      gate.complete();
      await tester.pumpAndSettle();
      expect(source.name, '新姓名');
      final exported = jsonDecode(
          AssistantRoleCardService.exportTavernV2Json(source))['data'];
      expect(exported['creator'], '合成作者');
      expect(exported['extensions']['future_card'], 7);
      expect(exported['character_book']['extensions']['future_book'], true);
      expect(
          exported['character_book']['entries'][0]['extensions']
              ['future_entry'],
          {
            'tags': ['保留']
          });
      expect(find.text('list'), findsOneWidget);
    });
  }
  for (final expired in ['account', 'restore', 'failure']) {
    testWidgets('pending edit $expired keeps original and recovers save button',
        (tester) async {
      final source = card();
      final before = source.toJson();
      final gate = Completer<void>();
      await edit(tester, source, (_) => gate.future);
      await tester.enterText(find.widgetWithText(TextField, '名称'), '未保存');
      await tester.tap(saveButton());
      await tester.pump();
      if (expired == 'account') account = 'other';
      if (expired == 'restore') restore++;
      if (expired == 'failure') {
        gate.completeError(StateError('synthetic DB failure'));
      } else {
        gate.complete();
      }
      await tester.pumpAndSettle();
      expect(source.toJson(), before);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(tester.widget<FilledButton>(saveButton()).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('worldbook edit preserves IDs and nested metadata after success',
      (tester) async {
    final source = card();
    final id =
        WorldBookCodec.decode(structuredJson: source.worldBookJson).single.id;
    await tester.pumpWidget(MaterialApp(
        home: AssistantWorldBookPage(
            assistant: source, operationScope: scope(), onSave: (_) async {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧设定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '新设定');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(
        WorldBookCodec.decode(structuredJson: source.worldBookJson).single.id,
        id);
    final exported =
        jsonDecode(AssistantRoleCardService.exportTavernV2Json(source))['data']
            ['character_book'];
    expect(exported['extensions']['future_book'], true);
    expect(exported['entries'][0]['content'], '新设定');
    expect(exported['entries'][0]['extensions']['future_entry'], {
      'tags': ['保留']
    });
  });
  testWidgets(
      'worldbook failed write retains model, entry and enabled controls',
      (tester) async {
    final source = card();
    final before = source.toJson();
    await tester.pumpWidget(MaterialApp(
        home: AssistantWorldBookPage(
            assistant: source,
            operationScope: scope(),
            onSave: (_) async => throw StateError('synthetic write failure'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧设定'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '设定内容'), '未保存');
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存'));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(source.toJson(), before);
    expect(find.text('旧设定'), findsOneWidget);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'damaged old carrier profile is readable and editor refuses overwrite',
      (tester) async {
    final source = AssistantModel(
        id: 1,
        name: '旧卡',
        memoryBook: '# [chatai_deep.tavern_raw.v1] broken-base64');
    await tester.pumpWidget(MaterialApp(
        home:
            AssistantProfilePage(assistant: source, operationScope: scope())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    var saves = 0;
    final before = source.toJson();
    await edit(tester, source, (_) async {
      saves++;
    });
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(source.toJson(), before);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'legacy role source shows visible degradation without cleaning saved public text',
      (tester) async {
    final room = StoryRoomModel(
        id: 1,
        title: '旧房间',
        mode: StoryRoomMode.tavern,
        publicContext: '【角色卡：合成】\n【角色简介】\n作者备注标签\n【Tavern 原卡信息】\n作者备注：私人描述');
    final original = room.toJson();
    final settings = AISettingsProvider();
    await tester.pumpWidget(ChangeNotifierProvider<AISettingsProvider>.value(
        value: settings,
        child: ChangeNotifierProvider(
            create: (_) => ThemeProvider(),
            child: MaterialApp(
                home: StoryRoomPage(
                    room: room, skipInitialLoadForTesting: true)))));
    await tester.pumpAndSettle();
    expect(find.text(StoryRoleCardContext.unavailableNotice), findsOneWidget);
    expect(room.toJson(), original);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    expect(tester.takeException(), isNull);
  });
}
