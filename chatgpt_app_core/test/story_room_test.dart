import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_speaker_scheduler.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('StoryRoomDao', () {
    late Database db;

    tearDown(() async {
      await db.close();
    });

    test('保存房间、多个参与者和带 speaker 信息的消息', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final room = StoryRoomModel(
        title: '雨夜书店',
        mode: StoryRoomMode.tavern,
        replyMode: StoryReplyMode.autoMulti,
        maxAutoReplies: 3,
        publicContext: '现代奇幻',
      );
      final roomId = await dao.saveRoom(room);

      final author = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.author,
        name: '作者',
      );
      final role = StoryParticipantModel(
        roomId: roomId,
        assistantId: 7,
        role: StoryParticipantRole.assistant,
        name: '风香',
        prompt: '内向但敏锐',
        avatarType: 'emoji',
        avatarValue: '📚',
        sortOrder: 1,
      );
      await dao.saveParticipant(author);
      await dao.saveParticipant(role);

      await dao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '门铃响了。',
      ));
      await dao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerId: role.id,
        speakerRole: role.role,
        speakerName: role.name,
        speakerAvatarType: role.avatarType,
        speakerAvatarValue: role.avatarValue,
        content: '她抬起头，看向门口。',
      ));

      final participants = await dao.getParticipants(roomId);
      expect(participants.map((e) => e.name), ['作者', '风香']);
      final savedRoom = await dao.getRoom(roomId);
      expect(savedRoom?.mode, StoryRoomMode.tavern);
      expect(savedRoom?.replyMode, StoryReplyMode.autoMulti);
      expect(savedRoom?.maxAutoReplies, 3);
      final messages = await dao.getMessages(roomId);
      expect(messages, hasLength(2));
      expect(messages.last.speakerId, role.id);
      expect(messages.last.speakerName, '风香');
      expect(messages.last.speakerAvatarValue, '📚');
    });

    test('重命名和删除房间会清理参与者与消息', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final room = StoryRoomModel(title: '旧名字');
      final roomId = await dao.saveRoom(room);
      await dao.saveParticipant(StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '风香',
      ));
      await dao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '你好',
      ));

      room.title = '新名字';
      await dao.saveRoom(room);
      expect((await dao.getRoom(roomId))?.title, '新名字');

      await dao.deleteRoom(roomId);
      expect(await dao.getRoom(roomId), isNull);
      expect(await dao.getParticipants(roomId), isEmpty);
      expect(await dao.getMessages(roomId), isEmpty);
    });
  });

  group('StoryRoomRoleCardImporter', () {
    late Database db;

    tearDown(() async {
      await db.close();
    });

    test('将多角色世界书卡导入为酒馆房间和角色参与者', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final assistant = AssistantModel(
        name: 'Yes, My Liege',
        description: 'Multiple Characters · Scenario · Sandbox',
        prompt: '[角色设定]\n高奇幻王国正在遭遇多线危机。',
      )
        ..openingMessage = 'Florin. Your home.'
        ..memoryBook = [
          '[p=10] Chandra => ----',
          'Name: Chandra',
          'Type: character',
          'Personality: passionate and boastful.',
          '[p=10] Medli => ----',
          'Name: Medli',
          'Type: character',
          'Personality: soft-spoken and caring.',
          '[p=10] Ice Queen => ----',
          'Name: The Ice Queen',
          'Type: character',
          'Personality: cold and strategic.',
        ].join('\n');

      expect(
          StoryRoomRoleCardImporter.shouldSuggestTavernRoom(assistant), isTrue);
      expect(
        StoryRoomRoleCardImporter.normalizeMemoryBookForMatching(
          assistant.memoryBook,
        ),
        contains('Chandra => ---- Name: Chandra Type: character'),
      );

      final roomId =
          await StoryRoomRoleCardImportService(dao).importAsTavernRoom(
        assistant,
        title: assistant.name,
        tavernMeta: const AssistantRoleCardTavernMeta(
          spec: 'chara_card_v2',
          specVersion: '2.0',
          tags: ['Multiple Characters', 'Scenario'],
          alternateGreetings: ['Alt opening A', 'Alt opening B'],
          characterBookName: 'YMLv2',
          characterBookScanDepth: 50,
          characterBookTokenBudget: 2000,
          characterBookRecursiveScanning: false,
          characterBookEntryCount: 29,
        ),
        initialOpening: 'Alt opening B',
      );

      final room = await dao.getRoom(roomId);
      expect(room?.title, 'Yes, My Liege');
      expect(room?.mode, StoryRoomMode.tavern);
      expect(room?.publicContext, contains('高奇幻王国'));
      expect(room?.publicContext, contains('Florin'));
      expect(room?.publicContext, contains('chara_card_v2 / 2.0'));
      expect(room?.publicContext, contains('世界书：YMLv2'));
      expect(room?.publicContext, contains('扫描深度：50'));
      expect(room?.publicContext, contains('Alt opening A'));
      final participants = await dao.getParticipants(roomId);
      expect(participants.map((item) => item.name), [
        'Chandra',
        'Medli',
        'The Ice Queen',
      ]);
      expect(participants.first.prompt, contains('passionate'));
      final messages = await dao.getMessages(roomId);
      expect(messages, hasLength(1));
      expect(messages.single.speakerName, '开场');
      expect(messages.single.content, 'Alt opening B');
    });

    test('批量角色卡可合并为一个酒馆房间', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final fuka = AssistantModel(
        name: 'Fuka',
        description: '害羞的图书委员。',
        prompt: '说话轻声，容易紧张。',
        avatarType: 'emoji',
        avatarValue: '📚',
      )
        ..openingMessage = '她抱紧书本，站在门边。'
        ..memoryBook = '图书馆 => Fuka 熟悉旧图书馆的每一排书架。';
      final chandra = AssistantModel(
        name: 'Chandra',
        description: '火焰将军。',
        prompt: '自信、直接，习惯指挥。',
      )..memoryBook = '[pos=after_char] 战场 => Chandra 会优先判断战况。';

      final roomId =
          await StoryRoomRoleCardImportService(dao).importBatchAsTavernRoom(
        [
          AssistantRoleCardImportResult(assistant: fuka),
          AssistantRoleCardImportResult(assistant: chandra),
        ],
        title: 'Imported Tavern',
        initialOpening: fuka.openingMessage,
      );

      final room = await dao.getRoom(roomId);
      expect(room?.title, 'Imported Tavern');
      expect(room?.mode, StoryRoomMode.tavern);
      expect(room?.replyMode, StoryReplyMode.autoMulti);
      expect(room?.maxAutoReplies, 2);
      expect(room?.publicContext, contains('【角色卡：Fuka】'));
      expect(room?.publicContext, contains('【角色卡：Chandra】'));
      expect(room?.publicContext, contains('【关键词记忆 / 世界书】'));
      expect(room?.publicContext, contains('# Fuka'));
      expect(room?.publicContext, contains('# Chandra'));

      final participants = await dao.getParticipants(roomId);
      expect(participants.map((item) => item.name), ['Fuka', 'Chandra']);
      expect(participants.first.avatarValue, '📚');
      expect(participants.first.prompt, contains('害羞的图书委员'));
      final messages = await dao.getMessages(roomId);
      expect(messages.single.content, fuka.openingMessage);

      final system = StoryContextBuilder.systemPrompt(
        room: room!,
        participants: participants,
        speaker: participants.last,
        latestInput: '战场那边发生了什么？',
      );
      expect(system, contains('【本轮命中世界书 / 角色后置】'));
      expect(system, contains('Chandra 会优先判断战况'));
    });
  });

  group('StoryContextBuilder', () {
    test('区分公共上下文、当前发言者人设和多 speaker 历史', () {
      final room = StoryRoomModel(title: '雨夜书店', publicContext: '城市里有魔法。');
      final author = StoryParticipantModel(
        id: 1,
        roomId: 1,
        role: StoryParticipantRole.author,
        name: '作者',
      );
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '害羞，避免主动与陌生人对视。',
      );
      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [author, fuka],
        speaker: fuka,
      );
      expect(system, contains('【公共上下文 / 世界设定】'));
      expect(system, contains('城市里有魔法。'));
      expect(system, contains('【当前发言者】'));
      expect(system, contains('角色：Fuka'));
      expect(system, contains('害羞，避免主动与陌生人对视。'));

      final history = StoryContextBuilder.history([
        StoryMessageModel(
          roomId: 1,
          speakerRole: 'user',
          speakerName: '我',
          content: '你会说话吗？',
        ),
        StoryMessageModel(
          roomId: 1,
          speakerId: 2,
          speakerRole: StoryParticipantRole.assistant,
          speakerName: 'Fuka',
          content: '会……一点。',
        ),
      ]);
      expect(history.first['role'], 'user');
      expect(history.last['role'], 'assistant');
      expect(history.last['content'], 'Fuka：会……一点。');
    });

    test('酒馆模式不注入作者和旁白职责', () {
      final room = StoryRoomModel(
        title: '旧校舍',
        mode: StoryRoomMode.tavern,
        publicContext: '放学后的走廊很安静。',
      );
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '容易紧张，说话很小声。',
      );
      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [fuka],
        speaker: fuka,
      );

      expect(system, contains('酒馆角色扮演房间'));
      expect(system, contains('【公共上下文 / 场景设定】'));
      expect(system, contains('不要以作者、旁白或系统解说身份输出'));
      expect(system, isNot(contains('你是作者助手')));
      expect(system, isNot(contains('如果当前发言者是旁白')));
    });

    test('酒馆世界书按条目扫描深度限制最近消息范围', () {
      final room = StoryRoomModel(
        title: '钟楼',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【关键词记忆 / 世界书】',
          '[depth=1] 旧钟声 => 旧钟声最近一轮才会触发。',
          '[depth=2] 古井 => 古井可扫描最近两轮。',
        ].join('\n'),
      );
      final fuka = StoryParticipantModel(
        id: 1,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '安静观察。',
      );

      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [fuka],
        speaker: fuka,
        latestInput: '现在没有新的线索。',
        recentMessages: [
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'assistant',
            speakerName: 'Fuka',
            content: '两轮前提到了旧钟声。',
          ),
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'user',
            speakerName: '我',
            content: '上一轮经过古井。',
          ),
        ],
      );

      expect(system, isNot(contains('旧钟声最近一轮才会触发')));
      expect(system, contains('古井可扫描最近两轮'));
    });

    test('酒馆世界书按本轮输入动态命中，避免全量注入', () {
      final room = StoryRoomModel(
        title: 'Florin',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息】',
          'Token 预算：2000',
          '',
          '【角色卡说明】',
          '高奇幻冒险。',
          '',
          '【关键词记忆 / 世界书】',
          '[p=10] Chandra => Name: Chandra\nPersonality: proud general.',
          '[pos=after_char] Chandra => After character prompt note.',
          '[p=10] Medli => Name: Medli\nPersonality: gentle scout.',
        ].join('\n'),
      );
      final chandra = StoryParticipantModel(
        id: 1,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Chandra',
        prompt: '火焰将军。',
      );

      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [chandra],
        speaker: chandra,
        latestInput: 'Chandra, report the battlefield.',
      );

      expect(system, contains('【本轮命中世界书】'));
      expect(system, contains('proud general'));
      expect(system, contains('【本轮命中世界书 / 角色后置】'));
      expect(system, contains('After character prompt note.'));
      expect(
        system.indexOf('【当前发言者人设 / 写作职责】'),
        lessThan(system.indexOf('【本轮命中世界书 / 角色后置】')),
      );
      expect(system, isNot(contains('gentle scout')));
      expect(system, isNot(contains('【关键词记忆 / 世界书】')));
    });
  });

  group('StorySpeakerScheduler', () {
    test('只把酒馆角色卡作为自动接话候选', () {
      final author = StoryParticipantModel(
        id: 1,
        roomId: 1,
        role: StoryParticipantRole.author,
        name: '作者',
      );
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
      );
      final disabled = StoryParticipantModel(
        id: 3,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '已禁用',
        enabled: false,
      );

      final candidates =
          StorySpeakerScheduler.tavernCandidates([author, fuka, disabled]);

      expect(candidates.map((e) => e.name), ['Fuka']);
      expect(
        StorySpeakerScheduler.fallbackSpeaker(
          candidates: candidates,
          selectedParticipantId: 2,
        )?.name,
        'Fuka',
      );
    });

    test('解析调度器返回的 speakerId', () {
      expect(
        StorySpeakerScheduler.parseSpeakerId('{"speakerId":2}', {2, 4}),
        2,
      );
      expect(
        StorySpeakerScheduler.parseSpeakerId(
          '```json\n{"speaker_id":"4"}\n```',
          {2, 4},
        ),
        4,
      );
      expect(
        StorySpeakerScheduler.parseSpeakerId('{"speakerId":9}', {2, 4}),
        isNull,
      );
    });

    test('解析群聊轮换返回的多个 speakerIds', () {
      expect(
        StorySpeakerScheduler.parseSpeakerIds(
          '{"speakerIds":[2,4,2,9]}',
          {2, 4, 6},
          maxCount: 3,
        ),
        [2, 4],
      );
      expect(
        StorySpeakerScheduler.parseSpeakerIds(
          '{"speaker_ids":["6","4"]}',
          {2, 4, 6},
          maxCount: 1,
        ),
        [6],
      );
    });

    test('生成酒馆调度提示词', () {
      final room = StoryRoomModel(
        title: '旧校舍',
        mode: StoryRoomMode.tavern,
        publicContext: '放学后的走廊。',
      );
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '害羞，容易紧张。',
      );
      final system = StorySpeakerScheduler.systemPrompt(
        room: room,
        candidates: [fuka],
        recentMessages: [
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'user',
            speakerName: '我',
            content: '有人在吗？',
          ),
        ],
      );

      expect(system, contains('发言调度器'));
      expect(system, contains('speakerId=2'));
      expect(system, contains('只输出 JSON'));
      expect(StorySpeakerScheduler.promptFor('你好'), contains('用户最新输入'));
    });

    test('群聊轮换提示词要求 speakerIds', () {
      final room = StoryRoomModel(
        title: '旧校舍',
        mode: StoryRoomMode.tavern,
      );
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
      );
      final system = StorySpeakerScheduler.systemPrompt(
        room: room,
        candidates: [fuka],
        recentMessages: const [],
        maxSpeakers: 3,
      );

      expect(system, contains('{"speakerIds":[数字]}'));
      expect(StorySpeakerScheduler.promptFor('你好', maxSpeakers: 3),
          contains('1-3 个最应该接话的角色'));
    });
  });
}
