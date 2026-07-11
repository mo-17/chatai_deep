import 'dart:io';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/pages/story_persona_edit_page.dart';
import 'package:chatgpt_app_core/pages/story_persona_list_page.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
  });

  Future<(HiDBManager, StoryPersonaDao)> newDao() async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    final storage = HiDBManager.test(database);
    return (storage, await StoryPersonaDao.create(storage));
  }

  testWidgets('列表展示 Persona、支持删除确认且 390px 不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final persona = StoryPersonaModel(
      personaKey: 'list-persona',
      name: '冷静的编辑',
      description: '负责把复杂内容整理成清晰、克制的表达。',
      avatarValue: '📝',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StoryPersonaListPage(initialPersonas: [persona]),
      ),
    );
    await tester.pump();

    expect(find.text('冷静的编辑'), findsOneWidget);
    expect(find.byKey(const ValueKey('story_persona_add')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('story_persona_delete_list-persona')),
    );
    await tester.pump();
    expect(find.text('删除 Persona？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selectionMode 点击 Persona 返回 StoryPersonaModel', (tester) async {
    final persona = StoryPersonaModel(
      personaKey: 'selectable',
      name: '可选择',
      description: '简介',
      avatarValue: '🎭',
    );
    StoryPersonaModel? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                selected = await Navigator.of(context).push<StoryPersonaModel>(
                  MaterialPageRoute(
                    builder: (_) => StoryPersonaListPage(
                      selectionMode: true,
                      initialPersonas: [persona],
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('可选择'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(selected?.personaKey, 'selectable');
    expect(selected?.name, '可选择');
    expect(tester.takeException(), isNull);
  });

  testWidgets('空名称保存显示 snackbar，编辑页 390px 不溢出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: StoryPersonaEditPage()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('story_persona_save')));
    await tester.pump();

    expect(find.text('请输入 Persona 名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('Persona 图片由 DAO 托管到应用目录', () async {
    final (storage, dao) = await newDao();
    addTearDown(() => storage.db.close());
    final root = await Directory.systemTemp.createTemp('story-persona-pages-');
    addTearDown(() => root.delete(recursive: true));
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => root;
    addTearDown(
      () => AvatarAssetService.debugDocumentsDirectoryResolver = null,
    );
    final source = File('${root.path}/picked.png')..writeAsBytesSync([1, 2, 3]);
    final persona = StoryPersonaModel(name: '图片 Persona');

    final managedPath = await dao.savePersonaAvatar(
      persona,
      sourcePath: source.path,
    );

    expect(managedPath, contains('/chat_avatar/'));
    expect(File(managedPath).existsSync(), isTrue);
    expect((await dao.getPersonas()).single.avatarValue, managedPath);
  });
}
