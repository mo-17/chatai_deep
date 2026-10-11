import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/world_book.dart';
import 'package:chatgpt_app_core/pages/assistant_list_page.dart';
import 'package:chatgpt_app_core/provider/ai_settings_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/personal_memory_test_support.dart';
import 'support/role_card_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late DatabaseFactory? previous;
  late FilePickerPlatform previousPicker;
  late Directory root;
  late HiDBManager storage;
  late AssistantDao dao;
  late PersonalMemoryTestAccount login;
  late RoleCardFixtureFilePicker picker;
  late AISettingsProvider settings;
  var serial = 0;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('role-list-');
    previous = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath('${root.path}/db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => root.path);
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    login = PersonalMemoryTestAccount('role-fixture-${serial++}')..install();
    storage = await HiDBManager.instance(dbName: login.account);
    dao = await AssistantDao.create(storage);
    settings = AISettingsProvider();
    previousPicker = FilePickerPlatform.instance;
    picker = RoleCardFixtureFilePicker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() async {
    FilePickerPlatform.instance = previousPicker;
    await HiDBManager.closeAll();
    settings.dispose();
    LoginSdkConfig.reset();
    databaseFactory = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await root.delete(recursive: true);
  });
  Future<void> pumpUntil(WidgetTester tester, bool Function() complete) async {
    for (var i = 0; i < 200; i++) {
      if (complete()) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('bounded page wait timed out');
  }

  Future<void> page(WidgetTester tester) async {
    await tester.pumpWidget(ChangeNotifierProvider<AISettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
            themeAnimationDuration: Duration.zero, home: AssistantListPage())));
    await pumpUntil(
        tester,
        () =>
            tester
                .widget<IconButton>(find.byWidgetPredicate((w) =>
                    w is IconButton &&
                    w.tooltip == '导入角色卡（.json/.png/.zip/.charx）'))
                .onPressed !=
            null);
  }

  Future<void> select(WidgetTester tester, AssistantModel model) async {
    final file = File('${root.path}/synthetic.json');
    await tester.runAsync(
        () => file.writeAsString(AssistantRoleCardService.exportJson(model)));
    picker.choose = () async => RoleCardFixtureFilePicker.selected(file.path);
    await tester.runAsync(() async {
      tester
          .widget<IconButton>(find.byWidgetPredicate((w) =>
              w is IconButton && w.tooltip == '导入角色卡（.json/.png/.zip/.charx）'))
          .onPressed!();
    });
    await pumpUntil(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    expect(picker.allowed, contains('charx'));
  }

  Future<void> rowsReady(WidgetTester tester, int count,
      {String? prompt}) async {
    for (var i = 0; i < 200; i++) {
      final rows = await tester.runAsync(dao.getAssistants);
      if (rows!.length == count &&
          (prompt == null || rows.first.prompt == prompt)) {
        return;
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    fail('bounded database wait timed out');
  }

  Future<void> confirm(WidgetTester tester) async {
    // 让实际 SQLite 事务在真实 async zone 开始，避免查询等待时 FakeAsync 阻塞事务续步。
    await tester
        .runAsync(() => tester.tap(find.widgetWithText(FilledButton, '导入')));
    await tester.pump();
  }

  AssistantModel incoming() => AssistantModel(
      name: '角色',
      prompt: '新正文',
      memoryBook: '门 => 新设定',
      useTools: true,
      model: '外部模型');

  testWidgets('actual import new/name conflict rename and cancel',
      (tester) async {
    await page(tester);
    await select(tester, incoming());
    await confirm(tester);
    await pumpUntil(
        tester,
        () =>
            find.text('角色').evaluate().isNotEmpty &&
            find.byType(AlertDialog).evaluate().isEmpty);
    await rowsReady(tester, 1);
    expect((await tester.runAsync(dao.getAssistants))!.single.model, '');
    await select(tester, incoming());
    await confirm(tester);
    await pumpUntil(tester, () => find.text('角色 (2)').evaluate().isNotEmpty);
    await rowsReady(tester, 2);
    expect((await tester.runAsync(dao.getAssistants))!.length, 2);
    await select(tester, incoming());
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(dao.getAssistants))!.length, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'actual overwrite merge updates effective JSON, keeps local settings and binding ID',
      (tester) async {
    final old = AssistantModel(
        name: '角色',
        prompt: '旧正文',
        memoryBook: '钟声 => 旧设定',
        model: '本地模型',
        useTools: false,
        toolIds: ['calculator'],
        defaultVoiceStyle: 'local');
    await tester.runAsync(() => dao.saveAssistant(old));
    await page(tester);
    await select(tester, incoming());
    await tester.ensureVisible(find.text('覆盖并合并世界书'));
    await tester.tap(find.text('覆盖并合并世界书'));
    await tester.pump();
    await confirm(tester);
    await pumpUntil(
        tester,
        () =>
            find.byType(AlertDialog).evaluate().isEmpty &&
            find.text('角色').evaluate().isNotEmpty);
    await rowsReady(tester, 1, prompt: '新正文');
    AssistantModel? saved;
    for (var i = 0; i < 100; i++) {
      saved = await tester
          .runAsync<AssistantModel?>(() => dao.getAssistant(old.id!));
      if (saved!.prompt == '新正文') break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(saved!.id, old.id);
    expect(saved.model, '本地模型');
    expect(saved.useTools, false);
    expect(saved.toolIds, ['calculator']);
    expect(saved.defaultVoiceStyle, 'local');
    expect(
        WorldBookCodec.decode(structuredJson: saved.worldBookJson)
            .map((e) => e.content),
        containsAll(['旧设定', '新设定']));
    expect(AssistantRoleCardService.exportTavernV2Json(saved), contains('旧设定'));
    expect(tester.takeException(), isNull);
  });
  for (final change in ['account', 'restore', 'target']) {
    testWidgets('preview then $change rejects stale overwrite and keeps target',
        (tester) async {
      final old = AssistantModel(name: '角色', prompt: '原正文');
      await tester.runAsync(() => dao.saveAssistant(old));
      await page(tester);
      await select(tester, incoming());
      await tester.ensureVisible(find.text('覆盖同名角色'));
      await tester.tap(find.text('覆盖同名角色'));
      await tester.pump();
      if (change == 'account') login.account = 'another';
      if (change == 'restore') BackupService.restoreTick.value++;
      if (change == 'target') {
        await tester.runAsync(() => storage.db.update(
            'tb_assistant', {'prompt': '其他编辑'},
            where: 'id = ?', whereArgs: [old.id]));
      }
      await confirm(tester);
      await pumpUntil(
          tester,
          () => find
              .textContaining(change == 'target' ? '导入失败' : '导入未完成')
              .evaluate()
              .isNotEmpty);
      final row = await tester.runAsync(() => dao.getAssistant(old.id!));
      expect(row!.prompt, change == 'target' ? '其他编辑' : '原正文');
      expect((await tester.runAsync(dao.getAssistants))!.length, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('file selection account switch does not open preview or save',
      (tester) async {
    await page(tester);
    final pending = Completer<FilePickerResult?>();
    picker.choose = () => pending.future;
    await tester.runAsync(() async {
      tester
          .widget<IconButton>(find.byWidgetPredicate((w) =>
              w is IconButton && w.tooltip == '导入角色卡（.json/.png/.zip/.charx）'))
          .onPressed!();
    });
    await tester.pump();
    login.account = 'other';
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(await tester.runAsync(dao.getAssistants), isEmpty);
    expect(find.textContaining('导入未完成'), findsOneWidget);
  });
  for (final stage in ['target', 'target-translate', 'opening']) {
    testWidgets('room import captured scope rejects restore at $stage dialog',
        (tester) async {
      await page(tester);
      await select(
          tester,
          AssistantRoleCardService.importJson(jsonEncode({
            'spec': 'chara_card_v2',
            'spec_version': '2.0',
            'data': {
              'name': '多角色群像',
              'description': '两个角色',
              'first_mes': '开场一',
              'alternate_greetings': ['开场二']
            }
          })));
      expect(find.text('选择导入方式'), findsOneWidget);
      if (stage == 'target-translate') {
        await tester.ensureVisible(find.text('创建酒馆房间前翻译为简体中文'));
        await tester.tap(find.text('创建酒馆房间前翻译为简体中文'));
        await tester.pump();
      }
      if (stage == 'opening') {
        await tester.runAsync(
            () => tester.tap(find.widgetWithText(FilledButton, '酒馆房间')));
        await pumpUntil(
            tester, () => find.text('选择房间开场').evaluate().isNotEmpty);
      }
      {
        BackupService.restoreTick.value++;
        await tester.pump();
        await tester.runAsync(() => tester.tap(find.widgetWithText(
            FilledButton, stage == 'opening' ? '创建房间' : '酒馆房间')));
        await pumpUntil(
            tester, () => find.textContaining('导入未完成').evaluate().isNotEmpty);
        final tables = (await tester.runAsync(() => storage.db
            .rawQuery("select name from sqlite_master where type='table'")))!;
        for (final name in [
          'tb_assistant',
          'tb_story_room',
          'tb_story_template',
          'tb_story_template_translation_task'
        ]) {
          if (tables.any((row) => row['name'] == name)) {
            expect(await tester.runAsync(() => storage.db.query(name)), isEmpty,
                reason: name);
          }
        }
        expect(tester.takeException(), isNull);
      }
    });
  }
}
