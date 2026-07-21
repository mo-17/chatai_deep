import 'dart:io';

import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/theme/starcore_icon_assets.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// L1（助手绑定工具）验收：
/// 1) AssistantModel.toolIds 的 JSON 往返（null / [] / 具体列表）；
/// 2) ToolRegistry.fromAssistant 选路（绑定 / forceWebSearch / 未配置 key）；
/// 3) tb_assistant 旧表（无 tools 列）经 create 升级后可读写 toolIds。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('AssistantModel.toolIds JSON 往返', () {
    test('null 保持 null（旧数据语义不变）', () {
      final a = AssistantModel(name: 'a');
      expect(a.toolIds, isNull);
      expect(a.toJson()['tools'], isNull);
      final back = AssistantModel.fromJson(a.toJson());
      expect(back.toolIds, isNull);
    });

    test('空列表与具体列表都能往返', () {
      final empty = AssistantModel(name: 'a', toolIds: const []);
      expect(AssistantModel.fromJson(empty.toJson()).toolIds, isEmpty);

      final bound = AssistantModel(name: 'a', toolIds: const ['web_search']);
      expect(AssistantModel.fromJson(bound.toJson()).toolIds, ['web_search']);
    });
  });

  group('ToolRegistry.fromAssistant 选路', () {
    AISettings configured() => AISettings.defaults()
      ..tavilyApiKey = 'tvly-x'; // webSearchProviderId 默认 tavily

    test('未绑定（null）且无 forceWebSearch -> 空注册表', () {
      final r = ToolRegistry.fromAssistant(configured(), null);
      expect(r.isEmpty, isTrue);
    });

    test('绑定 web_search 且已配置 key -> 含该工具', () {
      final r = ToolRegistry.fromAssistant(configured(), const ['web_search']);
      expect(r.byName('web_search'), isNotNull);
    });

    test('forceWebSearch=true（会话联网开关）即便未绑定也纳入 web_search', () {
      final r =
          ToolRegistry.fromAssistant(configured(), null, forceWebSearch: true);
      expect(r.byName('web_search'), isNotNull);
    });

    test('未配置搜索 key -> 即便绑定/强制也为空（依赖未满足）', () {
      final s = AISettings.defaults(); // 无 key
      expect(
          ToolRegistry.fromAssistant(s, const ['web_search']).isEmpty, isTrue);
      expect(ToolRegistry.fromAssistant(s, null, forceWebSearch: true).isEmpty,
          isTrue);
    });

    test('isAvailable：web_search 依赖搜索 key', () {
      expect(ToolRegistry.isAvailable(configured(), 'web_search'), isTrue);
      expect(ToolRegistry.isAvailable(AISettings.defaults(), 'web_search'),
          isFalse);
    });
  });

  group('tb_assistant 升级（tools 列）', () {
    late Database db;
    tearDown(() async => db.close());

    test('旧表（无 tools 列）经 create 后可读写 toolIds', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      // 模拟 L1 之前的旧 schema（无 tools 列）。
      await db.execute(
          'create table tb_assistant (id integer primary key autoincrement'
          ', name text, emoji text, prompt text, model text'
          ', useTools integer, createdAt integer, updatedAt integer)');
      final dao = await AssistantDao.create(HiDBManager.test(db));

      final id = await dao.saveAssistant(
          AssistantModel(name: '研究员', toolIds: const ['web_search']));
      final back = await dao.getAssistant(id!);
      expect(back!.toolIds, ['web_search']);
    });

    test('新库直接建表（含 tools），旧数据 toolIds 读为 null', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await AssistantDao.create(HiDBManager.test(db));
      final id = await dao.saveAssistant(AssistantModel(name: '无工具'));
      final back = await dao.getAssistant(id!);
      expect(back!.toolIds, isNull);
    });

    test('旧表（无 providerId 列）经 create 后可读写 providerId', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
          'create table tb_assistant (id integer primary key autoincrement'
          ', name text, emoji text, prompt text, model text'
          ', useTools integer, createdAt integer, updatedAt integer)');
      final dao = await AssistantDao.create(HiDBManager.test(db));
      final id = await dao.saveAssistant(
        AssistantModel(name: '研究员', providerId: 'openai'),
      );
      final back = await dao.getAssistant(id!);
      expect(back!.providerId, 'openai');
    });

    test('旧表（无头像列）经 create 后可读写 avatarType/avatarValue', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
          'create table tb_assistant (id integer primary key autoincrement'
          ', name text, emoji text, prompt text, model text'
          ', useTools integer, createdAt integer, updatedAt integer)');
      final dao = await AssistantDao.create(HiDBManager.test(db));
      final id = await dao.saveAssistant(
        AssistantModel(
          name: '有头像',
          avatarType: 'image',
          avatarValue: '/tmp/assistant-avatar.png',
        ),
      );
      final back = await dao.getAssistant(id!);
      expect(back!.avatarType, 'image');
      expect(back.avatarValue, '/tmp/assistant-avatar.png');
    });

    test('读取助手时会重定位旧 iOS 容器中的托管头像路径', () async {
      final newRoot =
          await Directory.systemTemp.createTemp('assistant_avatar_dao_root_');
      AvatarAssetService.debugDocumentsDirectoryResolver = () async => newRoot;
      addTearDown(() async {
        AvatarAssetService.debugDocumentsDirectoryResolver = null;
        if (await newRoot.exists()) await newRoot.delete(recursive: true);
      });
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await AssistantDao.create(HiDBManager.test(db));
      const oldPath = '/old/container/chat_avatar/test/assistant_role_1.png';
      final newPath = '${newRoot.path}/chat_avatar/test/assistant_role_1.png';
      await File(newPath).parent.create(recursive: true);
      await File(newPath).writeAsBytes([1, 2, 3]);
      final id = await dao.saveAssistant(
        AssistantModel(
          name: '旧路径头像',
          avatarType: AvatarAssetService.imageType,
          avatarValue: oldPath,
        ),
      );

      final back = await dao.getAssistant(id!);
      final rows =
          await db.query('tb_assistant', where: 'id = ?', whereArgs: [id]);

      expect(back!.avatarValue, newPath);
      expect(rows.single['avatarValue'], newPath);
    });

    test('Starcore asset id round-trips without filesystem relocation',
        () async {
      AvatarAssetService.debugDocumentsDirectoryResolver =
          () async => throw StateError('asset ids must not touch filesystem');
      addTearDown(() {
        AvatarAssetService.debugDocumentsDirectoryResolver = null;
      });
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await AssistantDao.create(HiDBManager.test(db));
      final id = await dao.saveAssistant(
        AssistantModel(
          name: '星核向导',
          avatarType: AvatarAssetService.assetType,
          avatarValue: StarcoreIconAssets.assistantExplorerId,
        ),
      );

      final back = await dao.getAssistant(id!);
      final rows =
          await db.query('tb_assistant', where: 'id = ?', whereArgs: [id]);

      expect(back!.avatarType, AvatarAssetService.assetType);
      expect(back.avatarValue, StarcoreIconAssets.assistantExplorerId);
      expect(
          rows.single['avatarValue'], StarcoreIconAssets.assistantExplorerId);
    });

    test('新表 providerId 缺省为空串', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await AssistantDao.create(HiDBManager.test(db));
      final id = await dao.saveAssistant(AssistantModel(name: '默认服务商'));
      final back = await dao.getAssistant(id!);
      expect(back!.providerId, isEmpty);
    });
  });
}
