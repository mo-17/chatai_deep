import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/story_tavern_chat_transfer.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('StoryTavernChatTransfer', () {
    late Database db;

    tearDown(() async => db.close());

    test('预览导入群聊、swipes、header 和 Persona 快照，再 round-trip 导出', () async {
      const source = '''
{"chat_metadata":{"note":"kept","nested":{"x":1}},"user_name":"旅行者","character_name":"风香","unknown_header":{"keep":true}}
{"name":"旅行者","is_user":true,"is_system":false,"send_date":100,"mes":"你好","extra":{"bias":1}}
{"name":"风香","is_user":false,"is_system":false,"send_date":200,"mes":"当前回复","swipes":["候选一","当前回复"],"swipe_id":1,"swipe_info":[{"gen_started":1}],"extra":{"keep":"yes"}}
{"name":"澪","is_user":false,"is_system":false,"send_date":300,"mes":"我也在"}
''';
      final preview = StoryTavernChatTransfer.previewJsonl(source);

      expect(preview.isAccepted, isTrue);
      final plan = preview.plan!;
      expect(plan.room.mode, StoryRoomMode.tavern);
      expect(plan.room.replyMode, StoryReplyMode.autoMulti);
      expect(plan.personaSnapshot?.name, '旅行者');
      expect(plan.participants.map((item) => item.name), ['风香', '澪']);
      expect(plan.messages, hasLength(4));
      expect(plan.messages[1].parentNodeKey, plan.messages[0].nodeKey);
      expect(plan.messages[2].parentNodeKey, plan.messages[0].nodeKey);
      expect(plan.room.activeMessageKey, plan.messages[3].nodeKey);

      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await StoryTavernChatTransfer.persistPlan(dao, plan);
      final storedRoom = await dao.getRoom(roomId);
      final stored = await dao.getMessages(roomId);
      final personas = await db.query('tb_story_persona');
      expect(personas, hasLength(1));
      expect(personas.single['name'], '旅行者');
      expect(storedRoom?.personaKey, personas.single['personaKey']);
      expect(stored.first.speakerPersonaKey, personas.single['personaKey']);
      expect(stored[1].speakerId, isNotNull);
      expect(stored[1].tavernExtraJson, jsonEncode({'keep': 'yes'}));
      expect(
          stored[1].tavernSwipeInfoJson,
          jsonEncode([
            {'gen_started': 1}
          ]));

      final exported = await StoryTavernChatTransfer.exportJsonl(dao, roomId);
      final exportedLines = const LineSplitter().convert(exported);
      final exportedHeader =
          jsonDecode(exportedLines.first) as Map<String, dynamic>;
      final reply = jsonDecode(exportedLines[2]) as Map<String, dynamic>;
      expect(exportedHeader['unknown_header'], {'keep': true});
      expect(exportedHeader['chat_metadata']['note'], 'kept');
      expect(reply['mes'], '当前回复');
      expect(reply['swipes'], ['候选一', '当前回复']);
      expect(reply['swipe_id'], 1);
      expect(reply['extra'], {'keep': 'yes'});

      final reparsed = StoryTavernChatTransfer.previewJsonl(exported);
      expect(reparsed.isAccepted, isTrue);
      expect(reparsed.plan!.messages, hasLength(4));
      expect(reparsed.plan!.room.replyMode, StoryReplyMode.autoMulti);
    });

    test('跳过 system 消息，不会当作 OpenAI system 导入', () {
      const source = '''
{"chat_metadata":{},"user_name":"我","character_name":"甲"}
{"name":"Narrator","is_system":true,"mes":"不要导入"}
{"name":"我","is_user":true,"mes":"保留"}
''';
      final preview = StoryTavernChatTransfer.previewJsonl(source);

      expect(preview.isAccepted, isTrue);
      expect(preview.plan!.messages.single.content, '保留');
      expect(preview.warnings.join(), contains('is_system'));
    });

    test('兼容旧 header、unused 名称、秒级时间和未同步 swipe', () {
      const source = '''
{"user_name":"unused","character_name":"unused"}
{"name":"旅行者","is_user":true,"send_date":1710000000,"mes":"你好"}
{"name":"风香","is_user":false,"send_date":"1710000001","mes":"当前可见回复","swipes":["旧候选一","当前可见回复"],"swipe_id":99}
''';

      final preview = StoryTavernChatTransfer.previewJsonl(source);

      expect(preview.isAccepted, isTrue);
      expect(preview.plan!.userName, '旅行者');
      expect(preview.plan!.characterName, '风香');
      expect(preview.plan!.personaSnapshot?.name, '旅行者');
      expect(preview.plan!.messages.first.createdAt, 1710000000000);
      expect(preview.plan!.messages.last.content, '当前可见回复');
      expect(preview.plan!.room.activeMessageKey,
          preview.plan!.messages.last.nodeKey);
      expect(preview.warnings.join(), contains('根据 mes'));
    });

    test('拒绝明显非 ST、坏 JSON、没有有效消息和超限字段', () {
      expect(
        StoryTavernChatTransfer.previewJsonl('{"name":"not header"}')
            .isAccepted,
        isFalse,
      );
      expect(
        StoryTavernChatTransfer.previewJsonl('{"chat_metadata":{}}\nnot-json')
            .isAccepted,
        isFalse,
      );
      expect(
        StoryTavernChatTransfer.previewJsonl(
                '{"chat_metadata":{}}\n{"is_system":true,"mes":"skip"}')
            .isAccepted,
        isFalse,
      );
      final tooLong = 'x' * (StoryTavernChatTransfer.maxMessageChars + 1);
      expect(
        StoryTavernChatTransfer.previewJsonl(
          '{"chat_metadata":{}}\n{"name":"我","is_user":true,"mes":"$tooLong"}',
        ).isAccepted,
        isFalse,
      );
    });

    test('旧库迁移 Tavern round-trip 列，且原子导入失败不留下房间', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
          'create table tb_story_room (id integer primary key autoincrement, title text, updatedAt integer)');
      await db.execute(
          'create table tb_story_message (id integer primary key autoincrement, roomId integer not null, nodeKey text, createdAt integer)');
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final columns = await db.rawQuery('pragma table_info(tb_story_message)');
      expect(columns.map((column) => column['name']),
          containsAll(['tavernExtraJson', 'tavernSwipeInfoJson']));

      final preview = StoryTavernChatTransfer.previewJsonl('''
{"chat_metadata":{},"user_name":"我","character_name":"甲"}
{"name":"甲","is_user":false,"mes":"你好"}
''');
      await db.execute('drop table tb_story_participant');
      await expectLater(
        StoryTavernChatTransfer.persistPlan(dao, preview.plan!),
        throwsA(isA<DatabaseException>()),
      );
      expect(await dao.getRooms(), isEmpty);
      expect(await db.query('tb_story_persona'), isEmpty);
      expect(preview.plan!.room.id, isNull);
      expect(preview.plan!.participants.single.id, isNull);
      expect(preview.plan!.participants.single.roomId, 0);
      expect(preview.plan!.messages.single.id, isNull);
      expect(preview.plan!.messages.single.roomId, 0);
      expect(preview.plan!.messages.single.speakerId, isNull);
    });
  });
}
