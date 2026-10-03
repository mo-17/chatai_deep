import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/db/skill_catalog_dao.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_service.dart';
import 'package:chatgpt_app_core/skill/skill_catalog_entry.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  final stores = <HiDBManager>[];
  final dirs = <Directory>[];

  Future<HiDBManager> newDb() async {
    final dir = await Directory.systemTemp.createTemp('skill_catalog_test');
    dirs.add(dir);
    final storage = HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${dir.path}/test.db'),
    );
    stores.add(storage);
    await AssistantDao.create(storage);
    return storage;
  }

  tearDown(() async {
    for (final store in stores) {
      await store.db.close();
    }
    stores.clear();
    for (final dir in dirs) {
      await dir.delete(recursive: true);
    }
    dirs.clear();
  });

  List<int> zip({String name = 'novel-writing', String body = '正文秘密：黄金三章'}) {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
        '$name/SKILL.md',
        utf8.encode('---\nname: $name\ndescription: 用于小说大纲和改写\n---\n$body'),
      ))
      ..addFile(ArchiveFile.bytes(
        '$name/references/outline.md',
        utf8.encode('引用秘密：伏笔与冲突。'),
      ));
    return ZipEncoder().encodeBytes(archive);
  }

  Future<AssistantModel> import(HiDBManager storage, {String? body}) async {
    final assistants = await AssistantDao.create(storage);
    final kb = await KnowledgeDao.create(storage);
    final result = await SkillImportService.import(
      SkillImportService.parseArchive(zip(body: body ?? '正文秘密：黄金三章')),
      assistantDao: assistants,
      knowledgeDao: kb,
    );
    return (await assistants.getAssistant(result.assistantId))!;
  }

  test('真实 ZIP 导入后目录只展示名称描述，调用工具才返回正文与指定引用', () async {
    final storage = await newDb();
    final assistant = await import(storage);
    final service = await SkillCatalogService.create(storage);
    final snapshot = await service.prepare(assistant: assistant);

    expect(snapshot.systemPrompt, contains('novel-writing'));
    expect(snapshot.systemPrompt, contains('用于小说大纲和改写'));
    expect(snapshot.systemPrompt, isNot(contains('正文秘密')));
    expect(snapshot.systemPrompt, isNot(contains('引用秘密')));
    expect(snapshot.replacesAssistantPrompt, isTrue);
    // 老路径仍使用完全相同的 prompt 与已有 knowledge_search。
    expect(assistant.prompt, contains('正文秘密'));
    expect(assistant.toolIds, ['knowledge_search']);

    final tool = snapshot.tools.single;
    final loaded = jsonDecode(
      (await tool.execute({'name': 'novel-writing'})).content,
    ) as Map;
    expect(loaded['text'], contains('正文秘密'));
    expect(loaded['text'], contains('知识库检索'));
    expect(loaded['references'], [
      {'name': 'references/outline.md', 'title': 'outline'},
    ]);
    final reference = jsonDecode((await tool.execute({
      'name': 'novel-writing',
      'reference': 'references/outline.md',
    }))
        .content) as Map;
    expect(reference['text'], '引用秘密：伏笔与冲突。');
  });

  test('旧 Skill 助手无目录记录时按需加载原始 prompt，不迁移或修改原助手', () async {
    final storage = await newDb();
    final dao = await AssistantDao.create(storage);
    final assistant = AssistantModel(
      name: '旧技能',
      emoji: '🧩',
      prompt: '旧助手完整正文\n知识库桥接说明保持原样。',
    );
    await dao.saveAssistant(assistant);
    final service = await SkillCatalogService.create(storage);
    final snapshot = await service.prepare(assistant: assistant);
    expect(snapshot.systemPrompt, isNot(contains('完整正文')));
    final result = jsonDecode((await snapshot.tools.single.execute({
      'name': '旧技能',
    }))
        .content) as Map;
    expect(result['text'], assistant.prompt);
    expect(await service.dao.list(), isEmpty);
    expect((await dao.getAssistant(assistant.id!))!.prompt, assistant.prompt);
    await dao.deleteAssistant(assistant.id!);
    expect(
        jsonDecode((await snapshot.tools.single.execute({
          'name': '旧技能',
        }))
            .content),
        contains('error'));
  });

  test('读取分页有界，拒绝无效页、未注册技能与本机路径', () async {
    final storage = await newDb();
    await import(storage, body: 'a' * 15000);
    final snapshot =
        await (await SkillCatalogService.create(storage)).prepare();
    final tool = snapshot.tools.single;
    final first = jsonDecode((await tool.execute({
      'name': 'novel-writing',
      'max_chars': 100,
    }))
        .content) as Map;
    expect((first['text'] as String).length, 100);
    expect(first['next_offset'], 100);
    final second = jsonDecode((await tool.execute({
      'name': 'novel-writing',
      'offset': 100,
      'max_chars': 100,
    }))
        .content) as Map;
    expect(second['offset'], 100);
    for (final args in [
      {'name': '/etc/passwd'},
      {'name': 'novel-writing', 'reference': '../../secret'},
      {'name': 'novel-writing', 'offset': -1},
      {'name': 'novel-writing', 'offset': 999999},
      {'name': 'novel-writing', 'max_chars': 12001},
      {'name': 'novel-writing', 'max_chars': 1.5},
    ]) {
      expect(jsonDecode((await tool.execute(args)).content), contains('error'));
    }
  });

  test('账号数据库相互隔离；助手删除后旧目录与既有工具均不可读取', () async {
    final first = await newDb();
    final second = await newDb();
    final assistant = await import(first);
    final firstService = await SkillCatalogService.create(first);
    final snapshot = await firstService.prepare();
    final empty = await (await SkillCatalogService.create(second)).prepare();
    expect(empty.tools, isEmpty);
    expect(empty.entries, isEmpty);

    await (await AssistantDao.create(first)).deleteAssistant(assistant.id!);
    expect((await firstService.prepare()).entries, isEmpty);
    expect(
        jsonDecode((await snapshot.tools.single.execute({
          'name': 'novel-writing',
        }))
            .content),
        contains('error'));
  });

  test('恢复或编辑助手后不会把同 id 的旧引用挂给新 prompt', () async {
    final storage = await newDb();
    final assistant = await import(storage);
    assistant.prompt = '编辑后的新正文';
    await (await AssistantDao.create(storage)).saveAssistant(assistant);
    final service = await SkillCatalogService.create(storage);
    expect(await service.dao.list(), isEmpty);
    final snapshot = await service.prepare(assistant: assistant);
    final result = jsonDecode((await snapshot.tools.single.execute({
      'name': 'novel-writing',
    }))
        .content) as Map;
    expect(result['text'], '编辑后的新正文');
    expect(result['references'], isEmpty);
  });

  test('重复导入同名 Skill 用 @助手编号精确区分', () async {
    final storage = await newDb();
    final first = await import(storage, body: '第一个正文');
    final second = await import(storage, body: '第二个正文');
    final snapshot =
        await (await SkillCatalogService.create(storage)).prepare();
    final tool = snapshot.tools.single;
    expect(snapshot.systemPrompt, contains('novel-writing@${first.id}'));
    expect(snapshot.systemPrompt, contains('novel-writing@${second.id}'));
    final result = jsonDecode((await tool.execute({
      'name': 'novel-writing@${first.id}',
    }))
        .content) as Map;
    expect(result['text'], contains('第一个正文'));
    expect(jsonDecode((await tool.execute({'name': 'novel-writing'})).content),
        contains('error'));
  });

  test('DAO 拒绝引用路径穿越，不允许保存超量正文', () {
    expect(
      () => SkillCatalogDao.validateContent(
        body: 'x' * (SkillCatalogDao.maxBodyChars + 1),
        references: [],
      ),
      throwsFormatException,
    );
    expect(
      () => SkillCatalogDao.validateContent(
        body: '正文',
        references: const [
          SkillCatalogReference(
            name: '../secret.txt',
            title: 'secret',
            text: 'text',
          ),
        ],
      ),
      throwsFormatException,
    );
  });

  test('不安全的手工 SkillPackage 在写助手或知识库前拒绝', () async {
    final storage = await newDb();
    final assistants = await AssistantDao.create(storage);
    final kb = await KnowledgeDao.create(storage);
    await expectLater(
      SkillImportService.import(
        const SkillPackage(
          name: 'bad-path',
          emoji: '🧩',
          description: '',
          systemPrompt: '正文',
          references: [
            SkillReference(title: 'secret', path: '../secret.txt', text: '引用'),
          ],
        ),
        assistantDao: assistants,
        knowledgeDao: kb,
      ),
      throwsFormatException,
    );
    expect(await assistants.getAssistants(), isEmpty);
    expect(await kb.getDocuments(), isEmpty);
  });

  test('全新账号尚无助手表时目录可正常初始化为空', () async {
    final dir = await Directory.systemTemp.createTemp('skill_empty_account');
    dirs.add(dir);
    final storage = HiDBManager.test(
      await databaseFactoryFfi.openDatabase('${dir.path}/test.db'),
    );
    stores.add(storage);
    final snapshot =
        await (await SkillCatalogService.create(storage)).prepare();
    expect(snapshot.systemPrompt, isEmpty);
    expect(snapshot.tools, isEmpty);
  });
}
