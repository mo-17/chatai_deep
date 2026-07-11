import 'dart:io';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
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

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));

  test('Persona 模型 key 稳定、兼容旧 JSON，并限制外部文本长度', () {
    final legacy = <String, dynamic>{
      'title': '旧人设',
      'content': '旧描述',
      'avatar': {'type': 'emoji', 'value': '🧭'},
    };
    final first = StoryPersonaModel.fromJson(legacy);
    final second = StoryPersonaModel.fromJson(legacy);
    expect(first.personaKey, second.personaKey);
    expect(first.name, '旧人设');
    expect(first.description, '旧描述');
    expect(first.avatarValue, '🧭');
    expect(StoryPersonaModel.fromJson(first.toJson()).personaKey,
        first.personaKey);

    final bounded = StoryPersonaModel(
      name: 'x' * (StoryPersonaLimits.maxNameLength + 1),
      description: 'y' * (StoryPersonaLimits.maxDescriptionLength + 1),
      avatarValue: 'z' * (StoryPersonaLimits.maxAvatarValueLength + 1),
    );
    expect(bounded.name.length, StoryPersonaLimits.maxNameLength);
    expect(bounded.description.length, StoryPersonaLimits.maxDescriptionLength);
    expect(bounded.avatarValue.length, StoryPersonaLimits.maxAvatarValueLength);
  });

  test('CRUD 以 personaKey 去重、按更新时间排序并可按 key 查找', () async {
    final storage = await newDb();
    final dao = await StoryPersonaDao.create(storage);
    final first = StoryPersonaModel(personaKey: 'persona-alpha', name: '甲');
    final second = StoryPersonaModel(personaKey: 'persona-beta', name: '乙');
    await dao.savePersona(first);
    await dao.savePersona(second);
    await storage.db.update('tb_story_persona', {'updatedAt': 1},
        where: 'id = ?', whereArgs: [first.id]);
    await storage.db.update('tb_story_persona', {'updatedAt': 2},
        where: 'id = ?', whereArgs: [second.id]);

    final sameKey = StoryPersonaModel(
        personaKey: 'persona-alpha', name: '甲（已更新）', description: '新描述');
    await dao.savePersona(sameKey);

    final listed = await dao.getPersonas();
    expect(listed, hasLength(2));
    expect(listed.first.personaKey, 'persona-alpha');
    expect((await dao.getPersonaByKey('persona-alpha'))!.name, '甲（已更新）');
    expect((await dao.getPersona(first.id!))!.description, '新描述');
    await storage.db.close();
  });

  test('旧 Persona 表自动补稳定 key，删除会写 personaKey 墓碑', () async {
    final storage = await newDb();
    await storage.db.execute(
        'create table tb_story_persona (id integer primary key autoincrement'
        ', name text, description text, avatarType text, avatarValue text'
        ', createdAt integer, updatedAt integer)');
    await storage.db.insert('tb_story_persona', {
      'name': '旧本地人设',
      'description': '迁移内容',
      'avatarType': 'emoji',
      'avatarValue': '🎭',
      'createdAt': 1,
      'updatedAt': 1,
    });

    final dao = await StoryPersonaDao.create(storage);
    final migrated = (await dao.getPersonas()).single;
    expect(migrated.personaKey, isNotEmpty);
    expect((await dao.getPersonaByKey(migrated.personaKey))!.name, '旧本地人设');

    expect(await dao.deletePersona(migrated.id!), isTrue);
    final tombstones = await storage.db.query('tb_sync_tombstone',
        where: 'entity = ? and entityId = ?',
        whereArgs: ['story_persona', migrated.personaKey]);
    expect(tombstones, hasLength(1));
    await storage.db.close();
  });

  test('Persona 头像保存至托管目录，删除 Persona 后保留历史消息快照资源', () async {
    final tmp = await Directory.systemTemp.createTemp('persona_avatar_test_');
    AvatarAssetService.debugDocumentsDirectoryResolver = () async => tmp;
    addTearDown(() async {
      AvatarAssetService.debugDocumentsDirectoryResolver = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final source = File('${tmp.path}/source.png');
    await source.writeAsBytes([137, 80, 78, 71]);
    final storage = await newDb();
    final dao = await StoryPersonaDao.create(storage);
    final persona = StoryPersonaModel(personaKey: 'persona-avatar', name: '头像');

    final savedPath =
        await dao.savePersonaAvatar(persona, sourcePath: source.path);
    expect(savedPath, contains('/chat_avatar/test/persona_persona-avatar_'));
    expect(await File(savedPath).exists(), isTrue);
    expect(await dao.deletePersona(persona.id!), isTrue);
    expect(await File(savedPath).exists(), isTrue);
    await storage.db.close();
  });
}
