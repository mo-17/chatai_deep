import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/project_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/model/project_model.dart';
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
      'blocks': '[{"type":"mainText","id":"b1"}]',
    });
    await FavoriteDao.create(storage);
    await storage.db.insert('tb_favorite',
        {'ownerName': 'AI', 'content': '收藏内容', 'createdAt': 333});
    return aid!;
  }

  group('导出/导入 round-trip', () {
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
      // blocks 列原样恢复
      final msgs = await dst.db.query('tb_messages', where: 'createdAt = 222');
      expect(msgs.single['blocks'], '[{"type":"mainText","id":"b1"}]');
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
