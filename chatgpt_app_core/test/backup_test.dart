import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_integrity.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_asset_store.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/chat/application/story_room_role_card_importer.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/db/story_artifact_dao.dart';
import 'package:chatgpt_app_core/db/story_persona_dao.dart';
import 'package:chatgpt_app_core/db/story_room_dao.dart';
import 'package:chatgpt_app_core/db/story_template_dao.dart';
import 'package:chatgpt_app_core/db/story_template_translation_task_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/model/story_artifact_model.dart';
import 'package:chatgpt_app_core/model/story_persona_model.dart';
import 'package:chatgpt_app_core/model/story_template_model.dart';
import 'package:chatgpt_app_core/model/story_template_translation_task_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/avatar_asset_service.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 阶段八（备份恢复）验收测试：导出/导入 round-trip、API key 脱敏、
/// 覆盖式恢复、外键修复、非法文件与版本校验。全部走真实
/// BackupService + DAO（HiDBManager.test 注入 ffi 内存库）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory defaultGeneratedImageRoot;
  setUp(() async {
    defaultGeneratedImageRoot =
        await Directory.systemTemp.createTemp('backup-test-images-');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${defaultGeneratedImageRoot.path}/managed-attachments');
    BackupService.debugGeneratedImageDirectoryResolver =
        () async => defaultGeneratedImageRoot;
    BackupService.debugRoleCardAssetsDirectoryResolver =
        () async => defaultGeneratedImageRoot;
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    BackupService.debugGeneratedImageDirectoryResolver = null;
    BackupService.debugRoleCardAssetsDirectoryResolver = null;
    if (await defaultGeneratedImageRoot.exists()) {
      await defaultGeneratedImageRoot.delete(recursive: true);
    }
  });

  Future<HiDBManager> newDb() async => HiDBManager.test(
        await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        ),
      );

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
      speakerStrategy: StorySpeakerStrategy.roundRobin,
      avoidRepeatSpeaker: false,
      maxAutoTotalTokens: 8192,
      publicContext: '旧城区的雨夜酒馆',
      promptConfigJson: '{"version":1,"modules":[]}',
      quickRepliesJson: '{"roomId":0,"groups":[]}',
      regexScriptsJson: '{"version":1,"rules":[]}',
      tavernPresetJson:
          '{"format":"chatai_deep_story_tavern_preset_bundle","formatVersion":1,"presets":{"context":{"story_string":"safe","api_key":"secret"}}}',
      topP: 0.82,
      tavernChatMetadataJson:
          '{"chat_metadata":{"scenario":"rain"},"unknown":true}',
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
      topP: 0.72,
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
      tavernExtraJson: '{"bias":1}',
      tavernSwipeInfoJson: '[{"gen_started":100}]',
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

  List<int> rawZipOf(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, content) {
      archive.addFile(ArchiveFile.bytes(name, content));
    });
    return ZipEncoder().encodeBytes(archive);
  }

  List<int> rawStoredZipOf(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, content) {
      archive.addFile(ArchiveFile.noCompress(name, content.length, content));
    });
    return ZipEncoder().encodeBytes(archive);
  }

  List<int> forgeZipDeclaredUncompressedSize(
    List<int> source, {
    required String entryName,
    required int declaredBytes,
  }) {
    final bytes = List<int>.from(source);
    var patchedLocal = false;
    var patchedCentral = false;

    int read16(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
    int read32(int offset) =>
        bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    void write32(int offset, int value) {
      for (var index = 0; index < 4; index++) {
        bytes[offset + index] = (value >> (index * 8)) & 0xff;
      }
    }

    for (var offset = 0; offset + 46 <= bytes.length; offset++) {
      final signature = read32(offset);
      if (signature == 0x04034b50) {
        final nameLength = read16(offset + 26);
        final nameStart = offset + 30;
        if (nameStart + nameLength > bytes.length) continue;
        final name = utf8.decode(
          bytes.sublist(nameStart, nameStart + nameLength),
          allowMalformed: true,
        );
        if (name == entryName) {
          write32(offset + 22, declaredBytes);
          patchedLocal = true;
        }
      } else if (signature == 0x02014b50) {
        final nameLength = read16(offset + 28);
        final nameStart = offset + 46;
        if (nameStart + nameLength > bytes.length) continue;
        final name = utf8.decode(
          bytes.sublist(nameStart, nameStart + nameLength),
          allowMalformed: true,
        );
        if (name == entryName) {
          write32(offset + 24, declaredBytes);
          patchedCentral = true;
        }
      }
    }
    if (!patchedLocal || !patchedCentral) {
      throw StateError('未找到 ZIP entry header: $entryName');
    }
    return bytes;
  }

  Map<String, Object> officialLegacyFiles(
    int version, {
    String accountHash = 'acc1',
    Map<String, Object> overrides = const {},
  }) {
    if (version < 1 || version > 10) {
      throw ArgumentError.value(version, 'version', '仅用于 v1..v10 fixture');
    }
    return <String, Object>{
      'manifest.json': {
        'formatVersion': version,
        'accountHash': accountHash,
      },
      'conversations.json': <Object>[],
      'messages.json': <Object>[],
      'assistants.json': <Object>[],
      'favorites.json': <Object>[],
      'settings.json': AISettings.defaults().toJson(),
      if (version >= 2) ...{
        'projects.json': <Object>[],
        'knowledge_docs.json': <Object>[],
        'knowledge_chunks.json': <Object>[],
        'project_knowledge.json': <Object>[],
      },
      if (version >= 3) 'story_templates.json': <Object>[],
      if (version >= 4) ...{
        'story_rooms.json': <Object>[],
        'story_participants.json': <Object>[],
        'story_messages.json': <Object>[],
        'story_artifacts.json': <Object>[],
        'story_artifact_revisions.json': <Object>[],
      },
      if (version >= 5) 'story_template_translation_tasks.json': <Object>[],
      if (version >= 8) 'story_personas.json': <Object>[],
      ...overrides,
    };
  }

  /// 在保留 v11 digest 自洽的前提下故意损坏结构，避免测试只被
  /// hash 校验拦住，没有真正触发 strict reader/counts 防线。
  List<int> rewriteV11Archive(
    List<int> source,
    void Function(
      Map<String, List<int>> entries,
      Map<String, dynamic> manifest,
    ) mutate,
  ) {
    final decoded = ZipDecoder().decodeBytes(source);
    final allEntries = <String, List<int>>{
      for (final file in decoded.files.where((file) => file.isFile))
        file.name: List<int>.from(file.content as List<int>),
    };
    final manifest = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(allEntries.remove('manifest.json')!)) as Map,
    );
    mutate(allEntries, manifest);
    manifest['entries'] = {
      for (final entry in digestEntries(allEntries).entries)
        entry.key: entry.value.toJson(),
    };

    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
        'manifest.json',
        utf8.encode(jsonEncode(manifest)),
      ));
    for (final entry in allEntries.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  group('酒馆房间备份', () {
    test('默认导出的 ZIP 不携带 legacy Tavern room secrets 且不修改本地库', () async {
      final src = await newDb();
      await seedStoryRoom(src);

      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final rows = jsonDecode(utf8.decode(List<int>.from(
        archive.findFile('story_rooms.json')!.content as List<int>,
      ))) as List;
      final preset = (rows.single as Map)['tavernPresetJson'] as String;

      expect(preset, contains('story_string'));
      expect(preset, isNot(contains('api_key')));
      expect(preset, isNot(contains('secret')));
      final sourceRow = (await src.db.query('tb_story_room')).single;
      expect(sourceRow['tavernPresetJson'], contains('secret'));
      await src.db.close();
    });

    test('默认导出的 ZIP 清洗 story_template.payload 内的 Tavern secrets', () async {
      final src = await newDb();
      final dao = await StoryTemplateDao.create(src);
      await dao.saveTemplate(StoryTemplateModel(
        title: 'legacy unsafe template',
        payload: jsonEncode({
          'formatVersion': StoryRoomTemplatePayload.formatVersion,
          'results': <Object>[],
          'tavernPresetJson': jsonEncode({
            'format': 'chatai_deep_story_tavern_preset_bundle',
            'formatVersion': 1,
            'presets': {
              'context': {
                'story_string': 'safe-template',
                'api_key': 'template-secret',
              },
            },
          }),
        }),
      ));

      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final rows = jsonDecode(utf8.decode(List<int>.from(
        archive.findFile('story_templates.json')!.content as List<int>,
      ))) as List;
      final payload =
          jsonDecode((rows.single as Map)['payload'] as String) as Map;
      final preset = payload['tavernPresetJson'] as String;

      expect(preset, contains('safe-template'));
      expect(preset, isNot(contains('api_key')));
      expect(preset, isNot(contains('template-secret')));
      await src.db.close();
    });

    test('Tavern JSON 损坏时导出副本 fail closed 且不修改源 SQLite', () async {
      final src = await newDb();
      await seedStoryRoom(src);
      await src.db.update(
        'tb_story_room',
        {'tavernPresetJson': '{"api_key":"room-secret"'},
      );
      final templateDao = await StoryTemplateDao.create(src);
      await templateDao.saveTemplate(StoryTemplateModel(
        title: 'broken template',
        payload: '{"tavernPresetJson":"template-secret"',
      ));

      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final roomRows = jsonDecode(utf8.decode(List<int>.from(
        archive.findFile('story_rooms.json')!.content as List<int>,
      ))) as List;
      final templateRows = jsonDecode(utf8.decode(List<int>.from(
        archive.findFile('story_templates.json')!.content as List<int>,
      ))) as List;

      expect((roomRows.single as Map)['tavernPresetJson'], '');
      expect((templateRows.single as Map)['payload'], '{}');
      final sourceRoom = (await src.db.query('tb_story_room')).single;
      final sourceTemplate = (await src.db.query('tb_story_template')).single;
      expect(sourceRoom['tavernPresetJson'], contains('room-secret'));
      expect(sourceTemplate['payload'], contains('template-secret'));
      await src.db.close();
    });

    test('导出、预览和覆盖恢复保留房间/参与者/消息关联与统计', () async {
      final src = await newDb();
      final aid = await seed(src);
      final sourceIds = await seedStoryRoom(src, assistantId: aid);
      final sourceArtifactDao = await StoryArtifactDao.create(src);
      final sourceArtifact = StoryArtifactModel(
        roomId: sourceIds['roomId']!,
        type: StoryArtifactType.chapter,
        title: '第一章',
        content: '初稿',
        status: 'draft',
      );
      await sourceArtifactDao.saveArtifact(sourceArtifact);
      sourceArtifact.content = '修订稿';
      await sourceArtifactDao.saveArtifact(sourceArtifact);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      final localIds = await seedStoryRoom(dst, title: '本地旧酒馆');
      final localArtifactDao = await StoryArtifactDao.create(dst);
      await localArtifactDao.saveArtifact(StoryArtifactModel(
        roomId: localIds['roomId']!,
        type: StoryArtifactType.outline,
        title: '本地资料',
      ));
      final preview = await BackupService(dst).previewArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(preview.storyRooms, 1);
      expect(preview.storyParticipants, 1);
      expect(preview.storyMessages, 1);
      expect(preview.storyArtifacts, 1);
      expect(preview.storyArtifactRevisions, 1);
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
      expect(result.storyArtifacts, 1);
      expect(result.storyArtifactRevisions, 1);
      expect(await dst.db.query('tb_story_room'), hasLength(1));
      expect(await dst.db.query('tb_story_participant'), hasLength(1));
      expect(
        (await dst.db.query('tb_story_participant')).single['topP'],
        0.72,
      );
      final messages = await dst.db.query('tb_story_message');
      expect(messages, hasLength(1));
      expect(messages.single['roomId'], isNot(sourceIds['roomId']));
      expect(messages.single['speakerId'], isNot(sourceIds['participantId']));
      expect(messages.single['content'], '她抬起头，看向门口。');
      expect(messages.single['nodeKey'], isNotEmpty);
      final restoredRoom = (await dst.db.query('tb_story_room')).single;
      expect(restoredRoom['activeMessageKey'], messages.single['nodeKey']);
      expect(restoredRoom['promptConfigJson'], '{"version":1,"modules":[]}');
      expect(restoredRoom['quickRepliesJson'], '{"roomId":0,"groups":[]}');
      expect(restoredRoom['regexScriptsJson'], '{"version":1,"rules":[]}');
      expect(restoredRoom['tavernPresetJson'], contains('story_string'));
      expect(restoredRoom['tavernPresetJson'], isNot(contains('secret')));
      expect(restoredRoom['topP'], 0.82);
      expect(restoredRoom['speakerStrategy'], StorySpeakerStrategy.roundRobin);
      expect(restoredRoom['avoidRepeatSpeaker'], 0);
      expect(restoredRoom['maxAutoTotalTokens'], 8192);
      expect(restoredRoom['tavernChatMetadataJson'],
          '{"chat_metadata":{"scenario":"rain"},"unknown":true}');
      expect(messages.single['tavernExtraJson'], '{"bias":1}');
      expect(messages.single['tavernSwipeInfoJson'], '[{"gen_started":100}]');
      final restoredRoomId = messages.single['roomId'] as int;
      final artifacts = await dst.db.query('tb_story_artifact');
      expect(artifacts, hasLength(1));
      expect(artifacts.single['roomId'], restoredRoomId);
      expect(artifacts.single['id'], isNot(sourceArtifact.id));
      final revisions = await dst.db.query('tb_story_artifact_revision');
      expect(revisions, hasLength(1));
      expect(revisions.single['artifactId'], artifacts.single['id']);
      await dst.db.close();
    });

    test('合并恢复遇到相同 ID 时重映射房间、参与者和消息发言者', () async {
      final src = await newDb();
      final srcAid = await (await AssistantDao.create(src)).saveAssistant(
        AssistantModel(name: '源角色', prompt: '源角色设定'),
      );
      final sourceIds =
          await seedStoryRoom(src, assistantId: srcAid, title: '源酒馆');
      final sourceArtifactDao = await StoryArtifactDao.create(src);
      final sourceArtifact = StoryArtifactModel(
        roomId: sourceIds['roomId']!,
        type: StoryArtifactType.outline,
        title: '源大纲',
        content: '源内容',
      );
      await sourceArtifactDao.saveArtifact(sourceArtifact);
      sourceArtifact.content = '源修订';
      await sourceArtifactDao.saveArtifact(sourceArtifact);
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
      final localArtifactDao = await StoryArtifactDao.create(dst);
      await localArtifactDao.saveArtifact(StoryArtifactModel(
        roomId: localIds['roomId']!,
        type: StoryArtifactType.outline,
        title: '本地大纲',
      ));
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );

      expect(result.storyRooms, 1);
      expect(result.storyParticipants, 1);
      expect(result.storyMessages, 1);
      expect(result.storyArtifacts, 1);
      expect(result.storyArtifactRevisions, 1);
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
      final importedArtifact = (await dst.db.query(
        'tb_story_artifact',
        where: 'title = ?',
        whereArgs: ['源大纲'],
      ))
          .single;
      expect(importedArtifact['roomId'], importedRoomId);
      expect(importedArtifact['id'], isNot(sourceArtifact.id));
      final importedRevision = (await dst.db.query(
        'tb_story_artifact_revision',
        where: 'artifactId = ?',
        whereArgs: [importedArtifact['id']],
      ))
          .single;
      expect(importedRevision['artifactId'], importedArtifact['id']);
      await dst.db.close();
    });

    test('合并恢复会整树改写冲突节点键并保留父链、候选组和活动叶', () async {
      final src = await newDb();
      final srcDao = await StoryRoomDao.create(src);
      final srcRoom = StoryRoomModel(title: '分支源房间');
      await srcDao.saveRoom(srcRoom);
      await srcDao.saveMessage(StoryMessageModel(
        roomId: srcRoom.id!,
        speakerRole: 'user',
        speakerName: '我',
        content: '选择道路',
        nodeKey: 'shared-root',
        candidateGroupKey: 'shared-root',
        contextStateAfter: 'root-state',
      ));
      await srcDao.saveMessage(StoryMessageModel(
        roomId: srcRoom.id!,
        speakerRole: 'assistant',
        speakerName: '角色',
        content: '走左边',
        nodeKey: 'source-left',
        parentNodeKey: 'shared-root',
        candidateGroupKey: 'reply-group',
        contextStateAfter: 'left-state',
      ));
      await srcDao.activateMessage(srcRoom.id!, 'shared-root');
      await srcDao.saveMessage(StoryMessageModel(
        roomId: srcRoom.id!,
        speakerRole: 'assistant',
        speakerName: '角色',
        content: '走右边',
        nodeKey: 'shared-active',
        parentNodeKey: 'shared-root',
        candidateGroupKey: 'reply-group',
        contextStateAfter: 'right-state',
      ));
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      final dstDao = await StoryRoomDao.create(dst);
      final localRoom = StoryRoomModel(title: '本地分支');
      await dstDao.saveRoom(localRoom);
      await dstDao.saveMessage(StoryMessageModel(
        roomId: localRoom.id!,
        speakerRole: 'user',
        speakerName: '我',
        content: '本地根',
        nodeKey: 'shared-root',
      ));
      await dstDao.saveMessage(StoryMessageModel(
        roomId: localRoom.id!,
        speakerRole: 'assistant',
        speakerName: '本地角色',
        content: '本地回复',
        nodeKey: 'shared-active',
      ));

      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      expect(result.warnings.join('\n'), contains('故事分支节点与本地重复'));
      final importedRoom = StoryRoomModel.fromJson((await dst.db.query(
        'tb_story_room',
        where: 'title = ?',
        whereArgs: ['分支源房间'],
      ))
          .single);
      final imported = await dstDao.getMessages(importedRoom.id!);
      final root = imported.singleWhere((item) => item.content == '选择道路');
      final left = imported.singleWhere((item) => item.content == '走左边');
      final right = imported.singleWhere((item) => item.content == '走右边');
      expect(root.nodeKey, isNot('shared-root'));
      expect(right.nodeKey, isNot('shared-active'));
      expect(left.parentNodeKey, root.nodeKey);
      expect(right.parentNodeKey, root.nodeKey);
      expect(left.candidateGroupKey, right.candidateGroupKey);
      expect(importedRoom.activeMessageKey, right.nodeKey);
      expect(
          (await dstDao.getActiveMessages(importedRoom.id!))
              .map((item) => item.content),
          ['选择道路', '走右边']);
      await dst.db.close();
    });

    test('v4 线性故事消息恢复时自动生成节点父链和活动叶', () async {
      final dst = await newDb();
      final bytes = zipOf(officialLegacyFiles(4, overrides: {
        'story_rooms.json': [
          {
            'id': 8,
            'title': '旧线性房间',
            'mode': StoryRoomMode.tavern,
            'worldBookState': 'legacy-state',
            'createdAt': 1,
            'updatedAt': 2,
          }
        ],
        'story_participants.json': [
          {
            'id': 9,
            'roomId': 8,
            'role': 'assistant',
            'name': '旧角色',
            'prompt': '',
            'sortOrder': 0,
            'enabled': 1,
            'createdAt': 1,
            'updatedAt': 2,
          }
        ],
        'story_messages.json': [
          {
            'id': 10,
            'roomId': 8,
            'speakerRole': 'user',
            'speakerName': '我',
            'content': '第一句',
            'createdAt': 10,
            'updatedAt': 10,
          },
          {
            'id': 11,
            'roomId': 8,
            'speakerRole': 'assistant',
            'speakerName': '角色',
            'content': '第二句',
            'createdAt': 11,
            'updatedAt': 11,
          },
        ],
      }));
      await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      final dao = await StoryRoomDao.create(dst);
      final room = (await dao.getRooms()).single;
      final participant = (await dao.getParticipants(room.id!)).single;
      final messages = await dao.getMessages(room.id!);
      expect(participant.participantKey, 'backup-participant-8-9');
      expect(participant.stateSummary, '');
      expect(messages, hasLength(2));
      expect(messages.first.parentNodeKey, isNull);
      expect(messages.last.parentNodeKey, messages.first.nodeKey);
      expect(room.activeMessageKey, messages.last.nodeKey);
      expect(messages.last.contextStateAfter, 'legacy-state');
      await dst.db.close();
    });

    test('旧备份没有酒馆文件时仍可覆盖导入并统计为零', () async {
      final dst = await newDb();
      await seedStoryRoom(dst, title: '待被清理的酒馆');
      final bytes = zipOf(officialLegacyFiles(1));

      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(result.storyRooms, 0);
      expect(result.storyParticipants, 0);
      expect(result.storyMessages, 0);
      expect(result.storyTemplateTranslationTasks, 0);
      expect(await dst.db.query('tb_story_room'), isEmpty);
      expect(await dst.db.query('tb_story_participant'), isEmpty);
      expect(await dst.db.query('tb_story_message'), isEmpty);
      expect(await dst.db.query('tb_story_template_translation_task'), isEmpty);
      await dst.db.close();
    });
  });

  group('酒馆模板翻译任务备份', () {
    test('覆盖恢复保留任务，合并恢复重映射关联的酒馆模板 ID', () async {
      final src = await newDb();
      final sourceTemplateDao = await StoryTemplateDao.create(src);
      final sourceTemplate = StoryTemplateModel(title: '英文酒馆', payload: '{}');
      final outputTemplate = StoryTemplateModel(title: '中文酒馆', payload: '{}');
      await sourceTemplateDao.saveTemplate(sourceTemplate);
      await sourceTemplateDao.saveTemplate(outputTemplate);
      final sourceRoomDao = await StoryRoomDao.create(src);
      final sourceRoom = StoryRoomModel(title: '中文酒馆房间');
      final sourceRoomId = await sourceRoomDao.saveRoom(sourceRoom);
      final sourceTaskDao = await StoryTemplateTranslationTaskDao.create(src);
      final task = StoryTemplateTranslationTaskModel(
        templateId: sourceTemplate.id,
        sourceTitle: '英文酒馆',
        sourcePayload: '{}',
        outputTitle: '中文酒馆',
        outputTemplateId: outputTemplate.id,
        outputRoomId: sourceRoomId,
        requestProfile: jsonEncode({
          'version': 1,
          'mode': 'local',
          'providerId': 'fast-provider',
          'modelId': 'fast-model',
          'reasoningPolicy': 'offIfSupported',
          'reasoningControlSuppressed': false,
          'apiKey': 'must-not-export',
        }),
        status: StoryTemplateTranslationTaskStatus.running,
        leaseOwner: 'dead-export-worker',
        leaseUntil:
            DateTime.now().add(const Duration(days: 7)).millisecondsSinceEpoch,
        nextRunAt:
            DateTime.now().add(const Duration(days: 8)).millisecondsSinceEpoch,
      );
      await sourceTaskDao.saveTask(task);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final exportedArchive = ZipDecoder().decodeBytes(bytes);
      final exportedTaskFile = exportedArchive.files.singleWhere(
        (file) => file.name == 'story_template_translation_tasks.json',
      );
      final exportedTasks = jsonDecode(
        utf8.decode(exportedTaskFile.content as List<int>),
      ) as List<dynamic>;
      final exportedTask = exportedTasks.single as Map<String, dynamic>;
      final exportedProfile = jsonDecode(
        exportedTask['requestProfile'] as String,
      ) as Map<String, dynamic>;
      expect(exportedProfile['providerId'], 'fast-provider');
      expect(exportedProfile['modelId'], 'fast-model');
      expect(exportedProfile, isNot(contains('apiKey')));
      expect(
        exportedTask['status'],
        StoryTemplateTranslationTaskStatus.retryable,
      );
      expect(exportedTask['leaseOwner'], isNull);
      expect(exportedTask['leaseUntil'], isNull);
      expect(exportedTask['nextRunAt'], isNull);
      final sourceTaskId = task.id;
      await src.db.close();

      final overwrite = await newDb();
      final overwriteRoomDao = await StoryRoomDao.create(overwrite);
      for (var index = 0; index < 3; index++) {
        await overwriteRoomDao.saveRoom(
          StoryRoomModel(title: '待覆盖房间 $index'),
        );
      }
      final overwritePreview = await BackupService(overwrite).previewArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(overwritePreview.storyTemplateTranslationTasks, 1);
      final overwriteResult = await BackupService(overwrite).importArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(overwriteResult.storyTemplateTranslationTasks, 1);
      final overwrittenTask = (await overwrite.db.query(
        'tb_story_template_translation_task',
      ))
          .single;
      final overwrittenRoom = (await overwrite.db.query(
        'tb_story_room',
        where: 'title = ?',
        whereArgs: ['中文酒馆房间'],
      ))
          .single;
      expect(overwrittenTask['id'], sourceTaskId);
      expect(overwrittenTask['templateId'], sourceTemplate.id);
      expect(overwrittenTask['outputTemplateId'], outputTemplate.id);
      expect(overwrittenRoom['id'], isNot(sourceRoomId));
      expect(overwrittenTask['outputRoomId'], overwrittenRoom['id']);
      expect(
        overwrittenTask['status'],
        StoryTemplateTranslationTaskStatus.retryable,
      );
      expect(overwrittenTask['leaseOwner'], isNull);
      expect(overwrittenTask['leaseUntil'], isNull);
      expect(overwrittenTask['nextRunAt'], isNull);
      await overwrite.db.close();

      final merge = await newDb();
      final localTemplateDao = await StoryTemplateDao.create(merge);
      await localTemplateDao.saveTemplate(
        StoryTemplateModel(title: '本地模板一', payload: '{}'),
      );
      await localTemplateDao.saveTemplate(
        StoryTemplateModel(title: '本地模板二', payload: '{}'),
      );
      final localRoomDao = await StoryRoomDao.create(merge);
      await localRoomDao.saveRoom(StoryRoomModel(title: '本地房间一'));
      await localRoomDao.saveRoom(StoryRoomModel(title: '本地房间二'));
      final mergeResult = await BackupService(merge).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      expect(mergeResult.storyTemplateTranslationTasks, 1);
      final importedSource = (await merge.db.query(
        'tb_story_template',
        where: 'title = ?',
        whereArgs: ['英文酒馆'],
      ))
          .single;
      final importedOutput = (await merge.db.query(
        'tb_story_template',
        where: 'title = ?',
        whereArgs: ['中文酒馆'],
      ))
          .single;
      final mergedTask = (await merge.db.query(
        'tb_story_template_translation_task',
      ))
          .single;
      expect(mergedTask['templateId'], importedSource['id']);
      expect(mergedTask['outputTemplateId'], importedOutput['id']);
      expect(mergedTask['templateId'], isNot(sourceTemplate.id));
      expect(mergedTask['outputTemplateId'], isNot(outputTemplate.id));
      final importedRoom = (await merge.db.query(
        'tb_story_room',
        where: 'title = ?',
        whereArgs: ['中文酒馆房间'],
      ))
          .single;
      expect(mergedTask['outputRoomId'], importedRoom['id']);
      expect(mergedTask['outputRoomId'], isNot(sourceRoomId));
      expect(
        mergedTask['status'],
        StoryTemplateTranslationTaskStatus.retryable,
      );
      expect(mergedTask['leaseOwner'], isNull);
      expect(mergedTask['leaseUntil'], isNull);
      expect(mergedTask['nextRunAt'], isNull);
      await merge.db.close();
    });

    test('导入边界清理旧运行器和未来租约并立即恢复为可重试', () async {
      final archivedTask = StoryTemplateTranslationTaskModel(
        sourceTitle: '旧运行任务',
        sourcePayload: '{}',
        outputTitle: '恢复后的任务',
        status: StoryTemplateTranslationTaskStatus.running,
        leaseOwner: 'archived-worker',
        leaseUntil:
            DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
        nextRunAt:
            DateTime.now().add(const Duration(days: 31)).millisecondsSinceEpoch,
      ).toJson()
        ..['id'] = 77;
      final bytes = zipOf(officialLegacyFiles(10, overrides: {
        'story_template_translation_tasks.json': [archivedTask],
      }));
      final dst = await newDb();

      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
      );

      expect(result.storyTemplateTranslationTasks, 1);
      final restored = (await dst.db.query(
        'tb_story_template_translation_task',
      ))
          .single;
      expect(restored['id'], 77);
      expect(
        restored['status'],
        StoryTemplateTranslationTaskStatus.retryable,
      );
      expect(restored['leaseOwner'], isNull);
      expect(restored['leaseUntil'], isNull);
      expect(restored['nextRunAt'], isNull);
      await dst.db.close();
    });

    test('覆盖恢复会清除翻译任务中缺失的生成房间引用并告警', () async {
      final src = await newDb();
      final templateDao = await StoryTemplateDao.create(src);
      final sourceTemplate = StoryTemplateModel(title: '英文酒馆', payload: '{}');
      final outputTemplate = StoryTemplateModel(title: '中文酒馆', payload: '{}');
      await templateDao.saveTemplate(sourceTemplate);
      await templateDao.saveTemplate(outputTemplate);
      final taskDao = await StoryTemplateTranslationTaskDao.create(src);
      final task = StoryTemplateTranslationTaskModel(
        templateId: sourceTemplate.id,
        sourceTitle: '英文酒馆',
        sourcePayload: '{}',
        outputTitle: '中文酒馆',
        outputTemplateId: outputTemplate.id,
        outputRoomId: 999,
        status: StoryTemplateTranslationTaskStatus.completed,
      );
      await taskDao.saveTask(task);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final sourceTaskId = task.id;
      await src.db.close();

      final dst = await newDb();
      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
      );
      final restoredTask = (await dst.db.query(
        'tb_story_template_translation_task',
      ))
          .single;
      expect(restoredTask['id'], sourceTaskId);
      expect(restoredTask['templateId'], sourceTemplate.id);
      expect(restoredTask['outputTemplateId'], outputTemplate.id);
      expect(restoredTask['outputRoomId'], isNull);
      expect(
        result.warnings,
        contains('1 个翻译任务找不到生成的酒馆房间，已清除引用'),
      );
      await dst.db.close();
    });
  });

  group('导出/导入 round-trip', () {
    test('官方 v1..v10 累积矩阵均可预览与覆盖导入', () async {
      for (var version = 1; version <= 10; version++) {
        final bytes = zipOf(officialLegacyFiles(version));
        final dst = await newDb();
        final service = BackupService(dst);

        final preview =
            await service.previewArchive(bytes, accountHash: 'acc1');
        final result = await service.importArchive(bytes, accountHash: 'acc1');

        expect(preview.formatVersion, version, reason: 'preview v$version');
        expect(preview.integrityVerified, isFalse, reason: 'preview v$version');
        expect(result.conversations, 0, reason: 'import v$version');
        await dst.db.close();
      }
    });

    test('v1..v10 每阶段新增必需行 entry 缺失/非列表/非 Map 均在写入前拒绝', () async {
      const requiredSince = <String, int>{
        'conversations.json': 1,
        'messages.json': 1,
        'assistants.json': 1,
        'favorites.json': 1,
        'projects.json': 2,
        'knowledge_docs.json': 2,
        'knowledge_chunks.json': 2,
        'project_knowledge.json': 2,
        'story_templates.json': 3,
        'story_rooms.json': 4,
        'story_participants.json': 4,
        'story_messages.json': 4,
        'story_artifacts.json': 4,
        'story_artifact_revisions.json': 4,
        'story_template_translation_tasks.json': 5,
        'story_personas.json': 8,
      };

      for (final required in requiredSince.entries) {
        final fixtures = <String, Map<String, Object>>{
          '缺失': officialLegacyFiles(required.value)..remove(required.key),
          '非列表': officialLegacyFiles(
            required.value,
            overrides: {required.key: <String, Object>{}},
          ),
          '含非 Map 行': officialLegacyFiles(
            required.value,
            overrides: {
              required.key: <Object>[42]
            },
          ),
        };
        for (final fixture in fixtures.entries) {
          final dst = await newDb();
          final dao = await ConversationListDao.create(dst);
          await dao.saveConversation(ConversationModel(cid: 99100, icon: '')
            ..title = 'required entry 损坏不得覆盖'
            ..stickTime = 0
            ..updateAt = 1);
          final service = BackupService(dst);
          final bytes = zipOf(fixture.value);

          await expectLater(
            service.previewArchive(bytes, accountHash: 'acc1'),
            throwsFormatException,
            reason: '${required.key}/${fixture.key}/preview',
          );
          await expectLater(
            service.importArchive(bytes, accountHash: 'acc1'),
            throwsFormatException,
            reason: '${required.key}/${fixture.key}/import',
          );
          final sentinel = await dst.db.query(
            'tb_conversation_list',
            where: 'cid = ?',
            whereArgs: [99100],
          );
          expect(sentinel, hasLength(1));
          await dst.db.close();
        }
      }
    });

    test('legacy settings 缺失或非 Map 时预览与导入均 fail closed', () async {
      final fixtures = <String, Map<String, Object>>{
        '缺失': officialLegacyFiles(1)..remove('settings.json'),
        '非 Map': officialLegacyFiles(
          1,
          overrides: {'settings.json': <Object>[]},
        ),
      };
      for (final fixture in fixtures.entries) {
        final dst = await newDb();
        final dao = await ConversationListDao.create(dst);
        await dao.saveConversation(ConversationModel(cid: 99101, icon: '')
          ..title = 'settings 损坏不得覆盖'
          ..stickTime = 0
          ..updateAt = 1);
        final service = BackupService(dst);
        final bytes = zipOf(fixture.value);

        await expectLater(
          service.previewArchive(bytes, accountHash: 'acc1'),
          throwsFormatException,
          reason: '${fixture.key}/preview',
        );
        await expectLater(
          service.importArchive(bytes, accountHash: 'acc1'),
          throwsFormatException,
          reason: '${fixture.key}/import',
        );
        expect(
          await dst.db.query(
            'tb_conversation_list',
            where: 'cid = ?',
            whereArgs: [99101],
          ),
          hasLength(1),
        );
        await dst.db.close();
      }
    });

    test('v11 只改 formatVersion 为 10 时预览与导入均拒绝且不覆盖本地数据', () async {
      final src = await newDb();
      await seed(src);
      final valid = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final downgraded = rewriteV11Archive(
        valid,
        (_, manifest) => manifest['formatVersion'] = 10,
      );
      await src.db.close();

      final dst = await newDb();
      final dao = await ConversationListDao.create(dst);
      await dao.saveConversation(ConversationModel(cid: 99001, icon: '')
        ..title = '必须保留的本地会话'
        ..stickTime = 0
        ..updateAt = 1);
      final service = BackupService(dst);
      Object? previewError;
      Object? importError;
      try {
        await service.previewArchive(downgraded, accountHash: 'acc1');
      } catch (error) {
        previewError = error;
      }
      try {
        await service.importArchive(downgraded, accountHash: 'acc1');
      } catch (error) {
        importError = error;
      }
      final sentinel = await dst.db.query(
        'tb_conversation_list',
        where: 'cid = ?',
        whereArgs: [99001],
      );

      expect(
        previewError is FormatException &&
            importError is FormatException &&
            sentinel.length == 1 &&
            sentinel.single['title'] == '必须保留的本地会话',
        isTrue,
        reason:
            'preview=$previewError, import=$importError, sentinel=$sentinel',
      );
      await dst.db.close();
    });

    test('v1 必需文件缺失或损坏时拒绝且 overwrite 不清理本地数据', () async {
      final fixtures = <String, List<int>>{
        '缺少 conversations.json': zipOf(
          officialLegacyFiles(1)..remove('conversations.json'),
        ),
        'conversations.json 不是列表': zipOf(
          officialLegacyFiles(1, overrides: {
            'conversations.json': <String, Object>{},
          }),
        ),
        'conversations.json 包含非 Map 行': zipOf(
          officialLegacyFiles(1, overrides: {
            'conversations.json': <Object>[42],
          }),
        ),
      };

      for (final fixture in fixtures.entries) {
        final dst = await newDb();
        final dao = await ConversationListDao.create(dst);
        await dao.saveConversation(ConversationModel(cid: 99002, icon: '')
          ..title = '旧备份损坏时不得清除'
          ..stickTime = 0
          ..updateAt = 1);
        final service = BackupService(dst);
        Object? previewError;
        Object? importError;
        try {
          await service.previewArchive(fixture.value, accountHash: 'acc1');
        } catch (error) {
          previewError = error;
        }
        try {
          await service.importArchive(fixture.value, accountHash: 'acc1');
        } catch (error) {
          importError = error;
        }
        final sentinel = await dst.db.query(
          'tb_conversation_list',
          where: 'cid = ?',
          whereArgs: [99002],
        );

        expect(
          previewError is FormatException &&
              importError is FormatException &&
              sentinel.length == 1 &&
              sentinel.single['title'] == '旧备份损坏时不得清除',
          isTrue,
          reason: '${fixture.key}: preview=$previewError, '
              'import=$importError, sentinel=$sentinel',
        );
        await dst.db.close();
      }
    });

    test('formatVersion 缺失、类型错误或越界时统一拒绝且不写数据库', () async {
      final manifests = <String, Map<String, Object?>>{
        '缺失': {'accountHash': 'acc1'},
        'null': {'formatVersion': null, 'accountHash': 'acc1'},
        '字符串': {'formatVersion': '11', 'accountHash': 'acc1'},
        '零': {'formatVersion': 0, 'accountHash': 'acc1'},
        '负数': {'formatVersion': -1, 'accountHash': 'acc1'},
        '未来版本': {'formatVersion': 12, 'accountHash': 'acc1'},
      };

      for (final fixture in manifests.entries) {
        final files = officialLegacyFiles(1)..['manifest.json'] = fixture.value;
        final bytes = zipOf(files);
        final dst = await newDb();
        final dao = await ConversationListDao.create(dst);
        await dao.saveConversation(ConversationModel(cid: 99003, icon: '')
          ..title = '非法版本不得覆盖'
          ..stickTime = 0
          ..updateAt = 1);
        Object? previewError;
        Object? importError;
        try {
          await BackupService(dst).previewArchive(bytes, accountHash: 'acc1');
        } catch (error) {
          previewError = error;
        }
        try {
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
        } catch (error) {
          importError = error;
        }
        final sentinel = await dst.db.query(
          'tb_conversation_list',
          where: 'cid = ?',
          whereArgs: [99003],
        );

        expect(
          previewError is FormatException &&
              importError is FormatException &&
              sentinel.length == 1,
          isTrue,
          reason: '${fixture.key}: preview=$previewError, '
              'import=$importError, sentinel=$sentinel',
        );
        await dst.db.close();
      }
    });

    test('实际解压长度大于 ZIP header 声明时拒绝且不覆盖本地数据', () async {
      final legacyFiles = officialLegacyFiles(1);
      final rawFiles = <String, List<int>>{
        for (final entry in legacyFiles.entries)
          entry.key: utf8.encode(jsonEncode(entry.value)),
      };
      rawFiles['conversations.json'] = utf8.encode('${' ' * 8192}[]');
      final forged = forgeZipDeclaredUncompressedSize(
        rawZipOf(rawFiles),
        entryName: 'conversations.json',
        declaredBytes: 2,
      );
      final dst = await newDb();
      final dao = await ConversationListDao.create(dst);
      await dao.saveConversation(ConversationModel(cid: 99004, icon: '')
        ..title = 'ZIP 大小伪造不得覆盖'
        ..stickTime = 0
        ..updateAt = 1);
      final generatedImages = AccountResourceScope.scopedDirectory(
        base: defaultGeneratedImageRoot,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc1',
      );
      await generatedImages.create(recursive: true);
      final resourceSentinel = File('${generatedImages.path}/keep.png');
      await resourceSentinel.writeAsBytes([7, 8, 9]);
      final tickBefore = BackupService.restoreTick.value;
      final service = BackupService(dst);
      Object? previewError;
      Object? importError;
      try {
        await service.previewArchive(forged, accountHash: 'acc1');
      } catch (error) {
        previewError = error;
      }
      try {
        await service.importArchive(forged, accountHash: 'acc1');
      } catch (error) {
        importError = error;
      }
      final sentinel = await dst.db.query(
        'tb_conversation_list',
        where: 'cid = ?',
        whereArgs: [99004],
      );
      final resourceBytes = await resourceSentinel.readAsBytes();

      expect(
        previewError is FormatException &&
            importError is FormatException &&
            sentinel.length == 1 &&
            BackupService.restoreTick.value == tickBefore &&
            resourceBytes.join(',') == '7,8,9',
        isTrue,
        reason: 'preview=$previewError, import=$importError, '
            'sentinel=$sentinel',
      );
      await dst.db.close();
    });

    test('stored entry 实际输出大于伪造 header 时也在任何写入前拒绝', () async {
      final legacyFiles = officialLegacyFiles(1);
      final rawFiles = <String, List<int>>{
        for (final entry in legacyFiles.entries)
          entry.key: utf8.encode(jsonEncode(entry.value)),
      };
      rawFiles['conversations.json'] = utf8.encode('${' ' * 8192}[]');
      final forged = forgeZipDeclaredUncompressedSize(
        rawStoredZipOf(rawFiles),
        entryName: 'conversations.json',
        declaredBytes: 2,
      );
      final dst = await newDb();
      final dao = await ConversationListDao.create(dst);
      await dao.saveConversation(ConversationModel(cid: 99005, icon: '')
        ..title = 'stored ZIP 伪造不得覆盖'
        ..stickTime = 0
        ..updateAt = 1);
      final tickBefore = BackupService.restoreTick.value;
      final service = BackupService(dst);

      await expectLater(
        service.previewArchive(forged, accountHash: 'acc1'),
        throwsFormatException,
      );
      await expectLater(
        service.importArchive(forged, accountHash: 'acc1'),
        throwsFormatException,
      );
      expect(
        await dst.db.query(
          'tb_conversation_list',
          where: 'cid = ?',
          whereArgs: [99005],
        ),
        hasLength(1),
      );
      expect(BackupService.restoreTick.value, tickBefore);
      await dst.db.close();
    });

    test('v11 导出包含全部长期记忆并校验每个 entry', () async {
      final src = await newDb();
      final assistantId = await seed(src);
      final memoryDao = await AssistantMemoryDao.create(src);
      for (final status in [
        AssistantMemoryStatus.active,
        AssistantMemoryStatus.rejected,
        AssistantMemoryStatus.archived,
      ]) {
        await memoryDao.saveMemory(AssistantMemoryModel(
          assistantId: assistantId,
          content: '${status.name} memory',
          status: status,
          confirmedByUser: status == AssistantMemoryStatus.active,
        ));
      }

      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      final rawEntries = {
        for (final file in archive.files.where((file) => file.isFile))
          file.name: List<int>.from(file.content as List<int>),
      };
      final manifest = Map<String, dynamic>.from(jsonDecode(
        utf8.decode(rawEntries['manifest.json']!),
      ) as Map);
      final memories = jsonDecode(
        utf8.decode(rawEntries['assistant_memories.json']!),
      ) as List;

      expect(manifest['formatVersion'], 11);
      expect((manifest['counts'] as Map)['assistantMemories'], 3);
      expect(memories, hasLength(3));
      expect(
        () => verifyEntryDigests(rawEntries, manifest['entries']),
        returnsNormally,
      );
      expect(
        (manifest['entries'] as Map).keys.toSet(),
        rawEntries.keys.where((name) => name != 'manifest.json').toSet(),
      );

      final dst = await newDb();
      final preview =
          await BackupService(dst).previewArchive(bytes, accountHash: 'acc1');
      expect(preview.integrityVerified, isTrue);
      expect(preview.assistantMemories, 3);
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.assistantMemories, 3);
      final restored = await dst.db.query('tb_assistant_memory');
      expect(restored, hasLength(3));
      expect(
        restored.map((row) => row['status']).toSet(),
        {'active', 'rejected', 'archived'},
      );
      await src.db.close();
      await dst.db.close();
    });

    test('v10 无记忆与 digest 的备份继续可预览', () async {
      final bytes = zipOf(officialLegacyFiles(
        10,
        accountHash: 'legacy-account',
      ));
      final dst = await newDb();

      final preview = await BackupService(dst).previewArchive(
        bytes,
        accountHash: 'legacy-account',
      );

      expect(preview.integrityVerified, isFalse);
      expect(preview.assistantMemories, 0);
      expect(
        preview.warnings.any((warning) => warning.contains('旧备份未包含完整性校验')),
        isTrue,
      );
      expect(
        preview.warnings.any((warning) => warning.contains('不包含长期记忆')),
        isTrue,
      );
      await dst.db.close();
    });

    test('v11 strict reader 在任何写入前拒绝自洽的缺项/非列表/坏行/数量不符', () async {
      final src = await newDb();
      await seed(src);
      final valid = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();
      final documents =
          await Directory.systemTemp.createTemp('backup-v11-strict-');
      final generatedImages = AccountResourceScope.scopedDirectory(
        base: documents,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc1',
      );
      await generatedImages.create(recursive: true);
      final sentinel = File('${generatedImages.path}/keep.png');
      await sentinel.writeAsBytes([9, 8, 7]);
      BackupService.debugGeneratedImageDirectoryResolver =
          () async => documents;
      addTearDown(() async {
        BackupService.debugGeneratedImageDirectoryResolver = null;
        if (await documents.exists()) {
          await documents.delete(recursive: true);
        }
      });

      final malformed = <String, List<int>>{
        '缺少必需 entry': rewriteV11Archive(valid, (entries, manifest) {
          entries.remove('conversations.json');
        }),
        '行文件不是列表': rewriteV11Archive(valid, (entries, manifest) {
          entries['conversations.json'] = utf8.encode(jsonEncode({}));
          (manifest['counts'] as Map)['conversations'] = 0;
        }),
        '列表含非 Map 行': rewriteV11Archive(valid, (entries, manifest) {
          entries['conversations.json'] = utf8.encode(jsonEncode([42]));
          (manifest['counts'] as Map)['conversations'] = 1;
        }),
        'manifest 数量与实际不符': rewriteV11Archive(valid, (entries, manifest) {
          final counts = manifest['counts'] as Map;
          counts['conversations'] = (counts['conversations'] as int) + 1;
        }),
        '资源数量与实际不符': rewriteV11Archive(valid, (entries, manifest) {
          final counts = manifest['counts'] as Map;
          counts['generatedImageAssets'] =
              (counts['generatedImageAssets'] as int) + 1;
        }),
      };

      for (final fixture in malformed.entries) {
        final dst = await newDb();
        final localDao = await ConversationListDao.create(dst);
        await localDao.saveConversation(ConversationModel(cid: 9901, icon: '')
          ..title = '不应被覆盖'
          ..stickTime = 0);
        final tickBefore = BackupService.restoreTick.value;
        final service = BackupService(dst);

        await expectLater(
          service.previewArchive(fixture.value, accountHash: 'acc1'),
          throwsFormatException,
          reason: fixture.key,
        );
        await expectLater(
          service.importArchive(fixture.value, accountHash: 'acc1'),
          throwsFormatException,
          reason: fixture.key,
        );

        final local = await dst.db.query(
          'tb_conversation_list',
          where: 'cid = ?',
          whereArgs: [9901],
        );
        expect(local.single['title'], '不应被覆盖', reason: fixture.key);
        expect(BackupService.restoreTick.value, tickBefore,
            reason: fixture.key);
        expect(await sentinel.readAsBytes(), [9, 8, 7], reason: fixture.key);
        await dst.db.close();
      }
    });

    test('v11 长期记忆 confirmedByUser 只接受 bool/0/1 且拒绝 active 未确认', () async {
      final src = await newDb();
      final assistantId = await seed(src);
      await (await AssistantMemoryDao.create(src)).saveMemory(
        AssistantMemoryModel(
          assistantId: assistantId,
          memoryId: 'strict-confirmation',
          content: '已确认',
        ),
      );
      final valid = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      List<int> withConfirmation(Object value) => rewriteV11Archive(
            valid,
            (entries, manifest) {
              final rows = jsonDecode(
                utf8.decode(entries['assistant_memories.json']!),
              ) as List;
              (rows.single as Map)['confirmedByUser'] = value;
              entries['assistant_memories.json'] =
                  utf8.encode(jsonEncode(rows));
            },
          );

      final dst = await newDb();
      final service = BackupService(dst);
      await expectLater(
        service.previewArchive(withConfirmation(2), accountHash: 'acc1'),
        throwsFormatException,
      );
      await expectLater(
        service.previewArchive(withConfirmation('true'), accountHash: 'acc1'),
        throwsFormatException,
      );
      await expectLater(
        service.importArchive(withConfirmation(false), accountHash: 'acc1'),
        throwsFormatException,
      );
      await dst.db.close();
    });

    test('accountGuard 在 staging 前与资源 swap 前都能中止导入并保留原数据', () async {
      final src = await newDb();
      await seed(src);
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      for (final mode in BackupImportMode.values) {
        final dst = await newDb();
        final localDao = await ConversationListDao.create(dst);
        await localDao.saveConversation(ConversationModel(cid: 9910, icon: '')
          ..title = '账号已切换'
          ..stickTime = 0);
        final tickBefore = BackupService.restoreTick.value;
        await expectLater(
          BackupService(dst).importArchive(
            bytes,
            accountHash: 'acc1',
            mode: mode,
            accountGuard: () => throw StateError('account changed'),
          ),
          throwsStateError,
          reason: mode.name,
        );
        expect(
          await dst.db.query(
            'tb_conversation_list',
            where: 'cid = ?',
            whereArgs: [9910],
          ),
          hasLength(1),
          reason: mode.name,
        );
        expect(BackupService.restoreTick.value, tickBefore, reason: mode.name);
        await dst.db.close();
      }

      final dst = await newDb();
      final localDao = await ConversationListDao.create(dst);
      await localDao.saveConversation(ConversationModel(cid: 9920, icon: '')
        ..title = 'swap 前仍应回滚'
        ..stickTime = 0);
      var guardCalls = 0;
      final tickBefore = BackupService.restoreTick.value;
      await expectLater(
        BackupService(dst).importArchive(
          bytes,
          accountHash: 'acc1',
          accountGuard: () {
            guardCalls++;
            if (guardCalls == 2) throw StateError('account changed');
          },
        ),
        throwsStateError,
      );
      expect(guardCalls, 2);
      expect(
        await dst.db.query(
          'tb_conversation_list',
          where: 'cid = ?',
          whereArgs: [9920],
        ),
        hasLength(1),
      );
      expect(BackupService.restoreTick.value, tickBefore);
      await dst.db.close();
    });

    test('合并导入重映射助手记忆并为冲突内容换新 ID', () async {
      final src = await newDb();
      final sourceAssistantId = await seed(src);
      final sourceMemoryDao = await AssistantMemoryDao.create(src);
      await sourceMemoryDao.saveMemory(AssistantMemoryModel(
        assistantId: sourceAssistantId,
        memoryId: 'shared-memory-id',
        content: '来自备份的内容',
        source: 'manual',
      ));
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );

      final dst = await newDb();
      final localAssistantId = await (await AssistantDao.create(dst))
          .saveAssistant(AssistantModel(name: '本地助手', prompt: '本地'));
      final localMemoryDao = await AssistantMemoryDao.create(dst);
      await localMemoryDao.saveMemory(AssistantMemoryModel(
        assistantId: localAssistantId!,
        memoryId: 'shared-memory-id',
        content: '本地不同内容',
        source: 'manual',
      ));

      final result = await BackupService(dst).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      final memories = await dst.db.query(
        'tb_assistant_memory',
        orderBy: 'id asc',
      );
      final imported = memories.firstWhere(
        (row) => row['content'] == '来自备份的内容',
      );

      expect(result.assistantMemories, 1);
      expect(memories, hasLength(2));
      expect(imported['assistantId'], isNot(localAssistantId));
      expect(imported['memoryId'], isNot('shared-memory-id'));
      expect(
          result.warnings.any((warning) => warning.contains('换用新 ID')), isTrue);
      await src.db.close();
      await dst.db.close();
    });

    test('重复合并相同备份时，每个新助手都保留自己的长期记忆', () async {
      final src = await newDb();
      final sourceAssistantId = await seed(src);
      await (await AssistantMemoryDao.create(src)).saveMemory(
        AssistantMemoryModel(
          assistantId: sourceAssistantId,
          memoryId: 'repeatable-memory',
          content: '每个新助手都需要这条记忆',
        ),
      );
      final bytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await src.db.close();

      final dst = await newDb();
      final service = BackupService(dst);
      await service.importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      await service.importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );

      final assistants = await dst.db.query(
        'tb_assistant',
        where: 'name = ?',
        whereArgs: ['审查员'],
      );
      expect(assistants, hasLength(2));
      for (final assistant in assistants) {
        final memories = await dst.db.query(
          'tb_assistant_memory',
          where: 'assistantId = ?',
          whereArgs: [assistant['id']],
        );
        expect(memories, hasLength(1));
        expect(memories.single['content'], '每个新助手都需要这条记忆');
      }
      final ids = (await dst.db.query('tb_assistant_memory'))
          .map((row) => row['memoryId'])
          .toSet();
      expect(ids, hasLength(2));
      await dst.db.close();
    });

    test('导出副本过滤历史孤儿并归档未确认 active，不修改本地库且可自恢复', () async {
      final src = await newDb();
      final assistantId = await seed(src);
      final memoryDao = await AssistantMemoryDao.create(src);
      await memoryDao.saveMemory(AssistantMemoryModel(
        assistantId: assistantId,
        memoryId: 'valid-memory-id',
        content: '第一条',
      ));
      final unconfirmed = AssistantMemoryModel(
        assistantId: assistantId,
        memoryId: 'unconfirmed-memory-id',
        assistantSyncId: 'legacy:$assistantId',
        content: '尚未确认',
        confirmedByUser: false,
      ).toJson()
        ..remove('id');
      final orphan = AssistantMemoryModel(
        assistantId: 999999,
        memoryId: 'orphan-memory-id',
        assistantSyncId: 'legacy:999999',
        content: '历史孤儿',
      ).toJson()
        ..remove('id');
      await src.db.insert('tb_assistant_memory', unconfirmed);
      await src.db.insert('tb_assistant_memory', orphan);
      final before = await src.db.query(
        'tb_assistant_memory',
        orderBy: 'id asc',
      );

      final report = await BackupService(src).exportArchiveWithReport(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );

      final after = await src.db.query(
        'tb_assistant_memory',
        orderBy: 'id asc',
      );
      expect(after, before, reason: '导出规范化只能修改 zip 副本');
      expect(report.warnings.join('\n'), contains('孤儿'));
      expect(report.warnings.join('\n'), contains('未确认'));

      final archive = ZipDecoder().decodeBytes(report.bytes);
      final exportedRows = jsonDecode(utf8.decode(
        List<int>.from(
          archive.findFile('assistant_memories.json')!.content as List<int>,
        ),
      )) as List;
      expect(exportedRows, hasLength(2));
      expect(
        exportedRows.any((row) => (row as Map)['assistantId'] == 999999),
        isFalse,
      );
      final archived = exportedRows.singleWhere(
        (row) => (row as Map)['memoryId'] == 'unconfirmed-memory-id',
      ) as Map;
      expect(archived['status'], AssistantMemoryStatus.archived.name);
      expect(archived['confirmedByUser'], 0);

      final dst = await newDb();
      final result = await BackupService(dst).importArchive(
        report.bytes,
        accountHash: 'acc1',
      );
      expect(result.assistantMemories, 2);
      final restored = await dst.db.query('tb_assistant_memory');
      expect(restored, hasLength(2));
      expect(
        restored.any(
          (row) =>
              row['memoryId'] == 'unconfirmed-memory-id' &&
              row['status'] == AssistantMemoryStatus.archived.name,
        ),
        isTrue,
      );
      await src.db.close();
      await dst.db.close();
    });

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
      final managedPath = await ManagedAttachmentStore.importFile(sourceFile);

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
          path: managedPath,
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
      expect(
        restoredBlock.file.path!.split(Platform.pathSeparator).last,
        matches(RegExp(r'^[a-f0-9]{64}\.txt$')),
        reason: '旧设备长路径只能作为归档 key，不得直接变为磁盘文件名',
      );
      expect(await File(restoredBlock.file.path!).readAsString(),
          'project attachment');
      expect(restoredBlock.file.extractedText, 'project extracted text');
      await dst.db.close();
    });

    test('v10 选择性导入不解析无关的损坏 settings', () async {
      final bytes = zipOf(officialLegacyFiles(10, overrides: {
        'settings.json': {
          'providers': [42],
          'activeProviderId': 'deepseek',
        },
      }));

      for (final mode in const [
        BackupImportMode.projectConversationsOnly,
        BackupImportMode.assistantsOnly,
        BackupImportMode.knowledgeBaseOnly,
      ]) {
        final dst = await newDb();
        await seed(dst);
        final result = await BackupService(dst).importArchive(
          bytes,
          accountHash: 'acc1',
          mode: mode,
        );
        expect(result.settings, isNull, reason: mode.name);
        await dst.db.close();
      }
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

    test('共享备份解析边界移除 keyless crafted MCP 运行授权', () async {
      final crafted = AISettings.defaults()
        ..mcpBackendEnabled = true
        ..mcpBackendTrusted = true
        ..mcpServers = const [
          McpServerConfig(
            id: 'crafted',
            name: 'Crafted loopback',
            url: 'http://127.0.0.1:8080/mcp',
            enabled: true,
            trusted: true,
            permission: McpToolPermission.confirmWrite,
            enabledProjectIds: [7],
            headers: {},
          ),
        ];
      final bytes = zipOf(officialLegacyFiles(
        10,
        overrides: {'settings.json': crafted.toJson()},
      ));
      final dst = await newDb();

      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      final restored = result.settings!;

      expect(restored.mcpBackendEnabled, isFalse);
      expect(restored.mcpBackendTrusted, isFalse);
      expect(restored.mcpServers.single.enabled, isFalse);
      expect(restored.mcpServers.single.trusted, isFalse);
      expect(restored.mcpServers.single.permission, McpToolPermission.readOnly);
      expect(restored.mcpServers.single.enabledProjectIds, isEmpty);
      expect(restored.mcpServers.single.headers, isEmpty);
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
      final managedPath = await ManagedAttachmentStore.importFile(sourceFile);

      final src = await newDb();
      await MessageDao.create(src, cid: 3001);
      final block = FileBlock(
        id: 'file_1',
        messageId: 'msg_1',
        createdAt: 1,
        status: MessageBlockStatus.success,
        file: FileMetadata(
          name: 'note.txt',
          path: managedPath,
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

    test('导入缺失附件资产时清除归档提供的本地路径且后续导出不会读取它', () async {
      final dir =
          await Directory.systemTemp.createTemp('backup-crafted-file-path-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final sentinel = File('${dir.path}/device-secret.txt');
      const sentinelBody = 'device-local-secret-that-must-not-be-exported';
      await sentinel.writeAsString(sentinelBody);
      final craftedBlock = FileBlock(
        id: 'crafted_file',
        messageId: 'crafted_message',
        createdAt: 555,
        status: MessageBlockStatus.success,
        file: FileMetadata(
          name: 'innocent.txt',
          path: sentinel.path,
          mime: 'text/plain',
          size: await sentinel.length(),
          extractedText: 'safe metadata only',
        ),
      );
      final craftedArchive = zipOf(officialLegacyFiles(2, overrides: {
        'conversations.json': [
          {
            'cid': 9001,
            'icon': '',
            'title': 'crafted',
            'stickTime': 0,
            'updateAt': 1,
          },
        ],
        'messages.json': [
          {
            'cid': 9001,
            'content': 'attachment',
            'createdAt': 555,
            'ownerName': 'user',
            'ownerType': 'sender',
            'blocks': MessageBlock.encodeList([craftedBlock]),
          },
        ],
      }));

      final dst = await newDb();
      final result = await BackupService(dst)
          .importArchive(craftedArchive, accountHash: 'acc1');
      expect(result.warnings, contains(contains('已移除归档携带的本地路径')));
      final imported = MessageBlock.decodeList(
        (await dst.db.query('tb_messages')).single['blocks'] as String,
      ).single as FileBlock;
      expect(imported.file.path, isNull);

      final exported = await BackupService(dst)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      final decoded = ZipDecoder().decodeBytes(exported);
      expect(
        decoded.files.any((file) => file.name.startsWith('assets/files/')),
        isFalse,
      );
      for (final file in decoded.files.where((entry) => entry.isFile)) {
        final content = List<int>.from(file.content as List<int>);
        expect(
          utf8.decode(content, allowMalformed: true),
          isNot(contains(sentinelBody)),
          reason: file.name,
        );
      }
      await dst.db.close();
    });

    test('备份导出拒绝 managed root 内指向外部文件的符号链接', () async {
      if (Platform.isWindows) return;
      final dir =
          await Directory.systemTemp.createTemp('backup-attachment-link-');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final sentinel = File('${dir.path}/outside-secret.txt');
      await sentinel.writeAsString('outside-managed-root-secret');
      final managedRoot = ManagedAttachmentStore.rootDirectory;
      await managedRoot.create(recursive: true);
      final link = Link(
        '${managedRoot.path}/crafted-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await link.create(sentinel.path);
      addTearDown(() async {
        if (await link.exists()) await link.delete();
      });

      final db = await newDb();
      await MessageDao.create(db, cid: 9002);
      await db.db.insert('tb_messages', {
        'cid': 9002,
        'content': 'crafted link',
        'createdAt': 556,
        'ownerName': 'user',
        'ownerType': 'sender',
        'blocks': MessageBlock.encodeList([
          FileBlock(
            id: 'link',
            messageId: 'link-message',
            createdAt: 556,
            status: MessageBlockStatus.success,
            file: FileMetadata(
              name: 'crafted.txt',
              path: link.path,
              mime: 'text/plain',
              size: await sentinel.length(),
            ),
          ),
        ]),
      });

      final exported = await BackupService(db)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      expect(
        ZipDecoder()
            .decodeBytes(exported)
            .files
            .any((file) => file.name.startsWith('assets/files/')),
        isFalse,
      );
      await db.db.close();
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
      final bytes = zipOf(officialLegacyFiles(10, overrides: {
        'conversations.json': [
          {
            'cid': 5101,
            'icon': '',
            'stickTime': 0,
            'avatarType': AvatarAssetService.imageType,
            'avatarValue': '${dstDir.path}/chat_avatar/acc1/missing.png',
          },
        ],
      }));

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

    test('生成图片导出只包含当前 scoped 与 legacy，覆盖恢复不动其他账号', () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup-generated-src-');
      final dstDir =
          await Directory.systemTemp.createTemp('backup-generated-dst-');
      addTearDown(() async {
        BackupService.debugGeneratedImageDirectoryResolver = null;
        if (srcDir.existsSync()) await srcDir.delete(recursive: true);
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
      });

      final srcLegacy = AccountResourceScope.legacyRoot(
        base: srcDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
      );
      final srcAccount = AccountResourceScope.scopedDirectory(
        base: srcDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc1',
      );
      final srcOtherAccount = AccountResourceScope.scopedDirectory(
        base: srcDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc2',
      );
      await srcLegacy.create(recursive: true);
      await srcAccount.create(recursive: true);
      await srcOtherAccount.create(recursive: true);
      await File('${srcLegacy.path}/chatai_sample.png')
          .writeAsBytes([1, 2, 3, 4]);
      await File('${srcAccount.path}/account.png').writeAsBytes([5, 6]);
      await File('${srcOtherAccount.path}/private.png').writeAsBytes([7, 8]);
      await File('${srcLegacy.path}/ignore.txt').writeAsString('not an image');

      BackupService.debugGeneratedImageDirectoryResolver = () async => srcDir;
      final src = await newDb();
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(
        archive.files
            .where((f) => f.name.startsWith('assets/generated_images/')),
        hasLength(2),
      );
      expect(archive.findFile('assets/generated_images/chatai_sample.png'),
          isNotNull);
      expect(
          archive.findFile('assets/generated_images/account.png'), isNotNull);
      expect(archive.findFile('assets/generated_images/private.png'), isNull);
      expect(
        (await BackupService(src).previewArchive(bytes, accountHash: 'acc1'))
            .generatedImageAssets,
        2,
      );
      await src.db.close();

      BackupService.debugGeneratedImageDirectoryResolver = () async => dstDir;
      final dstLegacy = AccountResourceScope.legacyRoot(
        base: dstDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
      );
      final dstAccount = AccountResourceScope.scopedDirectory(
        base: dstDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc1',
      );
      final dstOtherAccount = AccountResourceScope.scopedDirectory(
        base: dstDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc2',
      );
      await dstLegacy.create(recursive: true);
      await dstAccount.create(recursive: true);
      await dstOtherAccount.create(recursive: true);
      final legacySentinel = File('${dstLegacy.path}/legacy-stays.png');
      final accountOld = File('${dstAccount.path}/old.png');
      final otherSentinel = File('${dstOtherAccount.path}/private.png');
      await legacySentinel.writeAsBytes([9]);
      await accountOld.writeAsBytes([10]);
      await otherSentinel.writeAsBytes([11]);
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.generatedImageAssets, 2);
      expect(accountOld.existsSync(), isFalse);
      expect(await legacySentinel.readAsBytes(), [9]);
      expect(await otherSentinel.readAsBytes(), [11]);
      expect(await File('${dstAccount.path}/chatai_sample.png').readAsBytes(),
          [1, 2, 3, 4]);
      expect(
          await File('${dstAccount.path}/account.png').readAsBytes(), [5, 6]);
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

      final srcAlbum = AccountResourceScope.scopedDirectory(
        base: srcDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc1',
      );
      await srcAlbum.create(recursive: true);
      await File('${srcAlbum.path}/chatai_sample.png').writeAsBytes([1, 2, 3]);

      BackupService.debugGeneratedImageDirectoryResolver = () async => srcDir;
      final src = await newDb();
      final bytes = await BackupService(src)
          .exportArchive(settings: AISettings.defaults(), accountHash: 'acc1');
      await src.db.close();

      BackupService.debugGeneratedImageDirectoryResolver = () async => dstDir;
      final dstAlbum = AccountResourceScope.scopedDirectory(
        base: dstDir,
        resourceDirectoryName: GeneratedImageSaveService.albumDirectoryName,
        accountHash: 'acc1',
      );
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

  group('CHARX 角色卡资源备份', () {
    Future<List<int>> exportRoleCardAssistant({
      required Directory documents,
      required int assistantId,
      required List<int> content,
    }) async {
      final asset = File(
        '${documents.path}/${AssistantRoleCardAssetStore.directoryName}/$assistantId/000.webp',
      );
      await asset.parent.create(recursive: true);
      await asset.writeAsBytes(content);
      final source = await newDb();
      await AssistantDao.create(source);
      await source.db.insert(
        'tb_assistant',
        AssistantModel(
          name: '资源角色$assistantId',
          roleCardAssets: jsonEncode([
            {
              'type': 'background',
              'name': 'moon',
              'ext': 'webp',
              'localPath': asset.path,
            },
          ]),
        ).toJson()
          ..['id'] = assistantId,
      );
      final bytes = await BackupService(source).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      await source.db.close();
      return bytes;
    }

    String restoredAssetPath(Map<String, Object?> assistant) {
      final manifest =
          jsonDecode(assistant['roleCardAssets'] as String) as List;
      return (manifest.single as Map)['localPath'] as String;
    }

    test('角色卡导出只读当前账号清单引用的 scoped 文件', () async {
      final documents =
          await Directory.systemTemp.createTemp('backup-role-account-scope-');
      addTearDown(() async {
        BackupService.debugRoleCardAssetsDirectoryResolver = null;
        if (documents.existsSync()) await documents.delete(recursive: true);
      });
      final currentRoot = AccountResourceScope.scopedDirectory(
        base: documents,
        resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
        accountHash: 'acc1',
      );
      final otherRoot = AccountResourceScope.scopedDirectory(
        base: documents,
        resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
        accountHash: 'acc2',
      );
      final currentAsset = File('${currentRoot.path}/80/000.webp');
      final otherAsset = File('${otherRoot.path}/81/000.webp');
      await currentAsset.parent.create(recursive: true);
      await otherAsset.parent.create(recursive: true);
      await currentAsset.writeAsBytes([1, 2]);
      await otherAsset.writeAsBytes([9, 9]);

      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => documents;
      final source = await newDb();
      await AssistantDao.create(source);
      for (final entry in [(80, currentAsset), (81, otherAsset)]) {
        await source.db.insert(
          'tb_assistant',
          AssistantModel(
            name: 'scope-${entry.$1}',
            roleCardAssets: jsonEncode([
              {
                'type': 'background',
                'ext': 'webp',
                'localPath': entry.$2.path,
              },
            ]),
          ).toJson()
            ..['id'] = entry.$1,
        );
      }

      final bytes = await BackupService(source).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final archive = ZipDecoder().decodeBytes(bytes);

      expect(
        archive.findFile('assets/assistant_role_assets/80/000.webp'),
        isNotNull,
      );
      expect(
        archive.findFile('assets/assistant_role_assets/81/000.webp'),
        isNull,
      );
      await source.db.close();
    });

    test('覆盖恢复打包托管文件并改写角色卡清单路径', () async {
      final sourceDocuments =
          await Directory.systemTemp.createTemp('backup-role-card-source-');
      final targetDocuments =
          await Directory.systemTemp.createTemp('backup-role-card-target-');
      addTearDown(() async {
        BackupService.debugRoleCardAssetsDirectoryResolver = null;
        if (sourceDocuments.existsSync()) {
          await sourceDocuments.delete(recursive: true);
        }
        if (targetDocuments.existsSync()) {
          await targetDocuments.delete(recursive: true);
        }
      });

      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => sourceDocuments;
      final bytes = await exportRoleCardAssistant(
        documents: sourceDocuments,
        assistantId: 73,
        content: [1, 2, 3],
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(
        archive.findFile('assets/assistant_role_assets/73/000.webp'),
        isNotNull,
      );

      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;
      final target = await newDb();
      final result =
          await BackupService(target).importArchive(bytes, accountHash: 'acc1');
      expect(result.warnings, isEmpty);
      final assistant = (await target.db.query('tb_assistant')).single;
      final restoredPath = restoredAssetPath(assistant);
      expect(restoredPath, isNot(contains(sourceDocuments.path)));
      expect(
        restoredPath,
        contains(
          '/assistant_role_assets/accounts/'
          '${AccountResourceScope.tokenFor('acc1')}/73/',
        ),
      );
      expect(await File(restoredPath).readAsBytes(), [1, 2, 3]);
      await target.db.close();
    });

    test('仅助手恢复只替换当前 scoped，保留 legacy 与其他账号', () async {
      final sourceDocuments =
          await Directory.systemTemp.createTemp('backup-role-card-only-src-');
      final targetDocuments =
          await Directory.systemTemp.createTemp('backup-role-card-only-dst-');
      addTearDown(() async {
        BackupService.debugRoleCardAssetsDirectoryResolver = null;
        if (sourceDocuments.existsSync()) {
          await sourceDocuments.delete(recursive: true);
        }
        if (targetDocuments.existsSync()) {
          await targetDocuments.delete(recursive: true);
        }
      });

      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => sourceDocuments;
      final bytes = await exportRoleCardAssistant(
        documents: sourceDocuments,
        assistantId: 74,
        content: [4, 5, 6],
      );

      final legacyAsset = File(
        '${targetDocuments.path}/${AssistantRoleCardAssetStore.directoryName}/1/old.bin',
      );
      final currentRoot = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
        accountHash: 'acc1',
      );
      final otherRoot = AccountResourceScope.scopedDirectory(
        base: targetDocuments,
        resourceDirectoryName: AssistantRoleCardAssetStore.directoryName,
        accountHash: 'acc2',
      );
      final currentOld = File('${currentRoot.path}/1/current.bin');
      final otherAsset = File('${otherRoot.path}/1/private.bin');
      await legacyAsset.parent.create(recursive: true);
      await currentOld.parent.create(recursive: true);
      await otherAsset.parent.create(recursive: true);
      await legacyAsset.writeAsBytes([9]);
      await currentOld.writeAsBytes([8]);
      await otherAsset.writeAsBytes([7]);
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;
      final target = await newDb();
      final result = await BackupService(target).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.assistantsOnly,
      );
      expect(result.warnings, isEmpty);
      expect(currentOld.existsSync(), isFalse);
      expect(await legacyAsset.readAsBytes(), [9]);
      expect(await otherAsset.readAsBytes(), [7]);
      final assistant = (await target.db.query('tb_assistant')).single;
      final restoredPath = restoredAssetPath(assistant);
      expect(restoredPath, startsWith('${currentRoot.path}/74/'));
      expect(await File(restoredPath).readAsBytes(), [4, 5, 6]);
      await target.db.close();
    });

    test('合并追加按重映射后的助手 ID 重建资源并更新清单', () async {
      final sourceDocuments =
          await Directory.systemTemp.createTemp('backup-role-card-merge-src-');
      final targetDocuments =
          await Directory.systemTemp.createTemp('backup-role-card-merge-dst-');
      addTearDown(() async {
        BackupService.debugRoleCardAssetsDirectoryResolver = null;
        if (sourceDocuments.existsSync()) {
          await sourceDocuments.delete(recursive: true);
        }
        if (targetDocuments.existsSync()) {
          await targetDocuments.delete(recursive: true);
        }
      });

      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => sourceDocuments;
      final bytes = await exportRoleCardAssistant(
        documents: sourceDocuments,
        assistantId: 75,
        content: [7, 8, 9],
      );

      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => targetDocuments;
      final target = await newDb();
      final targetDao = await AssistantDao.create(target);
      await targetDao.saveAssistant(AssistantModel(name: '本地角色'));
      final result = await BackupService(target).importArchive(
        bytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      expect(result.warnings, isEmpty);
      final imported = (await target.db.query(
        'tb_assistant',
        where: 'name = ?',
        whereArgs: ['资源角色75'],
      ))
          .single;
      final importedId = imported['id'] as int;
      final restoredPath = restoredAssetPath(imported);
      expect(importedId, isNot(75));
      expect(
        restoredPath,
        contains(
          '/assistant_role_assets/accounts/'
          '${AccountResourceScope.tokenFor('acc1')}/$importedId/',
        ),
      );
      expect(await File(restoredPath).readAsBytes(), [7, 8, 9]);
      await target.db.close();
    });

    test('角色卡资源缺失时告警但仍导入助手与资源元数据', () async {
      final documents =
          await Directory.systemTemp.createTemp('backup-role-card-missing-');
      addTearDown(() async {
        BackupService.debugRoleCardAssetsDirectoryResolver = null;
        if (documents.existsSync()) await documents.delete(recursive: true);
      });
      final bytes = zipOf(officialLegacyFiles(10, overrides: {
        'assistants.json': [
          AssistantModel(
            name: '缺资源角色',
            roleCardAssets: jsonEncode([
              {
                'type': 'background',
                'ext': 'webp',
                'localPath': '/old/assistant_role_assets/76/000.webp',
              },
            ]),
          ).toJson()
            ..['id'] = 76,
        ],
      }));
      BackupService.debugRoleCardAssetsDirectoryResolver =
          () async => documents;
      final target = await newDb();
      final result = await BackupService(target).importArchive(
        bytes,
        accountHash: 'acc1',
      );
      expect(result.warnings.single, contains('角色卡资源不在备份中'));
      final assistant = (await target.db.query('tb_assistant')).single;
      expect(restoredAssetPath(assistant), isEmpty);
      await target.db.close();
    });
  });

  group('外键修复与非法输入', () {
    test('会话引用了备份中不存在的助手 -> 解除绑定 + 告警', () async {
      final bytes = zipOf(officialLegacyFiles(1, overrides: {
        'conversations.json': [
          {'cid': 1, 'icon': '', 'stickTime': 0, 'assistantId': 99},
        ],
        'assistants.json': <Object>[],
      }));
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.warnings.single, contains('解除绑定'));
      final conv = await dst.db.query('tb_conversation_list', where: 'cid = 1');
      expect(conv.single['assistantId'], isNull);
      await dst.db.close();
    });

    test('旧备份缺 projects/projectId 仍可导入为未分类', () async {
      final bytes = zipOf(officialLegacyFiles(1, overrides: {
        'conversations.json': [
          {'cid': 1, 'icon': '', 'stickTime': 0, 'title': '旧备份会话'},
        ],
        'assistants.json': <Object>[],
      }));
      final dst = await newDb();
      final result =
          await BackupService(dst).importArchive(bytes, accountHash: 'acc1');
      expect(result.projects, 0);
      final conv = await dst.db.query('tb_conversation_list', where: 'cid = 1');
      expect(conv.single['projectId'], isNull);
      await dst.db.close();
    });

    test('旧会话表 schema（无 projectId）导入后仍可写入', () async {
      final bytes = zipOf(officialLegacyFiles(1, overrides: {
        'conversations.json': [
          {'cid': 101, 'icon': '', 'stickTime': 0, 'title': '兼容导入测试'},
        ],
        'assistants.json': <Object>[],
      }));
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
      final bytes = zipOf(officialLegacyFiles(2, overrides: {
        'conversations.json': [
          {'cid': 1, 'icon': '', 'stickTime': 0, 'projectId': 99},
        ],
        'projects.json': <Object>[],
      }));
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
      await expectLater(
          service.importArchive(
              zipOf(officialLegacyFiles(1, overrides: {
                'settings.json': {
                  'providers': [42],
                  'activeProviderId': 'deepseek',
                },
              })),
              accountHash: 'acc1'),
          throwsFormatException);

      // 现有数据完好
      final convs = await dst.db.query('tb_conversation_list');
      expect(convs.length, 2);
      await dst.db.close();
    });

    test('v8 覆盖恢复 Persona 头像并重写历史消息快照路径', () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup-persona-avatar-src-');
      final dstDir =
          await Directory.systemTemp.createTemp('backup-persona-avatar-dst-');
      addTearDown(() async {
        AvatarAssetService.debugDocumentsDirectoryResolver = null;
        if (await srcDir.exists()) await srcDir.delete(recursive: true);
        if (await dstDir.exists()) await dstDir.delete(recursive: true);
      });

      AvatarAssetService.debugDocumentsDirectoryResolver = () async => srcDir;
      final src = await newDb();
      final personaDao = await StoryPersonaDao.create(src);
      final persona = StoryPersonaModel(
        personaKey: 'persona-backup-avatar',
        name: '备份人设',
        description: '会被完整恢复',
      );
      await personaDao.savePersona(persona);
      final sourcePath = await AvatarAssetService.savePersonaAvatarBytes(
        bytes: [1, 2, 3, 4],
        personaKey: persona.personaKey,
        accountHash: 'acc-src',
      );
      persona
        ..avatarType = AvatarAssetService.imageType
        ..avatarValue = sourcePath;
      await personaDao.savePersona(persona);
      final roomDao = await StoryRoomDao.create(src);
      final roomId = await roomDao.saveRoom(StoryRoomModel(
        title: '绑定 Persona 的房间',
        personaKey: persona.personaKey,
      ));
      await roomDao.saveMessage(StoryMessageModel(
        roomId: roomId,
        speakerRole: StoryParticipantRole.author,
        speakerName: persona.name,
        speakerPersonaKey: persona.personaKey,
        speakerAvatarType: AvatarAssetService.imageType,
        speakerAvatarValue: sourcePath,
        content: '保留头像快照',
      ));
      final archiveBytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc-src',
      );
      final archive = ZipDecoder().decodeBytes(archiveBytes);
      expect(archive.findFile('story_personas.json'), isNotNull);
      expect(
        (jsonDecode(utf8.decode(
                archive.findFile('manifest.json')!.content as List<int>))
            as Map)['counts']['storyPersonas'],
        1,
      );
      await src.db.close();

      AvatarAssetService.debugDocumentsDirectoryResolver = () async => dstDir;
      final dst = await newDb();
      final dstPersonaDao = await StoryPersonaDao.create(dst);
      await dstPersonaDao.savePersona(StoryPersonaModel(
        personaKey: persona.personaKey,
        name: '本地旧版本',
      ));
      final preview = await BackupService(dst)
          .previewArchive(archiveBytes, accountHash: 'acc-dst');
      expect(preview.storyPersonas, 1);
      expect(
        preview.conflictSummary.tableConflicts
            .firstWhere((item) => item.table == 'tb_story_persona')
            .replacingRows,
        1,
      );

      final result = await BackupService(dst).importArchive(
        archiveBytes,
        accountHash: 'acc-dst',
      );
      expect(result.storyPersonas, 1);
      final restoredPersona = (await dst.db.query(
        'tb_story_persona',
        where: 'personaKey = ?',
        whereArgs: [persona.personaKey],
      ))
          .single;
      final restoredPath = restoredPersona['avatarValue'] as String;
      expect(restoredPath, isNot(sourcePath));
      expect(restoredPath, contains('/chat_avatar/acc-dst/'));
      expect(await File(restoredPath).readAsBytes(), [1, 2, 3, 4]);
      final restoredRoom = (await dst.db.query('tb_story_room')).single;
      expect(restoredRoom['personaKey'], persona.personaKey);
      final restoredMessage = (await dst.db.query('tb_story_message')).single;
      expect(restoredMessage['speakerPersonaKey'], persona.personaKey);
      expect(restoredMessage['speakerAvatarValue'], restoredPath);
      await dst.db.close();
    });

    test('Persona 合并按 personaKey 去重，仅较新的版本覆盖且悬空房间解绑', () async {
      final srcDir =
          await Directory.systemTemp.createTemp('backup-persona-merge-src-');
      final dstDir =
          await Directory.systemTemp.createTemp('backup-persona-merge-dst-');
      addTearDown(() async {
        if (await srcDir.exists()) await srcDir.delete(recursive: true);
        if (await dstDir.exists()) await dstDir.delete(recursive: true);
      });
      final src = HiDBManager.test(
        await databaseFactoryFfi.openDatabase('${srcDir.path}/source.db'),
      );
      final sourceDao = await StoryPersonaDao.create(src);
      final source = StoryPersonaModel(
        personaKey: 'persona-merge',
        name: '远端旧版',
      );
      await sourceDao.savePersona(source);
      await src.db.update('tb_story_persona', {'updatedAt': 100},
          where: 'personaKey = ?', whereArgs: [source.personaKey]);
      var archiveBytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );

      final dst = HiDBManager.test(
        await databaseFactoryFfi.openDatabase('${dstDir.path}/target.db'),
      );
      final targetDao = await StoryPersonaDao.create(dst);
      final target = StoryPersonaModel(
        personaKey: source.personaKey,
        name: '本地较新版',
      );
      await targetDao.savePersona(target);
      await dst.db.update('tb_story_persona', {'updatedAt': 200},
          where: 'personaKey = ?', whereArgs: [source.personaKey]);
      final retained = await BackupService(dst).importArchive(
        archiveBytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      expect(retained.storyPersonas, 0);
      expect(
        (await targetDao.getPersonaByKey(source.personaKey))!.name,
        '本地较新版',
      );

      await src.db.update(
        'tb_story_persona',
        {'name': '远端较新版', 'updatedAt': 300},
        where: 'personaKey = ?',
        whereArgs: [source.personaKey],
      );
      archiveBytes = await BackupService(src).exportArchive(
        settings: AISettings.defaults(),
        accountHash: 'acc1',
      );
      final replaced = await BackupService(dst).importArchive(
        archiveBytes,
        accountHash: 'acc1',
        mode: BackupImportMode.mergeAppend,
      );
      expect(replaced.storyPersonas, 1);
      final merged = await targetDao.getPersonaByKey(source.personaKey);
      expect(merged!.id, target.id);
      expect(merged.name, '远端较新版');
      expect(merged.personaKey, source.personaKey);

      final danglingBytes = zipOf(officialLegacyFiles(8, overrides: {
        'story_rooms.json': [
          {
            'id': 77,
            'title': '悬空绑定',
            'mode': 'creation',
            'replyMode': 'autoSingle',
            'maxAutoReplies': 1,
            'publicContext': '',
            'personaKey': 'missing-persona',
            'createdAt': 1,
            'updatedAt': 1,
          },
        ],
        'story_messages.json': [
          {
            'id': 1,
            'roomId': 77,
            'speakerRole': 'user',
            'speakerName': '旧远端',
            'content': '没有 speakerPersonaKey 的旧消息',
            'createdAt': 1,
            'updatedAt': 1,
          },
        ],
      }));
      final dangling = await newDb();
      final danglingResult = await BackupService(dangling)
          .importArchive(danglingBytes, accountHash: 'acc1');
      expect(danglingResult.warnings.join('\n'), contains('Persona 不在备份中'));
      expect((await dangling.db.query('tb_story_room')).single['personaKey'],
          isNull);
      expect(
        (await dangling.db.query('tb_story_message'))
            .single['speakerPersonaKey'],
        isNull,
      );
      await src.db.close();
      await dst.db.close();
      await dangling.db.close();
    });
  });
}
