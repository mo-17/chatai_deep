import 'package:chatgpt_app_core/chat/application/story_room_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_participant_settings_resolver.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('新旧房间默认跟随；JSON 和重命名保留三态', () {
    expect(StoryRoomModel(title: '新房间').webSearchEnabled, isNull);
    expect(StoryRoomModel.fromJson({'title': '旧房间'}).webSearchEnabled, isNull);
    for (final value in <bool?>[null, false, true]) {
      final room = StoryRoomModel(
          title: '房间',
          webSearchEnabled: value,
          publicContext: '保留内容',
          topP: .7);
      final copy =
          StoryRoomModel.fromJson(room.toJson()).copyWith(title: '重命名');
      expect(copy.webSearchEnabled, value);
      expect(copy.publicContext, '保留内容');
      expect(copy.topP, .7);
    }
    expect(StoryRoomModel.fromJson({'webSearchEnabled': true}).webSearchEnabled,
        isTrue);
    expect(
        StoryRoomModel.fromJson({'webSearchEnabled': false}).webSearchEnabled,
        isFalse);
    expect(
        StoryRoomModel.fromJson({'webSearchEnabled': 'invalid'})
            .webSearchEnabled,
        isNull);
  });
  test('旧表兼容补列，旧房间保持跟随且重复升级不覆盖已保存值', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    await db.execute(
        'create table tb_story_room(id integer primary key, title text, publicContext text, createdAt integer, updatedAt integer)');
    await db.insert('tb_story_room', {
      'id': 1,
      'title': '旧房间',
      'publicContext': '原有内容',
      'createdAt': 12,
      'updatedAt': 13
    });
    final storage = HiDBManager.test(db);
    final dao = await StoryRoomDao.create(storage);
    final old = (await dao.getRoom(1))!;
    expect(old.webSearchEnabled, isNull);
    expect(old.publicContext, '原有内容');
    expect(old.createdAt, 12);
    await dao.updateWebSearchOverride(1, true);
    final reopened = await StoryRoomDao.create(storage);
    expect((await reopened.getRoom(1))!.webSearchEnabled, isTrue);
    await reopened.updateWebSearchOverride(1, false);
    expect((await reopened.getRoom(1))!.webSearchEnabled, isFalse);
    await reopened.updateWebSearchOverride(1, null);
    expect((await reopened.getRoom(1))!.webSearchEnabled, isNull);
    expect((await reopened.getRoom(1))!.publicContext, '原有内容');
    expect(await reopened.updateWebSearchOverride(999, true), 0);
  });
  test('账号数据库与房间互相隔离，局部保存不覆盖其它内容', () async {
    final a = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    final b = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(a.close);
    addTearDown(b.close);
    final da = await StoryRoomDao.create(HiDBManager.test(a));
    final db = await StoryRoomDao.create(HiDBManager.test(b));
    final first = StoryRoomModel(title: '账号 A', webSearchEnabled: false);
    final second = StoryRoomModel(title: 'A 另一房间');
    final other = StoryRoomModel(title: '账号 B', webSearchEnabled: false);
    await da.saveRoom(first);
    await da.saveRoom(second);
    await db.saveRoom(other);
    expect(first.id, other.id);
    await a.update('tb_story_room', {'publicContext': '并发更新'},
        where: 'id = ?', whereArgs: [first.id]);
    await da.updateWebSearchOverride(first.id!, true);
    expect((await da.getRoom(first.id!))!.webSearchEnabled, isTrue);
    expect((await da.getRoom(first.id!))!.publicContext, '并发更新');
    expect((await da.getRoom(second.id!))!.webSearchEnabled, isNull);
    expect((await db.getRoom(other.id!))!.webSearchEnabled, isFalse);
  });
  test('全局变化仅影响跟随房间；角色参数解析继续保留房间有效搜索设置', () {
    final global = AISettings.defaults()..tavilyApiKey = 'offline-placeholder';
    final speaker = StoryParticipantModel(
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '测试角色',
        temperature: .5);
    for (final override in <bool?>[null, false, true]) {
      final room = StoryRoomModel(title: '房间', webSearchEnabled: override);
      for (final enabled in [false, true, false]) {
        global.webSearchEnabled = enabled;
        final result = StoryRoomSettingsResolver.apply(room, global);
        final speakerSettings =
            StoryParticipantSettingsResolver.apply(result, speaker);
        expect(result.webSearchEnabled, override ?? enabled);
        expect(speakerSettings.webSearchEnabled, override ?? enabled);
        expect(speakerSettings.webSearchConfigured, isTrue);
        expect(global.webSearchEnabled, enabled);
        expect(room.webSearchEnabled, override);
      }
    }
  });
}
