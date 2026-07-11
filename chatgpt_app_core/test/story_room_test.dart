import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_context_builder.dart';
import 'package:chatgpt_app_core/chat/application/story_context_window.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/application/story_room_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_participant_settings_resolver.dart';
import 'package:chatgpt_app_core/chat/application/story_speaker_scheduler.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_prompt_config.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/model/story_quick_reply.dart';
import 'package:chatgpt_app_core/model/story_regex_script.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
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
        publicContext: '【关键词记忆 / 世界书】\n钟声 => 门会自动打开。',
        replyMode: StoryReplyMode.autoMulti,
        maxAutoReplies: 3,
        speakerStrategy: StorySpeakerStrategy.roundRobin,
        avoidRepeatSpeaker: false,
        maxAutoTotalTokens: 8192,
        worldBookState: '{"activations":[]}',
        promptConfigJson: '{"version":1,"modules":[]}',
        quickRepliesJson: '{"roomId":0,"groups":[]}',
        regexScriptsJson: '{"version":1,"rules":[]}',
        personaKey: 'persona-traveler',
        modelProviderId: 'deepseek',
        modelId: 'deepseek-v4-pro',
        temperature: 0.7,
        maxOutputTokens: 4096,
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
        modelProviderId: 'openai',
        modelId: 'gpt-4o-mini',
        temperature: 0.45,
        maxOutputTokens: 3072,
        sortOrder: 1,
      );
      await dao.saveParticipant(author);
      await dao.saveParticipant(role);

      await dao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        speakerPersonaKey: 'persona-traveler',
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
      expect(savedRoom?.speakerStrategy, StorySpeakerStrategy.roundRobin);
      expect(savedRoom?.avoidRepeatSpeaker, isFalse);
      expect(savedRoom?.maxAutoTotalTokens, 8192);
      expect(savedRoom?.worldBookState, '{"activations":[]}');
      expect(savedRoom?.promptConfigJson, '{"version":1,"modules":[]}');
      expect(savedRoom?.quickRepliesJson, '{"roomId":0,"groups":[]}');
      expect(savedRoom?.regexScriptsJson, '{"version":1,"rules":[]}');
      expect(savedRoom?.personaKey, 'persona-traveler');
      expect(savedRoom?.modelProviderId, 'deepseek');
      expect(savedRoom?.modelId, 'deepseek-v4-pro');
      expect(savedRoom?.temperature, 0.7);
      expect(savedRoom?.maxOutputTokens, 4096);
      final messages = await dao.getMessages(roomId);
      expect(messages, hasLength(2));
      expect(messages.first.speakerPersonaKey, 'persona-traveler');
      expect(messages.last.speakerId, role.id);
      expect(messages.last.speakerName, '风香');
      expect(messages.last.speakerAvatarValue, '📚');
      expect(participants.last.modelProviderId, 'openai');
      expect(participants.last.modelId, 'gpt-4o-mini');
      expect(participants.last.temperature, 0.45);
      expect(participants.last.maxOutputTokens, 3072);
    });

    test('旧参与者表会自动补齐角色模型覆盖列', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'create table tb_story_participant (id integer primary key autoincrement'
        ', roomId integer not null, assistantId integer, role text, name text'
        ', prompt text, avatarType text, avatarValue text, voiceStyle text'
        ', sortOrder integer, enabled integer, createdAt integer, updatedAt integer)',
      );
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '旧角色房间'));
      final participant = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '旧角色',
        modelProviderId: 'deepseek',
        modelId: 'deepseek-chat',
        temperature: 0.2,
        maxOutputTokens: 1024,
      );
      await dao.saveParticipant(participant);
      final saved = (await dao.getParticipants(roomId)).single;
      expect(saved.modelProviderId, 'deepseek');
      expect(saved.modelId, 'deepseek-chat');
      expect(saved.temperature, 0.2);
      expect(saved.maxOutputTokens, 1024);
    });

    test('房间调度配置会归一化，并兼容旧表补列', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'create table tb_story_room (id integer primary key autoincrement'
        ', title text, mode text, replyMode text, maxAutoReplies integer'
        ', publicContext text, worldBookState text'
        ', promptConfigJson text, quickRepliesJson text, regexScriptsJson text, personaKey text'
        ', modelProviderId text, modelId text'
        ', temperature real, maxOutputTokens integer'
        ', activeMessageKey text, tavernChatMetadataJson text'
        ', createdAt integer, updatedAt integer)',
      );
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final columns = await db.rawQuery('pragma table_info(tb_story_room)');
      final names = columns.map((column) => column['name']).toSet();
      expect(
          names,
          containsAll([
            'speakerStrategy',
            'avoidRepeatSpeaker',
            'maxAutoTotalTokens',
          ]));

      final room = StoryRoomModel.fromJson({
        'title': '旧调度房间',
        'speakerStrategy': 'unexpected',
        'avoidRepeatSpeaker': 0,
        'maxAutoTotalTokens': 999999,
      });
      expect(room.speakerStrategy, StorySpeakerStrategy.smart);
      expect(room.avoidRepeatSpeaker, isFalse);
      expect(room.maxAutoTotalTokens, 32768);
      expect(room.toJson()['speakerStrategy'], StorySpeakerStrategy.smart);
      expect(room.toJson()['avoidRepeatSpeaker'], 0);
      expect(room.toJson()['maxAutoTotalTokens'], 32768);
      expect(
        StoryRoomModel.fromJson({'title': '边界'}).maxAutoTotalTokens,
        4096,
      );
      expect(
        StoryRoomModel.fromJson({
          'title': '边界',
          'maxAutoTotalTokens': 1,
        }).maxAutoTotalTokens,
        256,
      );

      final roomId = await dao.saveRoom(room);
      final saved = await dao.getRoom(roomId);
      expect(saved?.speakerStrategy, StorySpeakerStrategy.smart);
      expect(saved?.avoidRepeatSpeaker, isFalse);
      expect(saved?.maxAutoTotalTokens, 32768);
      final renamed = saved?.copyWith(title: '新名字');
      expect(renamed?.speakerStrategy, StorySpeakerStrategy.smart);
      expect(renamed?.avoidRepeatSpeaker, isFalse);
      expect(renamed?.maxAutoTotalTokens, 32768);
    });

    test('旧参与者表迁移稳定键和角色状态列', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'create table tb_story_participant (id integer primary key autoincrement'
        ', roomId integer not null, assistantId integer, role text, name text'
        ', prompt text, avatarType text, avatarValue text, voiceStyle text'
        ', sortOrder integer, enabled integer, createdAt integer, updatedAt integer)',
      );
      await db.insert('tb_story_participant', {
        'roomId': 41,
        'role': StoryParticipantRole.assistant,
        'name': '旧角色',
        'enabled': 1,
      });

      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final participant = (await dao.getParticipants(41)).single;
      expect(participant.participantKey, 'legacy-participant-41-1');
      expect(participant.stateSummary, isEmpty);
      await expectLater(
        db.insert('tb_story_participant', {
          'roomId': 41,
          'participantKey': participant.participantKey,
        }),
        throwsA(isA<DatabaseException>()),
      );
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

    test('房间 copyWith 重命名不会丢失运行配置和活动分支', () {
      final room = StoryRoomModel(
        id: 7,
        title: '旧名字',
        worldBookState: 'world-state',
        promptConfigJson: 'prompt-config',
        quickRepliesJson: 'quick-replies',
        regexScriptsJson: 'regex-scripts',
        personaKey: 'persona-key',
        activeMessageKey: 'node-key',
      );

      final renamed = room.copyWith(title: '新名字');

      expect(renamed.title, '新名字');
      expect(renamed.worldBookState, 'world-state');
      expect(renamed.promptConfigJson, 'prompt-config');
      expect(renamed.quickRepliesJson, 'quick-replies');
      expect(renamed.regexScriptsJson, 'regex-scripts');
      expect(renamed.personaKey, 'persona-key');
      expect(renamed.activeMessageKey, 'node-key');
    });

    test('禁用角色默认不参与生成但可由管理界面读取和重新启用', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '群像房间'));
      final participant = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '暂离角色',
        enabled: false,
      );
      await dao.saveParticipant(participant);

      expect(await dao.getParticipants(roomId), isEmpty);
      final managed = await dao.getParticipants(roomId, includeDisabled: true);
      expect(managed.single.name, '暂离角色');
      expect(managed.single.enabled, isFalse);

      managed.single.enabled = true;
      await dao.saveParticipant(managed.single);
      expect((await dao.getParticipants(roomId)).single.enabled, isTrue);
    });

    test('房间消息支持编辑和删除', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '可编辑房间'));
      final message = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '旧内容',
      );
      await dao.saveMessage(message);

      message.content = '新内容';
      final previousUpdatedAt = message.updatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await dao.updateMessage(message);
      expect((await dao.getMessages(roomId)).single.content, '新内容');
      expect(message.updatedAt, greaterThan(previousUpdatedAt));

      await dao.deleteMessage(message.id!);
      expect(await dao.getMessages(roomId), isEmpty);
    });

    test('保存和读取可复用酒馆模板', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final templateDao = await StoryTemplateDao.create(HiDBManager.test(db));
      final template = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: 'Fuka', prompt: '害羞的图书委员。'),
            sourceName: 'fuka.png',
            tavernMeta: const AssistantRoleCardTavernMeta(
              spec: 'chara_card_v2',
              alternateGreetings: ['她轻轻推开门。'],
            ),
          ),
        ],
        initialOpening: '她轻轻推开门。',
      ).toTemplate(
        title: 'Fuka 模板',
        sourceTitle: 'fuka.png',
        translated: true,
      );

      final id = await templateDao.saveTemplate(template);
      final saved = await templateDao.getTemplate(id);
      final list = await templateDao.getTemplates();
      final payload = StoryRoomTemplatePayload.fromTemplate(saved!);

      expect(list, hasLength(1));
      expect(saved.title, 'Fuka 模板');
      expect(saved.sourceTitle, 'fuka.png');
      expect(saved.kind, StoryTemplateKind.tavernRoom);
      expect(saved.translated, isTrue);
      expect(payload.initialOpening, '她轻轻推开门。');
      expect(payload.results.single.assistant.name, 'Fuka');
      expect(payload.results.single.tavernMeta?.spec, 'chara_card_v2');

      saved.title = 'Fuka 模板改名';
      await templateDao.saveTemplate(saved);
      expect((await templateDao.getTemplate(id))?.title, 'Fuka 模板改名');
    });

    test('消息附件字段可保存读取，旧消息表会自动补列', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'create table tb_story_message (id integer primary key autoincrement'
        ', roomId integer not null, speakerId integer, speakerRole text'
        ', speakerName text, speakerAvatarType text, speakerAvatarValue text'
        ', speakerVoiceStyle text, content text, createdAt integer, updatedAt integer)',
      );
      await db.insert('tb_story_message', {
        'roomId': 999,
        'speakerRole': 'user',
        'speakerName': '旧用户',
        'content': '旧消息',
        'createdAt': 1,
        'updatedAt': 1,
      });

      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final legacy = await dao.getMessages(999);
      expect(legacy.single.imagePaths, isEmpty);
      expect(legacy.single.filePaths, isEmpty);
      expect(legacy.single.attachmentContext, isEmpty);

      final roomId = await dao.saveRoom(StoryRoomModel(title: '附件房间'));
      final message = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '请看附件',
        imagePaths: const ['/tmp/cover.png'],
        filePaths: const ['/tmp/world.pdf', '/tmp/notes.txt'],
        attachmentContext: '[附件 notes.txt 内容]',
      );
      await dao.saveMessage(message);

      final saved = (await dao.getMessages(roomId)).single;
      expect(saved.imagePaths, ['/tmp/cover.png']);
      expect(saved.filePaths, ['/tmp/world.pdf', '/tmp/notes.txt']);
      expect(saved.attachmentContext, '[附件 notes.txt 内容]');
    });

    test('旧房间和消息表首次补分支键时回填稳定父链与活动节点', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute(
        'create table tb_story_room (id integer primary key autoincrement'
        ', title text, mode text, replyMode text, maxAutoReplies integer'
        ', publicContext text, worldBookState text, modelProviderId text, modelId text'
        ', temperature real, maxOutputTokens integer, createdAt integer, updatedAt integer)',
      );
      await db.execute(
        'create table tb_story_message (id integer primary key autoincrement'
        ', roomId integer not null, speakerId integer, speakerRole text'
        ', speakerName text, speakerAvatarType text, speakerAvatarValue text'
        ', speakerVoiceStyle text, content text, imagePaths text, imageSources text'
        ', citationUrls text, filePaths text, attachmentContext text'
        ', createdAt integer, updatedAt integer)',
      );
      final roomId = await db.insert('tb_story_room', {
        'title': '旧分支房间',
        'createdAt': 1,
        'updatedAt': 1,
      });
      for (final content in ['一', '二', '三']) {
        await db.insert('tb_story_message', {
          'roomId': roomId,
          'speakerRole': 'user',
          'speakerName': '我',
          'content': content,
          'createdAt': 1,
          'updatedAt': 1,
        });
      }

      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final messages = await dao.getMessages(roomId);
      expect(
        messages.map((message) => message.nodeKey),
        ['legacy-$roomId-1', 'legacy-$roomId-2', 'legacy-$roomId-3'],
      );
      expect(
        messages.map((message) => message.parentNodeKey),
        [null, 'legacy-$roomId-1', 'legacy-$roomId-2'],
      );
      expect(
        messages.map((message) => message.candidateGroupKey),
        ['legacy-$roomId-1', 'legacy-$roomId-2', 'legacy-$roomId-3'],
      );
      expect(
        (await dao.getRoom(roomId))?.activeMessageKey,
        'legacy-$roomId-3',
      );
      expect(await dao.getActiveMessages(roomId), hasLength(3));

      await db.update(
        'tb_story_message',
        {'parentNodeKey': 'legacy-$roomId-1'},
        where: 'id = ?',
        whereArgs: [3],
      );
      await StoryRoomDao.create(HiDBManager.test(db));
      expect(
        (await dao.getMessages(roomId)).last.parentNodeKey,
        'legacy-$roomId-1',
      );
    });

    test('新消息线性接到活动叶，并为候选回复保留显式分组', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '分支房间'));
      final first = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '起点',
        contextStateAfter: '{"location":"书店"}',
      );
      await dao.saveMessage(first);
      final second = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'assistant',
        speakerName: '甲',
        content: '主线',
        contextStateAfter: '{"location":"门口"}',
      );
      await dao.saveMessage(second);
      final alternative = StoryMessageModel(
        roomId: roomId,
        parentNodeKey: first.nodeKey,
        candidateGroupKey: second.candidateGroupKey,
        speakerRole: 'assistant',
        speakerName: '乙',
        content: '候选',
        contextStateAfter: '{"location":"窗边"}',
      );
      await dao.saveMessage(alternative);

      expect(first.parentNodeKey, isNull);
      expect(first.candidateGroupKey, first.nodeKey);
      expect(second.parentNodeKey, first.nodeKey);
      expect(second.candidateGroupKey, second.nodeKey);
      expect(alternative.candidateGroupKey, second.candidateGroupKey);
      expect(
        (await dao.getMessageVariants(roomId, second.candidateGroupKey!))
            .map((message) => message.content),
        ['主线', '候选'],
      );
      expect(
          (await dao.getRoom(roomId))?.activeMessageKey, alternative.nodeKey);
      expect(
        StoryMessageModel.fromJson(alternative.toJson()).contextStateAfter,
        '{"location":"窗边"}',
      );
    });

    test('可切换活动叶，且拒绝其他房间的消息', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '活动路径'));
      final otherRoomId = await dao.saveRoom(StoryRoomModel(title: '另一房间'));
      final root = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '根',
        contextStateAfter: '{"branch":"root"}',
      );
      await dao.saveMessage(root);
      final left = StoryMessageModel(
        roomId: roomId,
        parentNodeKey: root.nodeKey,
        speakerRole: 'assistant',
        speakerName: '左',
        content: '左路',
        contextStateAfter: '{"branch":"left"}',
      );
      await dao.saveMessage(left);
      final right = StoryMessageModel(
        roomId: roomId,
        parentNodeKey: root.nodeKey,
        speakerRole: 'assistant',
        speakerName: '右',
        content: '右路',
        contextStateAfter: '{"branch":"right"}',
      );
      await dao.saveMessage(right);
      final outsider = StoryMessageModel(
        roomId: otherRoomId,
        speakerRole: 'user',
        speakerName: '外部',
        content: '不可切换',
      );
      await dao.saveMessage(outsider);

      expect(await dao.activateMessage(roomId, left.nodeKey), isTrue);
      expect(
        (await dao.getActiveMessages(roomId)).map((message) => message.content),
        ['根', '左路'],
      );
      expect((await dao.getRoom(roomId))?.worldBookState, '{"branch":"left"}');
      expect(await dao.activateMessage(roomId, right.nodeKey), isTrue);
      expect((await dao.getRoom(roomId))?.worldBookState, '{"branch":"right"}');
      expect(await dao.activateMessage(roomId, outsider.nodeKey), isFalse);
      expect((await dao.getRoom(roomId))?.activeMessageKey, right.nodeKey);

      right.contextStateAfter = '{"branch":"right-updated"}';
      await dao.updateMessage(right);
      expect(
        (await dao.getRoom(roomId))?.worldBookState,
        '{"branch":"right-updated"}',
      );
    });

    test('删除子树会回退活动叶并记录所有消息 tombstone', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '删除分支'));
      final root = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '根',
        contextStateAfter: '{"chapter":1}',
      );
      await dao.saveMessage(root);
      final child = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'assistant',
        speakerName: '甲',
        content: '子',
        contextStateAfter: '{"chapter":2}',
      );
      await dao.saveMessage(child);
      final leaf = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '叶',
        contextStateAfter: '{"chapter":3}',
      );
      await dao.saveMessage(leaf);

      await dao.deleteMessageSubtree(roomId, child.nodeKey);
      expect((await dao.getMessages(roomId)).map((message) => message.content),
          ['根']);
      expect((await dao.getRoom(roomId))?.activeMessageKey, root.nodeKey);
      expect((await dao.getRoom(roomId))?.worldBookState, '{"chapter":1}');
      final tombstones = await db.query(
        'tb_sync_tombstone',
        where: 'entity = ?',
        whereArgs: ['story_message'],
        orderBy: 'entityId asc',
      );
      expect(
          tombstones.map((row) => row['entityId']),
          [
            child.nodeKey,
            leaf.nodeKey,
          ]..sort());
    });

    test('保存消息会快照房间参与者状态，并在空状态时保存空对象', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '状态快照'));
      final fuka = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '风香',
        stateSummary: '站在书店门口',
      );
      final empty = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '空状态',
      );
      await dao.saveParticipant(fuka);
      await dao.saveParticipant(empty);

      final first = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '开场',
      );
      await dao.saveMessage(first);
      expect(StoryRoleStateCodec.decode(first.roleStatesAfter), {
        fuka.participantKey: '站在书店门口',
      });

      await dao.updateParticipantState(roomId, fuka.participantKey, '');
      final second = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '无状态',
      );
      await dao.saveMessage(second);
      expect(second.roleStatesAfter, '{}');
    });

    test('切换分支只恢复当前房间的角色长期状态', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '角色分支'));
      final otherRoomId = await dao.saveRoom(StoryRoomModel(title: '隔离房间'));
      final fuka = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '风香',
        stateSummary: '根状态',
      );
      final chandra = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '钱德拉',
        stateSummary: '根同伴状态',
      );
      final outsider = StoryParticipantModel(
        roomId: otherRoomId,
        role: StoryParticipantRole.assistant,
        name: '外部角色',
        stateSummary: '不应改变',
      );
      await dao.saveParticipant(fuka);
      await dao.saveParticipant(chandra);
      await dao.saveParticipant(outsider);
      final root = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '根',
      );
      await dao.saveMessage(root);
      final left = StoryMessageModel(
        roomId: roomId,
        parentNodeKey: root.nodeKey,
        speakerRole: 'assistant',
        speakerName: '左',
        content: '左分支',
        roleStatesAfter: StoryRoleStateCodec.encode({
          fuka.participantKey: '左状态',
          chandra.participantKey: '左同伴状态',
        }),
      );
      await dao.saveMessage(left);
      final right = StoryMessageModel(
        roomId: roomId,
        parentNodeKey: root.nodeKey,
        speakerRole: 'assistant',
        speakerName: '右',
        content: '右分支',
        roleStatesAfter: StoryRoleStateCodec.encode({
          fuka.participantKey: '右状态',
        }),
      );
      await dao.saveMessage(right);

      await dao.activateMessage(roomId, left.nodeKey);
      var participants = await dao.getParticipants(roomId);
      expect(participants.map((item) => item.stateSummary), ['左状态', '左同伴状态']);
      expect(
          (await dao.getParticipants(otherRoomId)).single.stateSummary, '不应改变');

      await dao.activateMessage(roomId, right.nodeKey);
      participants = await dao.getParticipants(roomId);
      expect(participants.map((item) => item.stateSummary), ['右状态', '']);
      expect(
          (await dao.getParticipants(otherRoomId)).single.stateSummary, '不应改变');
    });

    test('删除分支会回退角色状态，当前叶手动更新会同步快照', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final roomId = await dao.saveRoom(StoryRoomModel(title: '状态回退'));
      final fuka = StoryParticipantModel(
        roomId: roomId,
        role: StoryParticipantRole.assistant,
        name: '风香',
        stateSummary: '根状态',
      );
      await dao.saveParticipant(fuka);
      final root = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'user',
        speakerName: '我',
        content: '根',
      );
      await dao.saveMessage(root);
      final branch = StoryMessageModel(
        roomId: roomId,
        speakerRole: 'assistant',
        speakerName: '风香',
        content: '分支',
        roleStatesAfter:
            StoryRoleStateCodec.encode({fuka.participantKey: '分支状态'}),
      );
      await dao.saveMessage(branch);

      expect(
          await dao.updateParticipantState(roomId, fuka.participantKey, '手动状态'),
          isTrue);
      var current = (await dao.getMessages(roomId)).last;
      expect(StoryRoleStateCodec.decode(current.roleStatesAfter), {
        fuka.participantKey: '手动状态',
      });
      expect((await dao.getParticipants(roomId)).single.stateSummary, '手动状态');
      expect(await dao.updateParticipantState(roomId, fuka.participantKey, ''),
          isTrue);
      current = (await dao.getMessages(roomId)).last;
      expect(StoryRoleStateCodec.decode(current.roleStatesAfter), isEmpty);

      await dao.activateMessage(roomId, branch.nodeKey);
      await dao.deleteMessageSubtree(roomId, branch.nodeKey);
      expect((await dao.getParticipants(roomId)).single.stateSummary, '根状态');
      await dao.deleteMessageSubtree(roomId, root.nodeKey);
      expect((await dao.getParticipants(roomId)).single.stateSummary, isEmpty);
    });

    test('角色状态 codec 会过滤空值并安全处理坏 JSON', () {
      expect(StoryRoleStateCodec.decode('{bad json'), isEmpty);
      expect(StoryRoleStateCodec.decode('[]'), isEmpty);
      expect(StoryRoleStateCodec.decode('{"a":"ok","":"x","b":" "}'), {
        'a': 'ok',
      });
      expect(
        StoryRoleStateCodec.encode({' a ': ' ok ', '': 'x', 'b': ''}),
        '{"a":"ok"}',
      );
      expect(
          StoryMessageModel.fromJson({
            'roomId': 1,
            'speakerRole': 'user',
            'speakerName': '我',
          }).roleStatesAfter,
          isEmpty);
    });

    test('坏链的活动路径会在环或缺父处安全停止', () async {
      final one = StoryMessageModel(
        roomId: 1,
        nodeKey: 'one',
        parentNodeKey: 'two',
        speakerRole: 'user',
        speakerName: '我',
        content: '一',
      );
      final two = StoryMessageModel(
        roomId: 1,
        nodeKey: 'two',
        parentNodeKey: 'one',
        speakerRole: 'assistant',
        speakerName: '甲',
        content: '二',
      );
      final orphan = StoryMessageModel(
        roomId: 1,
        nodeKey: 'orphan',
        parentNodeKey: 'missing',
        speakerRole: 'assistant',
        speakerName: '乙',
        content: '孤儿',
      );

      expect(
        StoryRoomDao.activePath([one, two], 'two')
            .map((message) => message.nodeKey),
        ['one', 'two'],
      );
      expect(
        StoryRoomDao.activePath([orphan], 'orphan')
            .map((message) => message.nodeKey),
        ['orphan'],
      );
    });
  });

  group('StoryRoomSettingsResolver', () {
    test('本地模式应用房间服务商、模型和生成参数且不修改全局设置', () {
      final global = AISettings.defaults();
      final room = StoryRoomModel(
        title: '导演房',
        modelProviderId: 'openai',
        modelId: 'gpt-4o-mini',
        temperature: 0.35,
        maxOutputTokens: 8192,
      );

      final resolved = StoryRoomSettingsResolver.apply(room, global);

      expect(resolved.activeProviderId, 'openai');
      expect(resolved.effectiveModel, 'gpt-4o-mini');
      expect(resolved.temperature, 0.35);
      expect(resolved.maxOutputTokens, 8192);
      expect(global.activeProviderId, isNot('openai'));
    });

    test('后端模式只覆盖房间模型并保留全局跟随项', () {
      final global = AISettings.defaults()
        ..mode = AIMode.backend
        ..backendModel = 'global-model'
        ..temperature = 0.8
        ..maxOutputTokens = 2048;
      final room = StoryRoomModel(title: '创作房', modelId: 'room-model');

      final resolved = StoryRoomSettingsResolver.apply(room, global);

      expect(resolved.backendModel, 'room-model');
      expect(resolved.temperature, 0.8);
      expect(resolved.maxOutputTokens, 2048);
      expect(global.backendModel, 'global-model');
    });
  });

  group('StoryParticipantSettingsResolver', () {
    test('角色覆盖叠加到房间设置且不修改原设置', () {
      final roomSettings = AISettings.defaults()
        ..activeProviderId = 'deepseek'
        ..setActiveModel('deepseek-chat')
        ..temperature = 0.8
        ..maxOutputTokens = 2048;
      final participant = StoryParticipantModel(
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '角色',
        modelProviderId: 'openai',
        modelId: 'gpt-4o-mini',
        temperature: 0.25,
        maxOutputTokens: 4096,
      );

      final resolved =
          StoryParticipantSettingsResolver.apply(roomSettings, participant);

      expect(resolved.activeProviderId, 'openai');
      expect(resolved.effectiveModel, 'gpt-4o-mini');
      expect(resolved.temperature, 0.25);
      expect(resolved.maxOutputTokens, 4096);
      expect(roomSettings.activeProviderId, 'deepseek');
      expect(roomSettings.effectiveModel, 'deepseek-chat');
      expect(roomSettings.temperature, 0.8);
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
        avatarType: 'image',
        avatarValue: '/cards/yes-my-liege.png',
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
          creator: 'card maker',
          characterVersion: '1.2.3',
          createDate: '2026-07-01',
          updateDate: '2026-07-02',
          source: 'https://example.com/cards/yml',
          creatorNotes: '作者建议慢热推进。',
          systemPrompt: '保持沉浸。',
          postHistoryInstructions: '延续上一幕情绪。',
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
      expect(room?.publicContext, contains('作者：card maker'));
      expect(room?.publicContext, contains('角色版本：1.2.3'));
      expect(room?.publicContext, contains('创建时间：2026-07-01'));
      expect(room?.publicContext, contains('更新时间：2026-07-02'));
      expect(room?.publicContext, contains('来源：https://example.com/cards/yml'));
      expect(room?.publicContext, contains('作者备注：作者建议慢热推进。'));
      expect(room?.publicContext, contains('系统提示：保持沉浸。'));
      expect(room?.publicContext, contains('后续指令：延续上一幕情绪。'));
      expect(room?.publicContext, contains('世界书：YMLv2'));
      expect(room?.publicContext, contains('扫描深度：50'));
      expect(room?.publicContext, contains('Alt opening A'));
      final participants = await dao.getParticipants(roomId);
      expect(participants.map((item) => item.name), [
        'Chandra',
        'Medli',
        'The Ice Queen',
      ]);
      expect(participants.every((item) => item.avatarType == 'image'), isTrue);
      expect(
        participants
            .every((item) => item.avatarValue == '/cards/yes-my-liege.png'),
        isTrue,
      );
      expect(participants.first.prompt, contains('passionate'));
      final messages = await dao.getMessages(roomId);
      expect(messages, hasLength(1));
      expect(messages.single.speakerName, '开场');
      expect(messages.single.content, 'Alt opening B');
    });

    test('单角色卡包含场景和世界书字段时不自动建议酒馆房间', () {
      final assistant = AssistantModel(
        name: 'Dr. Moon',
        description:
            'Scenario: private research interview. World book and lorebook entries describe background facts.',
        prompt:
            'Name: Dr. Moon\nType: character\nPersonality: calm researcher.',
      )..memoryBook = [
          '[p=10] Foundation => A secret organization in the scenario.',
          'Containment sites and research protocols.',
          '[p=10] Reality Anchor => A background device from the lorebook.',
          'It stabilizes abnormal events.',
        ].join('\n');

      expect(
        StoryRoomRoleCardImporter.shouldSuggestTavernRoom(assistant),
        isFalse,
      );
    });

    test('双人角色卡名称或描述命中时建议酒馆房间', () {
      final assistant = AssistantModel(
        name: 'Aria & Amelia',
        description: 'Aria and Amelia are loyal maid twins.',
        prompt: 'Aria is bold. Amelia is timid.',
      );

      expect(
        StoryRoomRoleCardImporter.shouldSuggestTavernRoom(assistant),
        isTrue,
      );
    });

    test('双人角色卡导入酒馆房间时会拆成多个参与者', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final assistant = AssistantModel(
        name: 'Aria & Amelia',
        description: 'Aria and Amelia are loyal maid twins.',
        prompt: 'Aria is bold. Amelia is timid.',
        avatarType: 'image',
        avatarValue: '/cards/aria-amelia.png',
      )..openingMessage = 'The twin maids wait by the door.';

      final roomId =
          await StoryRoomRoleCardImportService(dao).importAsTavernRoom(
        assistant,
        title: assistant.name,
      );

      final room = await dao.getRoom(roomId);
      expect(room?.replyMode, StoryReplyMode.autoMulti);
      expect(room?.maxAutoReplies, 2);
      final participants = await dao.getParticipants(roomId);
      expect(participants.map((item) => item.name), ['Aria', 'Amelia']);
      expect(participants.every((item) => item.avatarType == 'image'), isTrue);
      expect(
        participants.every(
          (item) => item.avatarValue == '/cards/aria-amelia.png',
        ),
        isTrue,
      );
      expect(participants.first.prompt, contains('当前你只扮演：Aria'));
      expect(participants.last.prompt, contains('当前你只扮演：Amelia'));
      final messages = await dao.getMessages(roomId);
      expect(messages.single.content, 'The twin maids wait by the door.');

      final template = StoryRoomTemplatePayload(
        results: [AssistantRoleCardImportResult(assistant: assistant)],
        initialOpening: assistant.openingMessage,
      ).toTemplate(title: assistant.name);
      expect(
        StoryRoomRoleCardImporter.countTemplateParticipants(
          StoryRoomTemplatePayload.fromTemplate(template),
          title: template.title,
        ),
        2,
      );
    });

    test('单条合并名世界书角色导入酒馆房间时会拆成多个参与者', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final assistant = AssistantModel(
        name: 'Aria & Amelia',
        description: 'Twin maid character card.',
        prompt: 'Shared setting for both twins.',
      )..memoryBook = [
          'Twins => Name: Aria & Amelia',
          'Type: character',
          'Personality: Aria is bold. Amelia is timid.',
        ].join('\n');

      final roomId =
          await StoryRoomRoleCardImportService(dao).importAsTavernRoom(
        assistant,
        title: assistant.name,
      );

      final room = await dao.getRoom(roomId);
      final participants = await dao.getParticipants(roomId);
      expect(room?.replyMode, StoryReplyMode.autoMulti);
      expect(participants.map((item) => item.name), ['Aria', 'Amelia']);
      expect(participants.first.prompt, contains('Name: Aria & Amelia'));
      expect(participants.first.prompt, contains('当前你只扮演：Aria'));
      expect(participants.last.prompt, contains('当前你只扮演：Amelia'));

      final template = StoryRoomTemplatePayload(
        results: [AssistantRoleCardImportResult(assistant: assistant)],
      ).toTemplate(title: assistant.name);
      expect(
        StoryRoomRoleCardImporter.countTemplateParticipants(
          StoryRoomTemplatePayload.fromTemplate(template),
          title: template.title,
        ),
        2,
      );
    });

    test('两个世界书角色条目会建议酒馆房间', () {
      final assistant = AssistantModel(name: 'Twin Scene')
        ..memoryBook = [
          'Aria => Name: Aria',
          'Type: character',
          'Personality: bold.',
          '',
          'Amelia => Name: Amelia',
          'Type: character',
          'Personality: timid.',
        ].join('\n');

      expect(
        StoryRoomRoleCardImporter.shouldSuggestTavernRoom(assistant),
        isTrue,
      );
    });

    test('单卡导入默认开场为空时使用 Tavern 备选开场', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final assistant = AssistantModel(
        name: 'Fuka',
        prompt: '害羞的图书委员。',
      );

      final roomId =
          await StoryRoomRoleCardImportService(dao).importAsTavernRoom(
        assistant,
        title: 'Fuka Room',
        tavernMeta: const AssistantRoleCardTavernMeta(
          alternateGreetings: ['', '她轻轻推开图书馆的门。'],
        ),
      );

      final messages = await dao.getMessages(roomId);
      expect(messages, hasLength(1));
      expect(messages.single.content, '她轻轻推开图书馆的门。');
    });

    test('V3 群聊元数据会恢复到房间上下文且不凭空拆分参与者', () {
      final assistant = AssistantRoleCardService.importJson(jsonEncode({
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'data': {
          'name': 'Archivist',
          'nickname': '馆长',
          'description': '{{char}} 守护着档案塔。',
          'personality': '克制。',
          'first_mes': '',
          'mes_example': '',
          'group_only_greetings': ['{{char}} 在群聊里展开档案。'],
          'extensions': {
            'talkativeness': 0.7,
            'depth_prompt': {
              'prompt': '{{char}} 会先核对档案编号。',
              'depth': 6,
              'role': 'system',
            },
          },
        },
      }));

      final plan = StoryRoomRoleCardImporter.buildPlan(
        assistant,
        roomId: 0,
        title: '档案塔',
      );

      expect(plan.participants, hasLength(1));
      expect(plan.room.replyMode, StoryReplyMode.autoSingle);
      expect(plan.room.publicContext, contains('角色注释插入深度：6'));
      expect(plan.room.publicContext, contains('群聊活跃度：0.7'));
      expect(plan.room.publicContext, contains('群聊专属开场：馆长 在群聊里展开档案。'));
      expect(
          plan.room.publicContext, isNot(contains('chatai_deep.tavern_raw')));
      expect(
        StoryRoomRoleCardImporter.initialSceneMessage(assistant),
        '馆长 在群聊里展开档案。',
      );
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

    test('批量导入酒馆房间会自动生成多角色开场', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final fuka = AssistantModel(name: 'Fuka')..openingMessage = '她抱紧书本，站在门边。';
      final chandra = AssistantModel(name: 'Chandra')
        ..openingMessage = '火焰在她掌心亮起。';
      final silent = AssistantModel(name: 'Silent');

      final roomId =
          await StoryRoomRoleCardImportService(dao).importBatchAsTavernRoom(
        [
          AssistantRoleCardImportResult(assistant: fuka),
          AssistantRoleCardImportResult(assistant: chandra),
          AssistantRoleCardImportResult(assistant: silent),
        ],
        title: 'Imported Tavern',
      );

      final messages = await dao.getMessages(roomId);
      expect(messages, hasLength(1));
      expect(
        messages.single.content,
        [
          '【Fuka】',
          '她抱紧书本，站在门边。',
          '',
          '【Chandra】',
          '火焰在她掌心亮起。',
        ].join('\n'),
      );
    });

    test('批量导入酒馆房间可从备选开场生成房间开场', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dao = await StoryRoomDao.create(HiDBManager.test(db));
      final fuka = AssistantModel(name: 'Fuka');

      final roomId =
          await StoryRoomRoleCardImportService(dao).importBatchAsTavernRoom(
        [
          AssistantRoleCardImportResult(
            assistant: fuka,
            tavernMeta: const AssistantRoleCardTavernMeta(
              alternateGreetings: ['她从书架后探出头。'],
            ),
          ),
        ],
        title: 'Imported Tavern',
      );

      final messages = await dao.getMessages(roomId);
      expect(messages.single.content, '【Fuka】\n她从书架后探出头。');
    });

    test('可从保存的酒馆模板重复创建新房间', () async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final dbManager = HiDBManager.test(db);
      final dao = await StoryRoomDao.create(dbManager);
      final templateDao = await StoryTemplateDao.create(dbManager);
      final fuka = AssistantModel(
        name: 'Fuka',
        description: '害羞的图书委员。',
        prompt: '说话轻声，容易紧张。',
      )..openingMessage = '她抱紧书本，站在门边。';
      final chandra = AssistantModel(
        name: 'Chandra',
        description: '火焰将军。',
        prompt: '自信、直接。',
      );
      final template = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(assistant: fuka),
          AssistantRoleCardImportResult(assistant: chandra),
        ],
        initialOpening: fuka.openingMessage,
        promptConfigJson: '{"version":1,"modules":[]}',
        quickRepliesJson: '{"roomId":0,"groups":[]}',
      ).toTemplate(
        title: 'Imported Tavern',
        sourceTitle: 'cards.zip',
        translated: true,
      );
      await templateDao.saveTemplate(template);

      final importer = StoryRoomRoleCardImportService(dao);
      final firstId = await importer.createRoomFromTemplate(
        template,
        title: 'Imported Tavern A',
      );
      final secondId = await importer.createRoomFromTemplate(
        template,
        title: 'Imported Tavern B',
      );
      template.payload = StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(assistant: fuka),
          AssistantRoleCardImportResult(assistant: chandra),
        ],
        initialOpening: '新的模板开场。',
      )
          .toTemplate(
            title: template.title,
            sourceTitle: template.sourceTitle,
            translated: template.translated,
          )
          .payload;
      final thirdId = await importer.createRoomFromTemplate(
        template,
        title: 'Imported Tavern C',
      );

      final first = await dao.getRoom(firstId);
      final second = await dao.getRoom(secondId);
      final third = await dao.getRoom(thirdId);
      expect(first?.title, 'Imported Tavern A');
      expect(second?.title, 'Imported Tavern B');
      expect(third?.title, 'Imported Tavern C');
      expect(first?.promptConfigJson, '{"version":1,"modules":[]}');
      expect(first?.quickRepliesJson, '{"roomId":0,"groups":[]}');
      expect(await dao.getParticipants(firstId), hasLength(2));
      expect(await dao.getParticipants(secondId), hasLength(2));
      expect(await dao.getParticipants(thirdId), hasLength(2));
      expect(
          (await dao.getMessages(firstId)).single.content, fuka.openingMessage);
      expect((await dao.getMessages(secondId)).single.content,
          fuka.openingMessage);
      expect((await dao.getMessages(thirdId)).single.content, '新的模板开场。');
    });

    test('多角色世界书导入时跳过明确非角色条目', () {
      final participants =
          StoryRoomRoleCardImporter.parseMemoryBookParticipants(
        [
          'Chandra => Name: Chandra',
          'Type: character',
          'Personality: proud general.',
          '',
          'Florin => Name: Florin',
          'Type: location',
          'Description: A bright kingdom.',
          '',
          'Medli => Name: Medli',
          '性格：温柔但坚定。',
        ].join('\n'),
        roomId: 1,
      );

      expect(participants.map((item) => item.name), ['Chandra', 'Medli']);
      expect(participants.first.prompt, contains('proud general'));
      expect(participants.last.prompt, contains('温柔但坚定'));
    });

    test('多角色世界书可用条目标题补全角色名', () {
      final participants =
          StoryRoomRoleCardImporter.parseMemoryBookParticipants(
        [
          '# Medli',
          'companion => Type: character',
          'Personality: gentle scout.',
          '',
          '# 这个条目用于镜厅谜题。',
          '镜子 => 镜子背后藏着暗门。',
        ].join('\n'),
        roomId: 1,
      );

      expect(participants.map((item) => item.name), ['Medli']);
      expect(participants.single.prompt, contains('gentle scout'));
    });
  });

  test('Tavern 声明式 Prompt Manager 与文本 Quick Replies 会进入房间配置', () {
    final assistant = AssistantRoleCardService.importJson(jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': '艾琳',
        'description': '雨夜书店店员',
        'personality': '冷静',
        'extensions': {
          'prompt_manager': {
            'prompts': [
              {
                'identifier': 'weather',
                'content': '{{room}} 正在下雨。',
                'position': 'in_chat',
                'depth': 1,
              },
            ],
            'order': [
              {'identifier': 'weather', 'enabled': true},
            ],
          },
          'quick_replies': {
            'sets': [
              {
                'name': '动作',
                'items': [
                  {'id': 'look', 'label': '观察', 'message': '环顾四周。'},
                  {'id': 'script', 'label': '脚本', 'command': '/setvar x=1'},
                ],
              },
            ],
          },
          'regex_scripts': [
            {
              'scriptName': '去除旁白标签',
              'findRegex': r'/\[旁白\](.*)/i',
              'replaceString': r'$1',
              'placement': [2],
            },
          ],
        },
      },
    }));
    final plan = StoryRoomRoleCardImporter.buildPlan(
      assistant,
      roomId: 0,
      title: '测试酒馆',
    );
    final prompts = StoryPromptConfigCodec.decode(plan.room.promptConfigJson);
    final quick = StoryQuickReplyCollectionModel.tryParse(
      plan.room.quickRepliesJson,
    );
    final regex = StoryRegexScriptsCodec.decode(plan.room.regexScriptsJson);

    expect(prompts.modules.any((item) => item.key == 'tavern.weather'), isTrue);
    expect(quick.groups.single.label, '动作');
    expect(quick.groups.single.items.map((item) => item.key), ['look']);
    expect(regex.rules.single.name, '去除旁白标签');
    expect(regex.rules.single.caseSensitive, isFalse);
  });

  group('StoryContextBuilder', () {
    test('Persona 名称与简介进入上下文并解析 user 变量', () {
      final room = StoryRoomModel(
        title: '月下酒馆',
        mode: StoryRoomMode.tavern,
        publicContext: '{{user}} 刚从北境来到这里。',
      );
      final speaker = StoryParticipantModel(
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '艾琳',
      );
      final persona = StoryPersonaModel(
        personaKey: 'traveler',
        name: '旅人洛安',
        description: '来自北境，左手有一道旧伤。',
      );

      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        persona: persona,
      );

      expect(system, contains('【当前用户 Persona】'));
      expect(system, contains('名称：旅人洛安'));
      expect(system, contains('来自北境，左手有一道旧伤。'));
      expect(system, contains('旅人洛安 刚从北境来到这里。'));
      expect(system, isNot(contains('{{user}}')));
    });

    test('Persona 简介可触发仅扫描用户身份的世界书条目', () {
      final room = StoryRoomModel(
        title: '北境旅店',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【关键词记忆 / 世界书】',
          '[persona] 旧伤 => 旅店老板认出了这道北境军团留下的伤疤。',
        ].join('\n'),
      );
      final speaker = StoryParticipantModel(
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '老板',
        prompt: '谨慎地识别来客。',
      );
      final persona = StoryPersonaModel(
        personaKey: 'north-traveler',
        name: '旅人洛安',
        description: '来自北境，左手有一道旧伤。',
      );

      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        persona: persona,
        latestInput: '你好。',
      );

      expect(system, contains('老板认出了这道北境军团留下的伤疤'));
    });

    test('Prompt Manager 保留安全规则、角色顺序、历史开关和深度插入', () {
      final room = StoryRoomModel(
        title: '雨夜书店',
        mode: StoryRoomMode.tavern,
        promptConfigJson: StoryPromptConfigCodec.encode(
          const StoryPromptConfig(modules: [
            StoryPromptModule(
              key: 'builtin.rules',
              builtInSlot: StoryPromptBuiltInSlot.rules,
              enabled: false,
              role: StoryPromptRole.user,
              sortOrder: 20,
            ),
            StoryPromptModule(
              key: 'custom.before',
              content: '{{room}} 的钟声响起。',
              role: StoryPromptRole.user,
              sortOrder: 10,
            ),
            StoryPromptModule(
              key: 'custom.depth',
              content: '{{char}} 记得门没有锁。',
              role: StoryPromptRole.assistant,
              placement: StoryPromptPlacement.historyDepth,
              depth: 1,
              sortOrder: 30,
            ),
            StoryPromptModule(
              key: 'builtin.input',
              builtInSlot: StoryPromptBuiltInSlot.input,
              content: '本轮输入：{{input}}',
              placement: StoryPromptPlacement.historyDepth,
              role: StoryPromptRole.user,
              sortOrder: 40,
            ),
          ]),
        ),
      );
      final speaker = StoryParticipantModel(
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '艾琳',
      );
      final result = StoryContextBuilder.buildSystemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        latestInput: '你听见了吗？',
      );
      final history = result.applyToHistory([
        {'role': 'user', 'content': '这条历史应被关闭'},
      ]);

      expect(result.prompt, contains('酒馆规则：'));
      expect(result.leadingMessages.first['role'], StoryPromptRole.user);
      expect(result.leadingMessages.first['content'], contains('雨夜书店'));
      expect(result.leadingMessages.last['role'], StoryPromptRole.system);
      expect(result.includeHistory, isFalse);
      expect(result.worldBookHits, isEmpty);
      expect(history.any((item) => item['content'] == '这条历史应被关闭'), isFalse);
      final depthMessage = history.singleWhere(
        (item) => '${item['content']}'.contains('艾琳 记得门没有锁'),
      );
      expect(depthMessage['role'], StoryPromptRole.assistant);
      expect(result.inputPrompt, contains('你听见了吗？'));
      expect(result.inputPrompt, contains('本轮输入：你听见了吗？'));
    });

    test('按 Tavern depth_prompt 的深度和角色插入历史消息', () {
      final room = StoryRoomModel(
        title: '实验室',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息：Dr. Moon】',
          '角色注释：她会隐藏真实目的。',
          '第二行注释仍属于 depth prompt。',
          '角色注释插入深度：1',
          '角色注释角色：assistant',
          '世界书：实验室设定',
        ].join('\n'),
      );
      final speaker = StoryParticipantModel(
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Dr. Moon',
      );
      final history = StoryContextBuilder.history(
        [
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'user',
            speakerName: '我',
            content: '第一条',
          ),
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'assistant',
            speakerName: 'Dr. Moon',
            content: '第二条',
          ),
        ],
        room: room,
        speaker: speaker,
      );

      expect(history, hasLength(3));
      expect(history[1]['role'], 'assistant');
      expect(history[1]['content'], contains('隐藏真实目的'));
      expect(history[1]['content'], contains('第二行注释'));
      expect(history[2]['content'], contains('第二条'));
    });

    test('depth_prompt 超出历史范围时安全插到开头并回退 system role', () {
      final room = StoryRoomModel(
        title: '房间',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息】',
          '角色注释：保持沉默。',
          '角色注释插入深度：99',
          '角色注释角色：unknown',
        ].join('\n'),
      );
      final history = StoryContextBuilder.history(
        [
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'user',
            speakerName: '我',
            content: '你好',
          ),
        ],
        room: room,
      );

      expect(history.first['role'], 'system');
      expect(history.first['content'], '保持沉默。');
    });

    test('上下文窗口保留最近消息、开场和旧剧情连续状态', () {
      final room = StoryRoomModel(title: '钟楼谜案', mode: StoryRoomMode.tavern);
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '安静观察。',
      );
      final messages = <StoryMessageModel>[
        StoryMessageModel(
          roomId: 1,
          speakerRole: StoryParticipantRole.assistant,
          speakerName: '开场',
          content: '雨夜的钟楼传来第三次钟声。',
        ),
        StoryMessageModel(
          roomId: 1,
          speakerRole: 'user',
          speakerName: '我',
          content: '我把银钥匙交给 Fuka。',
        ),
        StoryMessageModel(
          roomId: 1,
          speakerRole: StoryParticipantRole.assistant,
          speakerName: 'Fuka',
          content: 'Fuka 收好银钥匙，决定先去地下室。',
        ),
        StoryMessageModel(
          roomId: 1,
          speakerRole: StoryParticipantRole.assistant,
          speakerName: '守钟人',
          content: '守钟人留在塔顶监视街道。',
        ),
        for (var index = 0; index < 12; index++)
          StoryMessageModel(
            roomId: 1,
            speakerRole: index.isEven ? 'user' : StoryParticipantRole.assistant,
            speakerName: index.isEven ? '我' : 'Fuka',
            content: '最近剧情 $index',
          ),
      ];

      final history = StoryContextBuilder.history(messages);
      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [fuka],
        speaker: fuka,
        recentMessages: messages,
      );

      expect(history, hasLength(12));
      expect(history.first['content'], '最近剧情 0');
      expect(history.last['content'], 'Fuka：最近剧情 11');
      expect(history.map((item) => item['content']),
          isNot(contains('我把银钥匙交给 Fuka。')));
      expect(system, contains('【长期剧情记忆】'));
      expect(system, contains('【系统开场】'));
      expect(system, contains('雨夜的钟楼传来第三次钟声。'));
      expect(system, contains('【连续状态】'));
      expect(system, contains('Fuka：Fuka 收好银钥匙，决定先去地下室。'));
      expect(system, contains('守钟人：守钟人留在塔顶监视街道。'));
      expect(system, contains('【旧剧情摘要】'));
    });

    test('上下文摘要在相同输入下保持确定性并受字符预算限制', () {
      final messages = List.generate(
        20,
        (index) => StoryMessageModel(
          roomId: 1,
          speakerRole: index.isEven ? 'user' : StoryParticipantRole.assistant,
          speakerName: index.isEven ? '我' : 'Fuka',
          content: '第 $index 幕 ${'剧情内容' * 80}',
        ),
      );
      final first = StoryContextWindow.fromMessages(messages).summary(
        maxCharacters: 300,
      );
      final second = StoryContextWindow.fromMessages(messages).summary(
        maxCharacters: 300,
      );

      expect(first, second);
      expect(first.length, lessThanOrEqualTo(300));
      expect(first, contains('【连续状态】'));
    });

    test('区分公共上下文、当前发言者人设和多 speaker 历史', () {
      final room = StoryRoomModel(title: '雨夜书店', publicContext: '城市里有魔法。');
      final author = StoryParticipantModel(
        id: 1,
        roomId: 1,
        role: StoryParticipantRole.author,
        name: '作者',
        stateSummary: '正在追踪第一章尚未回收的伏笔。',
      );
      final fuka = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '害羞，避免主动与陌生人对视。',
        stateSummary: '仍然紧张，双手攥着衣角；已经答应回答用户的问题。',
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
      expect(system, contains('【当前分支角色长期状态】'));
      expect(system, contains('- 作者：正在追踪第一章尚未回收的伏笔。'));
      expect(system, contains('- Fuka：仍然紧张，双手攥着衣角；已经答应回答用户的问题。'));

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

    test('酒馆原卡扫描深度限制默认世界书最近消息范围', () {
      final room = StoryRoomModel(
        title: '镜厅',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息】',
          '扫描深度：1',
          '',
          '【关键词记忆 / 世界书】',
          '旧钟声 => 旧钟声不在房间扫描深度内时不触发。',
          '镜子 => 镜子在最近一轮内会触发。',
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
            content: '两轮前听见旧钟声。',
          ),
          StoryMessageModel(
            roomId: 1,
            speakerRole: 'user',
            speakerName: '我',
            content: '上一轮看见镜子。',
          ),
        ],
      );

      expect(system, isNot(contains('旧钟声不在房间扫描深度内时不触发')));
      expect(system, contains('镜子在最近一轮内会触发'));
    });

    test('酒馆原卡递归扫描会用已命中世界书继续触发相关条目', () {
      final room = StoryRoomModel(
        title: '镜厅',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息】',
          '递归扫描：开启',
          '',
          '【关键词记忆 / 世界书】',
          '镜子 => 镜子背后藏着暗门。',
          '暗门 => 暗门后通向地下书库。',
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
        latestInput: '我看见了镜子。',
      );

      expect(system, contains('镜子背后藏着暗门'));
      expect(system, contains('暗门后通向地下书库'));
    });

    test('酒馆世界书防递归条目不会继续触发相关条目', () {
      final room = StoryRoomModel(
        title: '镜厅',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息】',
          '递归扫描：开启',
          '',
          '【关键词记忆 / 世界书】',
          '[norec] 镜子 => 镜子背后藏着暗门。',
          '暗门 => 暗门后通向地下书库。',
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
        latestInput: '我看见了镜子。',
      );

      expect(system, contains('镜子背后藏着暗门'));
      expect(system, isNot(contains('暗门后通向地下书库')));
    });

    test('酒馆世界书同组条目只注入权重最高版本', () {
      final room = StoryRoomModel(
        title: '钟楼',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【关键词记忆 / 世界书】',
          '[group=bell] [gw=1] 钟声 => 低权重钟声设定。',
          '[group=bell] [gw=9] 钟声 => 高权重钟声设定。',
          '钟声 => 无分组公共设定。',
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
        latestInput: '钟声响了。',
      );

      expect(system, contains('高权重钟声设定'));
      expect(system, contains('无分组公共设定'));
      expect(system, isNot(contains('低权重钟声设定')));
    });

    test('酒馆原卡 Token 预算会裁剪最终注入的世界书文本', () {
      final room = StoryRoomModel(
        title: '镜厅',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【Tavern 原卡信息】',
          'Token 预算：20',
          '',
          '【关键词记忆 / 世界书】',
          '镜子 => 这是一个非常非常非常长的镜子设定，后半段不应该完整出现。',
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
        latestInput: '我看见了镜子。',
      );

      expect(system, contains('这是一个非常非常'));
      expect(system, contains('...'));
      expect(system, isNot(contains('后半段不应该完整出现')));
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

    test('酒馆世界书兼容 after char 位置别名', () {
      final room = StoryRoomModel(
        title: '训练场',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【关键词记忆 / 世界书】',
          '[pos=after char] 剑术 => 这条应注入到角色人设之后。',
        ].join('\n'),
      );
      final fuka = StoryParticipantModel(
        id: 1,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: 'Fuka',
        prompt: '谨慎观察。',
      );

      final system = StoryContextBuilder.systemPrompt(
        room: room,
        participants: [fuka],
        speaker: fuka,
        latestInput: '你会剑术吗？',
      );

      expect(system, contains('【本轮命中世界书 / 角色后置】'));
      expect(system, contains('这条应注入到角色人设之后。'));
      expect(
        system.indexOf('【当前发言者人设 / 写作职责】'),
        lessThan(system.indexOf('【本轮命中世界书 / 角色后置】')),
      );
      expect(
        system,
        isNot(contains('【本轮命中世界书】\n命中角色记忆')),
      );
    });

    test('酒馆房间世界书匹配会忽略导入备注注释', () {
      final room = StoryRoomModel(
        title: '镜厅',
        mode: StoryRoomMode.tavern,
        publicContext: [
          '【关键词记忆 / 世界书】',
          '# 这个条目用于镜厅谜题。',
          '镜子 => 镜子背后藏着暗门。',
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
        latestInput: '我看见了镜子。',
      );

      expect(system, contains('镜子背后藏着暗门'));
      expect(system, isNot(contains('这个条目用于镜厅谜题')));
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
      expect(system, contains('@角色名'));
      expect(system, contains('smart'));
      expect(StorySpeakerScheduler.promptFor('你好'), contains('用户最新输入'));
    });

    test('酒馆世界书 sticky cooldown delay 跨轮生效且回退消息会清理未来状态', () {
      final room = StoryRoomModel(
        id: 1,
        title: '钟楼',
        mode: StoryRoomMode.tavern,
        publicContext: '''
【关键词记忆 / 世界书】
[sticky=2] [cooldown=2] [delay=2] 钟声 => 钟楼暗门已经开启。
''',
      );
      final speaker = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '艾琳',
      );
      StoryMessageModel message(int index) => StoryMessageModel(
            id: index,
            roomId: 1,
            speakerRole: 'user',
            speakerName: '我',
            content: '历史 $index',
          );

      final first = StoryContextBuilder.buildSystemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        latestInput: '我听见钟声',
        recentMessages: [message(1)],
      );
      expect(first.prompt, contains('钟楼暗门已经开启'));
      room.worldBookState = jsonEncode(first.worldBookState.toJson());

      final sticky = StoryContextBuilder.buildSystemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        latestInput: '现在很安静',
        recentMessages: [message(1), message(2)],
      );
      expect(sticky.prompt, contains('钟楼暗门已经开启'));

      final cooldown = StoryContextBuilder.buildSystemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        latestInput: '钟声再次响起',
        recentMessages: [message(1), message(2), message(3), message(4)],
      );
      expect(cooldown.prompt, isNot(contains('钟楼暗门已经开启')));

      final rolledBack = StoryContextBuilder.buildSystemPrompt(
        room: room,
        participants: [speaker],
        speaker: speaker,
        latestInput: '没有关键词',
      );
      expect(rolledBack.prompt, isNot(contains('钟楼暗门已经开启')));
      expect(rolledBack.worldBookState.activations, isEmpty);
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

    test('smart 调度优先点名，并识别全角 @ 和直接姓名', () {
      final aili = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '艾莉',
      );
      final ailisi = StoryParticipantModel(
        id: 3,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '艾莉丝',
      );
      final room = StoryRoomModel(title: '点名房间');

      expect(
        StorySpeakerScheduler.mentionedCandidates(
          input: '＠艾莉丝，请回答。',
          candidates: [aili, ailisi],
        ).map((candidate) => candidate.id),
        [3],
      );
      expect(
        StorySpeakerScheduler.schedule(
          room: room,
          input: '艾莉丝，你怎么看？',
          candidates: [aili, ailisi],
          recentMessages: [
            StoryMessageModel(
              roomId: 1,
              speakerId: 3,
              speakerRole: StoryParticipantRole.assistant,
              speakerName: '艾莉丝',
              content: '上一句。',
            ),
          ],
        ).single.id,
        3,
      );
    });

    test('smart 调度在未点名时避免重复，只有一人时允许连续', () {
      final first = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '甲',
      );
      final second = StoryParticipantModel(
        id: 3,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '乙',
      );
      final history = [
        StoryMessageModel(
          roomId: 1,
          speakerRole: StoryParticipantRole.assistant,
          speakerName: '甲',
          content: '旧消息没有 speakerId。',
        ),
      ];

      expect(
        StorySpeakerScheduler.smartCandidates(
          input: '继续。',
          candidates: [first, second],
          recentMessages: history,
        ).single.id,
        3,
      );
      expect(
        StorySpeakerScheduler.smartCandidates(
          input: '继续。',
          candidates: [first],
          recentMessages: history,
        ).single.id,
        2,
      );
    });

    test('round robin 依序跳过禁用候选且不重复', () {
      final first = StoryParticipantModel(
        id: 2,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '甲',
        sortOrder: 10,
      );
      final previous = StoryParticipantModel(
        id: 3,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '乙',
        sortOrder: 20,
      );
      final disabled = StoryParticipantModel(
        id: 4,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '禁用',
        sortOrder: 30,
        enabled: false,
      );
      final third = StoryParticipantModel(
        id: 5,
        roomId: 1,
        role: StoryParticipantRole.assistant,
        name: '丙',
        sortOrder: 40,
      );
      final room = StoryRoomModel(
        title: '轮换房间',
        speakerStrategy: StorySpeakerStrategy.roundRobin,
      );

      expect(
        StorySpeakerScheduler.schedule(
          room: room,
          input: '@甲 也请说说。',
          candidates: [third, disabled, previous, first],
          recentMessages: [
            StoryMessageModel(
              roomId: 1,
              speakerId: 3,
              speakerRole: StoryParticipantRole.assistant,
              speakerName: '乙',
              content: '上一句。',
            ),
          ],
          maxCount: 3,
        ).map((candidate) => candidate.id),
        [5, 2, 3],
      );
    });
  });
}
