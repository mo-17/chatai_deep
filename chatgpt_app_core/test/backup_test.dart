import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 阶段八（备份恢复）验收测试：导出/导入 round-trip、API key 脱敏、
/// 覆盖式恢复、外键修复、非法文件与版本校验。全部走真实
/// BackupService + DAO（HiDBManager.test 注入 ffi 内存库）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));

  /// 造一套有代表性的数据：助手 + 绑定它的会话 + 带 blocks 的消息 + 收藏。
  Future<int> seed(HiDBManager storage) async {
    final assistantDao = await AssistantDao.create(storage);
    final aid = await assistantDao
        .saveAssistant(AssistantModel(name: '审查员', prompt: '你是代码审查员'));
    final projectDao = await ProjectDao.create(storage);
    final project = ProjectModel(name: '项目A');
    await projectDao.saveProject(project);
    final convDao = await ConversationListDao.create(storage);
    await convDao.saveConversation(ConversationModel(
        cid: 1001, icon: '', assistantId: aid, projectId: project.id)
      ..title = '绑定助手的会话'
      ..stickTime = 0
      ..updateAt = 1);
    await convDao.saveConversation(ConversationModel(cid: 1002, icon: '')
      ..title = '普通会话'
      ..stickTime = 0
      ..updateAt = 2);
    await MessageDao.create(storage, cid: 1001);
    await storage.db.insert('tb_messages', {
      'cid': 1001,
      'content': '你好',
      'createdAt': 111,
      'ownerName': 'user',
      'ownerType': 'sender',
    });
    await storage.db.insert('tb_messages', {
      'cid': 1001,
      'content': '答案正文',
      'createdAt': 222,
      'ownerName': 'AI',
      'ownerType': 'receiver',
      'blocks': MessageBlock.encodeList(const [
        MainTextBlock(
          id: 'b1',
          messageId: 'msg_222',
          createdAt: 222,
          status: MessageBlockStatus.success,
          content: '答案正文',
        ),
        RoleContextBlock(
          id: 'role_ctx_222',
          messageId: 'msg_222',
          createdAt: 222,
          status: MessageBlockStatus.success,
          content: '[当前命中的角色记忆]\n- 钟声代表潮汐',
          memoryBudget: AssistantMemoryContextBudget(
            context: '[当前命中的角色记忆]\n- 钟声代表潮汐',
            matchedCount: 3,
            includedCount: 1,
            skippedCount: 2,
            truncated: true,
            maxContextChars: 80,
            usedChars: 60,
          ),
          memoryHits: [
            AssistantMemoryEntryPreview(
              keywords: ['钟声'],
              content: '钟声代表潮汐',
              alwaysOn: false,
              priority: 5,
            ),
          ],
        ),
      ]),
    });
    await FavoriteDao.create(storage);
    await storage.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '收藏内容', 'createdAt': 333});
    final templateDao = await StoryTemplateDao.create(storage);
    await templateDao.saveTemplate(
      StoryRoomTemplatePayload(
        results: [
          AssistantRoleCardImportResult(
            assistant: AssistantModel(name: '酒馆角色', prompt: '保持沉浸。'),
          ),
        ],
        initialOpening: '夜色降临。',
      ).toTemplate(
        title: '酒馆模板',
        sourceTitle: 'card.png',
        translated: true,
      ),
    );
    return aid!;
  }

  Future<Map<String, int>> seedStoryRoom(
    HiDBManager storage, {
    int? assistantId,
    String title = '雨夜酒馆',
  }) async {
    final dao = await StoryRoomDao.create(storage);
    final room = StoryRoomModel(
      title: title,
      mode: StoryRoomMode.tavern,
      replyMode: StoryReplyMode.autoMulti,
      maxAutoReplies: 3,
      publicContext: '旧城区的雨夜酒馆',
    );
    final roomId = await dao.saveRoom(room);
    final participant = StoryParticipantModel(
      roomId: roomId,
      assistantId: assistantId,
      role: StoryParticipantRole.assistant,
      name: '风香',
      prompt: '内向但敏锐',
      avatarType: 'emoji',
      avatarValue: '📚',
      sortOrder: 1,
    );
    final participantId = await dao.saveParticipant(participant);
    final message = StoryMessageModel(
      roomId: roomId,
      speakerId: participantId,
      speakerRole: participant.role,
      speakerName: participant.name,
      speakerAvatarType: participant.avatarType,
      speakerAvatarValue: participant.avatarValue,
      content: '她抬起头，看向门口。',
      createdAt: 777,
    );
    final messageId = await dao.saveMessage(message);
    return {
      'roomId': roomId,
      'participantId': participantId,
      'messageId': messageId,
    };
  }

  List<int> zipOf(Map<String, Object> files) {
    final archive = Archive();
    files.forEach((name, content) {
      archive
          .addFile(ArchiveFile.bytes(name, utf8.encode(jsonEncode(content))));
    });
    return ZipEncoder().encodeBytes(archive);
  }

  group('酒馆房间备份', () {
    test('导出、预览和覆盖恢复保留房间/参与者/消息关联与统计', () async {
      final src = await newDb();
      final aid = await seed(src);
      final sourceIds = await seedStoryRoom(src, assistantId: aid);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      await seedStoryRoom(dst, title: '本地旧酒馆');
      final preview = await BackupService(dst).previewArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(preview.storyRooms, 1);
      expect(preview.storyParticipants, 1);
      expect(preview.storyMessages, 1);
      expect(preview.totalRows, greaterThanOrEqualTo(3));
      expect(
        preview.conflictSummary.tableConflicts
            .firstWhere((item) => item.table == 'tb_story_room')
            .replacingRows,
        1,
      );
      final mergePlan = preview.planFor(BackupImportMode.mergeAppend);
      expect(mergePlan.backupOnlyRows, greaterThanOrEqualTo(3));

      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(result.storyRooms, 1);
      expect(result.storyParticipants, 1);
      expect(result.storyMessages, 1);
      expect(await dst.db.query('tb_story_room'), hasLength(1));
      expect(await dst.db.query('tb_story_participant'), hasLength(1));
      final messages = await dst.db.query('tb_story_message');
      expect(messages, hasLength(1));
      expect(messages.single['roomId'], sourceIds['roomId']);
      expect(messages.single['speakerId'], sourceIds['participantId']);
      expect(messages.single['content'], '她抬起头，看向门口。');
      await dst.db.close();
    });

    test('合并恢复遇到相同 ID 时重映射房间、参与者和消息发言者', () async {
      final src = await newDb();
      final srcAid = await (await AssistantDao.create(src)).saveAssistant(
        AssistantModel(name: '源角色', prompt: '源角色设定'),
      );
      await seedStoryRoom(src, assistantId: srcAid, title: '源酒馆');
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      final dstAid = await (await AssistantDao.create(dst)).saveAssistant(
        AssistantModel(name: '本地角色', prompt: '本地角色设定'),
      );
      final localIds = await seedStoryRoom(
        dst,
        assistantId: dstAid,
        title: '本地酒馆',
      );
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );

      expect(result.storyRooms, 1);
      expect(result.storyParticipants, 1);
      expect(result.storyMessages, 1);
      expect(result.warnings.join('\n'), contains('酒馆房间 ID'));
      expect(await dst.db.query('tb_story_room'), hasLength(2));
      expect(await dst.db.query('tb_story_participant'), hasLength(2));
      expect(await dst.db.query('tb_story_message'), hasLength(2));
      final importedRoom = (await dst.db.query(
        'tb_story_room',
        where: 'title = ?',
        whereArgs: ['源酒馆'],
      ))
          .single;
      final importedRoomId = importedRoom['id'] as int;
      expect(importedRoomId, isNot(localIds['roomId']));
      final importedParticipant = (await dst.db.query(
        'tb_story_participant',
        where: 'roomId = ?',
        whereArgs: [importedRoomId],
      ))
          .single;
      final importedParticipantId = importedParticipant['id'] as int;
      expect(importedParticipantId, isNot(localIds['participantId']));
      final importedMessage = (await dst.db.query(
        'tb_story_message',
        where: 'roomId = ?',
        whereArgs: [importedRoomId],
      ))
          .single;
      expect(importedMessage['speakerId'], importedParticipantId);
      expect(importedParticipant['assistantId'], isNot(dstAid));
      await dst.db.close();
    });

    test('旧备份没有酒馆文件时仍可覆盖导入并统计为零', () async {
      final dst = await newDb();
      await seedStoryRoom(dst, title: '待被清理的酒馆');
      final bytes = zipOf({
        'manifest.json': {'formatVersion': 1, 'accountHash': 'acc1'},
        'conversations.json': <Object>[],
        'assistants.json': <Object>[],
      });

      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(result.storyRooms, 0);
      expect(result.storyParticipants, 0);
      expect(result.storyMessages, 0);
      expect(await dst.db.query('tb_story_room'), isEmpty);
      expect(await dst.db.query('tb_story_participant'), isEmpty);
      expect(await dst.db.query('tb_story_message'), isEmpty);
      await dst.db.close();
    });
  });

  group('导出/导入 round-trip', () {
    test('导入前预览只读数量、账号和资源，不修改数据库', () async {
      final src = await newDb();
      await seed(src);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
        includeApiKeys: true,
      );
      await src.db.close();

      final dst = await newDb();
      final convDao = await ConversationListDao.create(dst);
      await convDao.saveConversation(ConversationModel(cid: 9001, icon: '')
        ..title = '本地会话'
        ..stickTime = 0);
      final tickBefore = BackupService.restoreTick.value;

      final preview =
          await BackupService(dst).previewArchive(bytes, accountHash: 'acc2');

      expect(preview.formatVersion, BackupService.formatVersion);
      expect(preview.accountHash, 'acc1');
      expect(preview.includeApiKeys, isTrue);
      expect(preview.hasSettings, isTrue);
      expect(preview.conversations, 2);
      expect(preview.messages, 2);
      expect(preview.assistants, 1);
      expect(preview.favorites, 1);
      expect(preview.projects, 1);
      expect(preview.storyTemplates, 1);
      expect(preview.totalRows, greaterThan(0));
      expect(preview.warnings.single, contains('其他账号'));
      expect(preview.conflictSummary.localRows, 1);
      expect(preview.conflictSummary.replacingRows, 0);
      expect(preview.conflictSummary.localOnlyRows, 1);
      expect(preview.conflictSummary.backupOnlyRows, greaterThan(0));
      expect(preview.conflictSummary.hasConflict, isTrue);
      expect(BackupService.restoreTick.value, tickBefore);

      final local =
          await dst.db.query('tb_conversation_list', where: 'cid = 9001');
      expect(local.single['title'], '本地会话');
      await dst.db.close();
    });

    test('导入前预览识别同 ID 覆盖风险', () async {
      final src = await newDb();
      await seed(src);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      final convDao = await ConversationListDao.create(dst);
      await convDao.saveConversation(ConversationModel(cid: 1001, icon: '')
        ..title = '本地同 cid 会话'
        ..stickTime = 0);

      final preview =
          await BackupService(dst).previewArchive(bytes, accountHash: 'acc1');

      expect(preview.warnings, isEmpty);
      expect(preview.conflictSummary.localRows, 1);
      expect(preview.conflictSummary.replacingRows, 1);
      expect(preview.conflictSummary.localOnlyRows, 0);
      expect(preview.conflictSummary.changedRows, 1);
      expect(preview.conflictSummary.hasConflict, isTrue);
      final conversationConflict = preview.conflictSummary.tableConflicts
          .firstWhere((item) => item.table == 'tb_conversation_list');
      expect(conversationConflict.replacingRows, 1);
      expect(conversationConflict.changedRows, 1);
      expect(conversationConflict.replacingSamples, ['1001']);
      await dst.db.close();
    });

    test('导入计划按导入方式汇总预计覆盖、新增和仅本地删除数量', () async {
      final src = await newDb();
      await seed(src);
      final srcKnowledgeDao = await KnowledgeDao.create(src);
      await srcKnowledgeDao.addDocument('备份资料', 'Backup knowledge');
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      final convDao = await ConversationListDao.create(dst);
      await convDao.saveConversation(ConversationModel(cid: 1001, icon: '')
        ..title = '本地同 cid 会话'
        ..stickTime = 0);
      await convDao.saveConversation(ConversationModel(cid: 9999, icon: '')
        ..title = '仅本地会话'
        ..stickTime = 0);
      await AssistantDao.create(dst);
      await dst.db.insert(
        'tb_assistant',
        AssistantModel(name: '本地助手').toJson()..['id'] = 999,
      );
      final dstKnowledgeDao = await KnowledgeDao.create(dst);
      await dstKnowledgeDao.addDocument('本地资料', 'Local knowledge');

      try {
        final preview =
            await BackupService(dst).previewArchive(bytes, accountHash: 'acc1');

        final overwrite = preview.planFor(BackupImportMode.overwriteAll);
        expect(overwrite.scope, '覆盖全部数据');
        expect(overwrite.replacingRows, greaterThanOrEqualTo(1));
        expect(overwrite.localOnlyRows, greaterThan(0));

        final projectConversations =
            preview.planFor(BackupImportMode.projectConversationsOnly);
        expect(projectConversations.scope, '仅项目、会话和消息');
        expect(projectConversations.replacingRows, 1);
        expect(projectConversations.localOnlyRows, 1);
        expect(projectConversations.backupOnlyRows, greaterThan(0));

        final assistants = preview.planFor(BackupImportMode.assistantsOnly);
        expect(assistants.scope, '仅助手');
        expect(assistants.localOnlyRows, 1);
        expect(assistants.backupOnlyRows, 1);

        final knowledge = preview.planFor(BackupImportMode.knowledgeBaseOnly);
        expect(knowledge.scope, '仅知识库');
        expect(knowledge.localRows, greaterThan(0));
        expect(
            knowledge.replacingRows + knowledge.backupOnlyRows, greaterThan(0));
      } finally {
        await dst.db.close();
      }
    });

    test('数据完整往返：会话/消息(blocks)/助手/收藏/设置', () async {
      final src = await newDb();
      final aid = await seed(src);
      final settings = AISettings.defaults();
      settings.providers.firstWhere((p) => p.id == 'openai').apiKey =
          'sk-secret';

      final bytes = await BackupService(src).exportArchive(
          settings: settings, accountHash: 'acc1', includeApiKeys: true);
      await src.db.close();

      // 导入到全新空库
      final dst = await newDb();
      final tickBefore = BackupService.restoreTick.value;
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');

      expect(result.conversations, 2);
      expect(result.messages, 2);
      expect(result.assistants, 1);
      expect(result.favorites, 1);
      expect(result.projects, 1);
      expect(result.storyTemplates, 1);
      expect(result.warnings, isEmpty);
      expect(
          result.settings!.providers.firstWhere((p) => p.id == 'openai').apiKey,
          'sk-secret');
      expect(BackupService.restoreTick.value, tickBefore + 1);

      // 会话与助手的绑定关系保留（原始 id 不变）
      final convs =
          await dst.db.query('tb_conversation_list', where: 'cid = 1001');
      expect(convs.single['assistantId'], aid);
      expect(convs.single['projectId'], isNotNull);
      final projectRows = await dst.db.query('tb_project');
      expect(projectRows.single['name'], '项目A');
      final assistant =
          await (await AssistantDao.create(dst)).getAssistant(aid);
      expect(assistant!.name, '审查员');
      final restoredTemplates =
          await (await StoryTemplateDao.create(dst)).getTemplates();
      expect(restoredTemplates, hasLength(1));
      expect(restoredTemplates.single.title, '酒馆模板');
      final restoredTemplatePayload =
          StoryRoomTemplatePayload.fromTemplate(restoredTemplates.single);
      expect(restoredTemplatePayload.results.single.assistant.name, '酒馆角色');
      expect(restoredTemplatePayload.initialOpening, '夜色降临。');
      // blocks 列原样恢复，包含可追溯的角色上下文快照。
      final msgs = await dst.db.query('tb_messages', where: 'createdAt = 222');
      final restoredBlocks =
          MessageBlock.decodeList(msgs.single['blocks'] as String);
      expect(restoredBlocks.whereType<MainTextBlock>().single.content, '答案正文');
      final roleBlock = restoredBlocks.whereType<RoleContextBlock>().single;
      expect(roleBlock.content, contains('钟声代表潮汐'));
      expect(roleBlock.memoryBudget?.matchedCount, 3);
      expect(roleBlock.memoryBudget?.includedCount, 1);
      expect(roleBlock.memoryBudget?.skippedCount, 2);
      expect(roleBlock.memoryBudget?.truncated, isTrue);
      expect(roleBlock.memoryHits, hasLength(1));
      expect(roleBlock.memoryHits.single.label, '钟声 · p=5');
      expect(roleBlock.memoryHits.single.content, '钟声代表潮汐');
      await dst.db.close();
    });

    test('覆盖式恢复：导入后旧数据被清掉', () async {
      final src = await newDb();
      await seed(src);
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();

      final dst = await newDb();
      final convDao = await ConversationListDao.create(dst);
      await convDao.saveConversation(ConversationModel(cid: 9999, icon: '')
        ..title = '导入前的本地会话'
        ..stickTime = 0);
      await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      final old =
          await dst.db.query('tb_conversation_list', where: 'cid = 9999');
      expect(old, isEmpty, reason: '覆盖式恢复应清空旧数据');
      await dst.db.close();
    });

    test('仅导入知识库：不影响会话/助手/收藏/项目，只替换知识库数据', () async {
      final src = await newDb();
      await ProjectDao.create(src);
      await src.db.insert(
          'tb_project', ProjectModel(name: '共享项目').toJson()..['id'] = 77);
      final srcKnowledgeDao = await KnowledgeDao.create(src);
      final importedDocId =
          await srcKnowledgeDao.addDocument('导入资料', 'Alpha imported knowledge');
      await srcKnowledgeDao.setProjectDocIds(77, [importedDocId!]);
      await srcKnowledgeDao.setProjectDocIds(999, [importedDocId]);
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();

      final dst = await newDb();
      final aid = await seed(dst);
      await ProjectDao.create(dst);
      await dst.db.insert(
          'tb_project', ProjectModel(name: '共享项目').toJson()..['id'] = 77);
      final dstKnowledgeDao = await KnowledgeDao.create(dst);
      await dstKnowledgeDao.addDocument('本地旧资料', 'Local old knowledge');

      final tickBefore = BackupService.restoreTick.value;
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.knowledgeBaseOnly,
      );

      expect(result.conversations, 0);
      expect(result.messages, 0);
      expect(result.assistants, 0);
      expect(result.favorites, 0);
      expect(result.projects, 0);
      expect(result.knowledgeDocs, 1);
      expect(result.knowledgeChunks, greaterThan(0));
      expect(result.projectKnowledge, 1);
      expect(result.settings, isNull);
      expect(result.warnings.single, contains('无法匹配当前项目'));
      expect(BackupService.restoreTick.value, tickBefore + 1);

      expect(await dst.db.query('tb_conversation_list'), hasLength(2));
      expect(await dst.db.query('tb_assistant'), hasLength(1));
      expect(
          await (await AssistantDao.create(dst)).getAssistant(aid), isNotNull);
      expect(await dst.db.query('tb_favorite'), hasLength(1));
      expect(await dst.db.query('tb_project'), hasLength(2));
      final docs = await dstKnowledgeDao.getDocuments();
      expect(docs.single.title, '导入资料');
      expect(await dstKnowledgeDao.getProjectDocIds(77), [importedDocId]);
      await dst.db.close();
    });

    test('仅导入助手：替换助手列表并清理无效助手引用，不影响其它数据', () async {
      final src = await newDb();
      await AssistantDao.create(src);
      await src.db.insert(
        'tb_assistant',
        AssistantModel(name: '导入助手', prompt: 'Imported prompt').toJson()
          ..['id'] = 880,
      );
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();

      final dst = await newDb();
      final localAid = await seed(dst);
      final projectRows = await dst.db.query('tb_project');
      final localProjectId = projectRows.first['id'] as int;
      await dst.db.update(
        'tb_project',
        {'defaultAssistantId': localAid},
        where: 'id = ?',
        whereArgs: [localProjectId],
      );
      final localKnowledgeDao = await KnowledgeDao.create(dst);
      await localKnowledgeDao.addDocument('本地资料', 'Local knowledge stays');

      final tickBefore = BackupService.restoreTick.value;
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.assistantsOnly,
      );

      expect(result.assistants, 1);
      expect(result.conversations, 0);
      expect(result.messages, 0);
      expect(result.favorites, 0);
      expect(result.projects, 0);
      expect(result.knowledgeDocs, 0);
      expect(result.settings, isNull);
      expect(result.warnings, hasLength(2));
      expect(result.warnings.join('\n'), contains('解除绑定'));
      expect(result.warnings.join('\n'), contains('默认助手'));
      expect(BackupService.restoreTick.value, tickBefore + 1);

      final assistants = await dst.db.query('tb_assistant');
      expect(assistants, hasLength(1));
      expect(assistants.single['id'], 880);
      expect(assistants.single['name'], '导入助手');
      expect(await dst.db.query('tb_conversation_list'), hasLength(2));
      expect(await dst.db.query('tb_messages'), hasLength(2));
      expect(await dst.db.query('tb_favorite'), hasLength(1));
      expect(await dst.db.query('tb_project'), hasLength(1));
      final conv = await dst.db
          .query('tb_conversation_list', where: 'cid = ?', whereArgs: [1001]);
      expect(conv.single['assistantId'], isNull);
      final project = await dst.db
          .query('tb_project', where: 'id = ?', whereArgs: [localProjectId]);
      expect(project.single['defaultAssistantId'], isNull);
      final docs = await localKnowledgeDao.getDocuments();
      expect(docs.single.title, '本地资料');
      await dst.db.close();
    });

    test('仅导入项目和会话：保留助手/收藏/知识库/设置并恢复附件', () async {
      final dir =
          await Directory.systemTemp.createTemp('backup-project-conv-asset-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final sourceFile = File('${dir.path}/project-note.txt');
      await sourceFile.writeAsString('project attachment');

      final src = await newDb();
      await AssistantDao.create(src);
      await src.db.insert(
        'tb_assistant',
        AssistantModel(name: '备份助手').toJson()..['id'] = 880,
      );
      await ProjectDao.create(src);
      await src.db.insert(
          'tb_project',
          ProjectModel(name: '导入项目', defaultAssistantId: 880).toJson()
            ..['id'] = 77);
      final srcConvDao = await ConversationListDao.create(src);
      await srcConvDao.saveConversation(ConversationModel(
          cid: 7001, icon: '', assistantId: 880, projectId: 77)
        ..title = '导入会话'
        ..stickTime = 0
        ..updateAt = 11);
      await srcConvDao.saveConversation(ConversationModel(
          cid: 7002, icon: '', assistantId: 880, projectId: 999)
        ..title = '无效项目会话'
        ..stickTime = 0
        ..updateAt = 12);
      await MessageDao.create(src, cid: 7001);
      final block = FileBlock(
        id: 'file_project',
        messageId: 'msg_project',
        createdAt: 7,
        status: MessageBlockStatus.success,
        file: FileMetadata(
          name: 'project-note.txt',
          path: sourceFile.path,
          mime: 'text/plain',
          size: await sourceFile.length(),
          extractedText: 'project extracted text',
        ),
      );
      await src.db.insert('tb_messages', {
        'cid': 7001,
        'content': '导入消息',
        'createdAt': 777,
        'ownerName': 'user',
        'ownerType': 'sender',
        'blocks': MessageBlock.encodeList([block]),
      });
      await FavoriteDao.create(src);
      await src.db.insert('tb_favorite',
          {'ownerName': 'AI', 'content': '备份收藏不应导入', 'createdAt': 888});
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults()..tavilyApiKey = 'backup-key',
        accountHash: 'acc1',
        includeApiKeys: true,
      );
      await src.db.close();

      final dst = await newDb();
      final localAid = await seed(dst);
      final localKnowledgeDao = await KnowledgeDao.create(dst);
      final localDocId =
          await localKnowledgeDao.addDocument('本地资料', 'Local knowledge stays');
      final localProjectId =
          (await dst.db.query('tb_project')).single['id'] as int;
      await localKnowledgeDao.setProjectDocIds(localProjectId, [localDocId!]);

      final tickBefore = BackupService.restoreTick.value;
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.projectConversationsOnly,
      );

      expect(result.projects, 1);
      expect(result.conversations, 2);
      expect(result.messages, 1);
      expect(result.assistants, 0);
      expect(result.favorites, 0);
      expect(result.knowledgeDocs, 0);
      expect(result.settings, isNull);
      expect(result.warnings.join('\n'), contains('本地助手列表'));
      expect(result.warnings.join('\n'), contains('未分类'));
      expect(result.warnings.join('\n'), contains('项目知识库绑定'));
      expect(BackupService.restoreTick.value, tickBefore + 1);

      final assistants = await dst.db.query('tb_assistant');
      expect(assistants, hasLength(1));
      expect(assistants.single['id'], localAid);
      expect(await dst.db.query('tb_favorite'), hasLength(1));
      final docs = await localKnowledgeDao.getDocuments();
      expect(docs.single.title, '本地资料');
      expect(await dst.db.query('tb_project_kb'), isEmpty);

      final projects = await dst.db.query('tb_project');
      expect(projects, hasLength(1));
      expect(projects.single['id'], 77);
      expect(projects.single['name'], '导入项目');
      expect(projects.single['defaultAssistantId'], isNull);
      expect(await dst.db.query('tb_conversation_list', where: 'cid = 1001'),
          isEmpty);
      final imported = await dst.db
          .query('tb_conversation_list', where: 'cid = ?', whereArgs: [7001]);
      expect(imported.single['assistantId'], isNull);
      expect(imported.single['projectId'], 77);
      final invalidProject = await dst.db
          .query('tb_conversation_list', where: 'cid = ?', whereArgs: [7002]);
      expect(invalidProject.single['projectId'], isNull);

      final rows = await dst.db.query('tb_messages', where: 'createdAt = 777');
      final restoredBlock =
          MessageBlock.decodeList(rows.single['blocks'] as String).single
              as FileBlock;
      expect(restoredBlock.file.path, isNot(sourceFile.path));
      expect(await File(restoredBlock.file.path!).readAsString(),
          'project attachment');
      expect(restoredBlock.file.extractedText, 'project extracted text');
      await dst.db.close();
    });

    test('合并导入：保留本地数据，重映射 cid/id 并修复消息和知识库绑定', () async {
      final src = await newDb();
      await AssistantDao.create(src);
      await src.db.insert(
        'tb_assistant',
        AssistantModel(name: '导入助手', prompt: 'Imported prompt').toJson()
          ..['id'] = 880,
      );
      await ProjectDao.create(src);
      await src.db.insert(
        'tb_project',
        ProjectModel(name: '导入项目', defaultAssistantId: 880).toJson()
          ..['id'] = 77,
      );
      final srcConvDao = await ConversationListDao.create(src);
      await srcConvDao.saveConversation(
        ConversationModel(cid: 1001, icon: '', assistantId: 880, projectId: 77)
          ..title = '导入会话'
          ..stickTime = 0
          ..updateAt = 77,
      );
      await MessageDao.create(src, cid: 1001);
      await src.db.insert('tb_messages', {
        'cid': 1001,
        'content': '导入消息',
        'createdAt': 777,
        'ownerName': 'user',
        'ownerType': 'sender',
      });
      await FavoriteDao.create(src);
      await src.db.insert('tb_favorite',
          {'ownerName': 'AI', 'content': '导入收藏', 'createdAt': 888});
      final srcKnowledgeDao = await KnowledgeDao.create(src);
      final srcDocId =
          await srcKnowledgeDao.addDocument('导入资料', 'Imported knowledge body');
      await srcKnowledgeDao.setProjectDocIds(77, [srcDocId!]);
      await (await StoryTemplateDao.create(src)).saveTemplate(
        StoryRoomTemplatePayload(
          results: [
            AssistantRoleCardImportResult(
              assistant: AssistantModel(name: '导入酒馆角色'),
            ),
          ],
        ).toTemplate(title: '导入酒馆模板', translated: true),
      );
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults()..tavilyApiKey = 'backup-key',
        accountHash: 'acc1',
        includeApiKeys: true,
      );
      await src.db.close();

      final dst = await newDb();
      final localAid = await seed(dst);
      final dstKnowledgeDao = await KnowledgeDao.create(dst);
      final localDocId =
          await dstKnowledgeDao.addDocument('本地资料', 'Local knowledge stays');
      final localProjectId =
          (await dst.db.query('tb_project')).single['id'] as int;
      await dstKnowledgeDao.setProjectDocIds(localProjectId, [localDocId!]);

      final tickBefore = BackupService.restoreTick.value;
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );

      expect(result.projects, 1);
      expect(result.conversations, 1);
      expect(result.messages, 1);
      expect(result.assistants, 1);
      expect(result.favorites, 1);
      expect(result.knowledgeDocs, 1);
      expect(result.knowledgeChunks, greaterThan(0));
      expect(result.projectKnowledge, 1);
      expect(result.storyTemplates, 1);
      expect(result.settings, isNull);
      expect(result.warnings.join('\n'), contains('cid 与本地冲突'));
      expect(BackupService.restoreTick.value, tickBefore + 1);

      final localConversation = await dst.db
          .query('tb_conversation_list', where: 'cid = ?', whereArgs: [1001]);
      expect(localConversation.single['title'], '绑定助手的会话');
      expect(localConversation.single['assistantId'], localAid);

      final importedConversation = await dst.db.query(
        'tb_conversation_list',
        where: 'title = ?',
        whereArgs: ['导入会话'],
      );
      expect(importedConversation, hasLength(1));
      final importedCid = importedConversation.single['cid'] as int;
      expect(importedCid, isNot(1001));
      final importedAssistantId =
          importedConversation.single['assistantId'] as int;
      final importedProjectId = importedConversation.single['projectId'] as int;
      expect(importedAssistantId, isNot(880));
      expect(importedProjectId, isNot(77));

      final importedAssistant = await dst.db.query(
        'tb_assistant',
        where: 'id = ?',
        whereArgs: [importedAssistantId],
      );
      expect(importedAssistant.single['name'], '导入助手');
      final importedProject = await dst.db.query(
        'tb_project',
        where: 'id = ?',
        whereArgs: [importedProjectId],
      );
      expect(importedProject.single['name'], '导入项目');
      expect(importedProject.single['defaultAssistantId'], importedAssistantId);

      final importedMessages = await dst.db.query(
        'tb_messages',
        where: 'createdAt = ?',
        whereArgs: [777],
      );
      expect(importedMessages.single['cid'], importedCid);
      expect(
          await dst.db.query('tb_messages', where: 'cid = 1001'), hasLength(2));

      expect(await dst.db.query('tb_favorite'), hasLength(2));
      final importedDocs = await dst.db.query(
        'tb_kb_doc',
        where: 'title = ?',
        whereArgs: ['导入资料'],
      );
      expect(importedDocs, hasLength(1));
      final importedDocId = importedDocs.single['id'] as int;
      expect(importedDocId, isNot(srcDocId));
      final importedChunks = await dst.db.query(
        'tb_kb_chunk',
        where: 'docId = ?',
        whereArgs: [importedDocId],
      );
      expect(importedChunks, isNotEmpty);
      final importedProjectKnowledge = await dst.db.query('tb_project_kb',
          where: 'projectId = ? and docId = ?',
          whereArgs: [importedProjectId, importedDocId]);
      expect(importedProjectKnowledge, hasLength(1));

      final mergedTemplates =
          await (await StoryTemplateDao.create(dst)).getTemplates();
      expect(mergedTemplates.map((item) => item.title), contains('导入酒馆模板'));
      expect(mergedTemplates.map((item) => item.title), contains('酒馆模板'));
      expect(
          await dstKnowledgeDao.getProjectDocIds(localProjectId), [localDocId]);
      await dst.db.close();
    });

    test('默认脱敏：includeApiKeys=false 时备份里的 key 为空', () async {
      final src = await newDb();
      final settings = AISettings.defaults()..tavilyApiKey = 'tv-secret';
      settings.providers.firstWhere((p) => p.id == 'openai').apiKey =
          'sk-secret';
      settings.providers.firstWhere((p) => p.id == 'deepseek').apiKey =
          'dk-secret';
      final bytes = await BackupService(src)
          .exportArchive(settings: settings, accountHash: 'acc1');
      await src.db.close();

      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      final restored = result.settings!;
      expect(restored.providers.firstWhere((p) => p.id == 'openai').apiKey, '');
      expect(
          restored.providers.firstWhere((p) => p.id == 'deepseek').apiKey, '');
      expect(restored.tavilyApiKey, '');
      // 原设置对象不被改动（导出用的是 clone）
      expect(settings.providers.firstWhere((p) => p.id == 'openai').apiKey,
          'sk-secret');
      await dst.db.close();
    });

    test('账号不一致时导入成功但带告警', () async {
      final src = await newDb();
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc2');
      expect(result.warnings.single, contains('其他账号'));
      await dst.db.close();
    });

    test('v2 备份包含知识库文档、chunks 与项目绑定', () async {
      final src = await newDb();
      final projectDao = await ProjectDao.create(src);
      final projectId =
          await projectDao.saveProject(ProjectModel(name: '项目 A'));
      final knowledgeDao = await KnowledgeDao.create(src);
      final docId =
          await knowledgeDao.addDocument('项目资料', 'Alpha 需求说明。\n\nBeta 技术方案。');
      await knowledgeDao.setProjectDocIds(projectId!, [docId!]);
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();

      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.knowledgeDocs, 1);
      expect(result.knowledgeChunks, greaterThan(0));
      expect(result.projectKnowledge, 1);
      final docs = await dst.db.query('tb_kb_doc');
      final chunks = await dst.db.query('tb_kb_chunk');
      final refs = await dst.db.query('tb_project_kb');
      expect(docs.single['title'], '项目资料');
      expect(chunks, isNotEmpty);
      expect(refs.single['projectId'], projectId);
      expect(refs.single['docId'], docId);
      final restoredDao = await KnowledgeDao.create(dst);
      expect(
          (await restoredDao.search('Alpha', projectId: projectId))
              .single
              .docTitle,
          '项目资料');
      await dst.db.close();
    });

    test('v2 备份包含附件原始文件，并在导入后重写 FileBlock.path', () async {
      final dir = await Directory.systemTemp.createTemp('backup-file-asset-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final sourceFile = File('${dir.path}/note.txt');
      await sourceFile.writeAsString('attachment body');

      final src = await newDb();
      await MessageDao.create(src, cid: 3001);
      final block = FileBlock(
        id: 'file_1',
        messageId: 'msg_1',
        createdAt: 1,
        status: MessageBlockStatus.success,
        file: FileMetadata(
          name: 'note.txt',
          path: sourceFile.path,
          mime: 'text/plain',
          size: await sourceFile.length(),
          extractedText: 'wrapped text',
        ),
      );
      await src.db.insert('tb_messages', {
        'cid': 3001,
        'content': '带附件',
        'createdAt': 444,
        'ownerName': 'user',
        'ownerType': 'sender',
        'blocks': MessageBlock.encodeList([block]),
      });

      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(
          archive.files.any((f) => f.name.startsWith('assets/files/')), isTrue);
      await src.db.close();

      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.warnings, isEmpty);
      final rows = await dst.db.query('tb_messages', where: 'createdAt = 444');
      final restoredBlock =
          MessageBlock.decodeList(rows.single['blocks'] as String).single
              as FileBlock;
      expect(restoredBlock.file.name, 'note.txt');
      expect(restoredBlock.file.path, isNot(sourceFile.path));
      expect(await File(restoredBlock.file.path!).readAsString(),
          'attachment body');
      expect(restoredBlock.file.extractedText, 'wrapped text');
      await dst.db.close();
    });

    test('v2 备份包含会话头像资源，并在导入后重写 avatarValue', () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup-avatar-src-');
      final dstDir =
          await Directory.systemTemp.createTemp('backup-avatar-dst-');
      addTearDown(() async {
        AvatarAssetService.debugDocumentsDirectoryResolver = null;
        if (srcDir.existsSync()) await srcDir.delete(recursive: true);
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
      });

      AvatarAssetService.debugDocumentsDirectoryResolver = () async => srcDir;
      final srcAvatarDir =
          await AvatarAssetService.avatarDir(accountHash: 'acc1');
      final avatar = File('${srcAvatarDir.path}/conversation_1001.png');
      await avatar.writeAsBytes([7, 8, 9]);
      final src = await newDb();
      await ConversationListDao.create(src);
      await src.db.insert('tb_conversation_list', {
        'cid': 1001,
        'icon': '',
        'stickTime': 0,
        'title': '图片头像会话',
        'avatarType': AvatarAssetService.imageType,
        'avatarValue': avatar.path,
      });

      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.where((f) => f.name.startsWith('assets/avatars/')),
          hasLength(1));
      expect(
        (await BackupService(src).previewArchive(bytes, accountHash: 'acc1'))
            .avatarAssets,
        1,
      );
      await src.db.close();

      AvatarAssetService.debugDocumentsDirectoryResolver = () async => dstDir;
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc2');
      expect(result.warnings.any((w) => w.contains('其他账号')), isTrue);
      final row = (await dst.db.query('tb_conversation_list',
              where: 'cid = ?', whereArgs: [1001]))
          .single;
      expect(row['avatarType'], AvatarAssetService.imageType);
      final restoredPath = row['avatarValue'] as String;
      expect(restoredPath, isNot(avatar.path));
      expect(restoredPath, contains('/chat_avatar/acc2/'));
      expect(await File(restoredPath).readAsBytes(), [7, 8, 9]);
      await dst.db.close();
    });

    test('备份缺头像资源时图片头像降级默认头像并给出告警', () async {
      final dstDir =
          await Directory.systemTemp.createTemp('backup-avatar-missing-');
      addTearDown(() async {
        AvatarAssetService.debugDocumentsDirectoryResolver = null;
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
      });
      final archive = Archive()
        ..addFile(ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(
                jsonEncode({'formatVersion': BackupService.formatVersion}))))
        ..addFile(ArchiveFile.bytes(
            'conversations.json',
            utf8.encode(jsonEncode([
              {
                'cid': 5101,
                'icon': '',
                'stickTime': 0,
                'avatarType': AvatarAssetService.imageType,
                'avatarValue': '${dstDir.path}/chat_avatar/acc1/missing.png',
              },
            ]))));
      final bytes = ZipEncoder().encodeBytes(archive);

      AvatarAssetService.debugDocumentsDirectoryResolver = () async => dstDir;
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.warnings.any((w) => w.contains('头像资源不在备份中')), isTrue);
      final row = (await dst.db.query('tb_conversation_list',
              where: 'cid = ?', whereArgs: [5101]))
          .single;
      expect(row['avatarType'], isNull);
      expect(row['avatarValue'], isNull);
      await dst.db.close();
    });

    test('v2 备份包含应用内生成图片，并在导入后恢复到本地相册', () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup-generated-src-');
      final dstDir =
          await Directory.systemTemp.createTemp('backup-generated-dst-');
      addTearDown(() async {
        BackupService.debugGeneratedImageDirectoryResolver = null;
        if (srcDir.existsSync()) await srcDir.delete(recursive: true);
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
      });

      final srcAlbum = Directory(
          '${srcDir.path}/${GeneratedImageSaveService.albumDirectoryName}');
      await srcAlbum.create(recursive: true);
      await File('${srcAlbum.path}/chatai_sample.png')
          .writeAsBytes([1, 2, 3, 4]);
      await File('${srcAlbum.path}/ignore.txt').writeAsString('not an image');

      BackupService.debugGeneratedImageDirectoryResolver = () async => srcDir;
      final src = await newDb();
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(
        archive.files
            .where((f) => f.name.startsWith('assets/generated_images/')),
        hasLength(1),
      );
      expect(
        (await BackupService(src).previewArchive(bytes, accountHash: 'acc1'))
            .generatedImageAssets,
        1,
      );
      await src.db.close();

      BackupService.debugGeneratedImageDirectoryResolver = () async => dstDir;
      final dstAlbum = Directory(
          '${dstDir.path}/${GeneratedImageSaveService.albumDirectoryName}');
      await dstAlbum.create(recursive: true);
      await File('${dstAlbum.path}/old.png').writeAsBytes([9]);
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.generatedImageAssets, 1);
      expect(File('${dstAlbum.path}/old.png').existsSync(), isFalse);
      expect(await File('${dstAlbum.path}/chatai_sample.png').readAsBytes(),
          [1, 2, 3, 4]);
      await dst.db.close();
    });

    test('合并导入生成图片时保留本地同名图片并追加唯一文件名', () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup-generated-merge-src-');
      final dstDir =
          await Directory.systemTemp.createTemp('backup-generated-merge-dst-');
      addTearDown(() async {
        BackupService.debugGeneratedImageDirectoryResolver = null;
        if (srcDir.existsSync()) await srcDir.delete(recursive: true);
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
      });

      final srcAlbum = Directory(
          '${srcDir.path}/${GeneratedImageSaveService.albumDirectoryName}');
      await srcAlbum.create(recursive: true);
      await File('${srcAlbum.path}/chatai_sample.png').writeAsBytes([1, 2, 3]);

      BackupService.debugGeneratedImageDirectoryResolver = () async => srcDir;
      final src = await newDb();
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();

      BackupService.debugGeneratedImageDirectoryResolver = () async => dstDir;
      final dstAlbum = Directory(
          '${dstDir.path}/${GeneratedImageSaveService.albumDirectoryName}');
      await dstAlbum.create(recursive: true);
      await File('${dstAlbum.path}/chatai_sample.png').writeAsBytes([9, 9, 9]);
      final dst = await newDb();
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );

      expect(result.generatedImageAssets, 1);
      expect(await File('${dstAlbum.path}/chatai_sample.png').readAsBytes(),
          [9, 9, 9]);
      expect(await File('${dstAlbum.path}/chatai_sample_1.png').readAsBytes(),
          [1, 2, 3]);
      await dst.db.close();
    });
  });

  group('外键修复与非法输入', () {
    List<int> zipOf(Map<String, Object> files) {
      final archive = Archive();
      files.forEach((name, content) {
        archive
            .addFile(ArchiveFile.bytes(name, utf8.encode(jsonEncode(content))));
      });
      return ZipEncoder().encodeBytes(archive);
    }

    test('会话引用了备份中不存在的助手 -> 解除绑定 + 告警', () async {
      final bytes = zipOf({
        'manifest.json': {'formatVersion': 1, 'accountHash': 'acc1'},
        'conversations.json': [
          {'cid': 1, 'icon': '', 'stickTime': 0, 'assistantId': 99},
        ],
        'assistants.json': <Object>[],
      });
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.warnings.single, contains('解除绑定'));
      final conv = await dst.db.query('tb_conversation_list', where: 'cid = 1');
      expect(conv.single['assistantId'], isNull);
      await dst.db.close();
    });

    test('旧备份缺 projects/projectId 仍可导入为未分类', () async {
      final bytes = zipOf({
        'manifest.json': {'formatVersion': 1, 'accountHash': 'acc1'},
        'conversations.json': [
          {'cid': 1, 'icon': '', 'stickTime': 0, 'title': '旧备份会话'},
        ],
        'assistants.json': <Object>[],
      });
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.projects, 0);
      final conv = await dst.db.query('tb_conversation_list', where: 'cid = 1');
      expect(conv.single['projectId'], isNull);
      await dst.db.close();
    });

    test('旧会话表 schema（无 projectId）导入后仍可写入', () async {
      final bytes = zipOf({
        'manifest.json': {'formatVersion': 1, 'accountHash': 'acc1'},
        'conversations.json': [
          {'cid': 101, 'icon': '', 'stickTime': 0, 'title': '兼容导入测试'},
        ],
        'assistants.json': <Object>[],
      });
      final dst = await newDb();
      await dst.db.execute(
          'create table tb_conversation_list (id integer primary key autoincrement'
          ', cid integer, title text, icon text, updateAt integer'
          ', messageCount integer, lastMessage text, stickTime integer, assistantId integer)');
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.conversations, 1);
      expect(result.warnings, isEmpty);
      final conv =
          await dst.db.query('tb_conversation_list', where: 'cid = 101');
      expect(conv.single['title'], '兼容导入测试');
      expect(conv.single['projectId'], isNull);
      await dst.db.close();
    });

    test('会话引用了备份中不存在的项目 -> 移动到未分类 + 告警', () async {
      final bytes = zipOf({
        'manifest.json': {'formatVersion': 1, 'accountHash': 'acc1'},
        'conversations.json': [
          {'cid': 1, 'icon': '', 'stickTime': 0, 'projectId': 99},
        ],
        'projects.json': <Object>[],
      });
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.warnings.single, contains('未分类'));
      final conv = await dst.db.query('tb_conversation_list', where: 'cid = 1');
      expect(conv.single['projectId'], isNull);
      await dst.db.close();
    });

    test('非 zip / 缺 manifest / 版本过新 -> FormatException 且不动现有数据', () async {
      final dst = await newDb();
      await seed(dst);
      final service = BackupService(dst);

      await expectLater(service.importArchive([1, 2, 3], accountHash: 'acc1'),
          throwsFormatException);
      await expectLater(
          service.importArchive(zipOf({'foo.json': {}}), accountHash: 'acc1'),
          throwsFormatException);
      await expectLater(
          service.importArchive(
              zipOf({
                'manifest.json': {'formatVersion': 999},
              }),
              accountHash: 'acc1'),
          throwsFormatException);

      // 现有数据完好
      final convs = await dst.db.query('tb_conversation_list');
      expect(convs.length, 2);
      await dst.db.close();
    });
  });
}
