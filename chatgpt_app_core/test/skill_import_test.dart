import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/skill/skill_import_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 技能（Agent Skill）导入器验收测试：解析 SKILL.md（frontmatter 折叠块标量 +
/// 正文）、references/ 进知识库、evals/ 排除、落库成助手并绑定知识库检索工具。
/// 走真实 SkillImportService + DAO（HiDBManager.test 注入 ffi 内存库）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ffi 的 ':memory:' 在同进程内会被多次 openDatabase 复用、互相污染，
  // 故每个测试用独立临时文件库，保证表数据隔离。
  Future<HiDBManager> newDb() async {
    final dir = await Directory.systemTemp.createTemp('skill_test');
    return HiDBManager.test(
        await databaseFactoryFfi.openDatabase('${dir.path}/t.db'));
  }

  /// 造一个仿真技能 zip：单层子目录 novel-writing/，含 SKILL.md（folded
  /// description）、两篇 references、一份 evals（应被排除）、一个 .DS_Store。
  List<int> buildSkillZip() {
    const skillMd = '''
---
name: novel-writing
description: >-
  中文网文写作助手。帮助搭建世界观与大纲、撰写正文、润色改写，
  以及卡文时给灵感。提到写小说/网文/正文/大纲都应使用本技能。
---

# 中文网文写作

这个技能帮助创作和打磨中文网络小说。核心是「如何让读者忍不住看下一章」。

> 想了解套路读 references/web-novel-tropes.md。
''';
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
          'novel-writing/SKILL.md', utf8.encode(skillMd)))
      ..addFile(ArchiveFile.bytes('novel-writing/references/web-novel-tropes.md',
          utf8.encode('# 套路库\n\n金手指：系统流、重生流。')))
      ..addFile(ArchiveFile.bytes('novel-writing/references/story-structure.md',
          utf8.encode('# 结构模板\n\n黄金三章定生死。')))
      ..addFile(ArchiveFile.bytes('novel-writing/evals/evals.json',
          utf8.encode('{"skill_name":"novel-writing","evals":[]}')))
      ..addFile(ArchiveFile.bytes('novel-writing/.DS_Store', [0, 1, 2]));
    return ZipEncoder().encodeBytes(archive);
  }

  test('解析：frontmatter 折叠 description + 正文 + references（排除 evals/隐藏文件）',
      () {
    final pkg = SkillImportService.parseArchive(buildSkillZip());

    expect(pkg.name, 'novel-writing');
    // 折叠块标量：多行合成一行（逗号是原文内容，行间以空格连接）。
    expect(pkg.description, contains('中文网文写作助手'));
    expect(pkg.description, contains('卡文时给灵感'));
    expect(pkg.description.contains('\n'), isFalse);
    // 正文不含 frontmatter 分隔符。
    expect(pkg.systemPrompt, contains('# 中文网文写作'));
    expect(pkg.systemPrompt.startsWith('---'), isFalse);
    // 两篇 references，evals.json 与 .DS_Store 被排除。
    expect(pkg.references.length, 2);
    final titles = pkg.references.map((r) => r.title).toSet();
    expect(titles, {'web-novel-tropes', 'story-structure'});
  });

  test('落库：新建助手（正文进提示词 + 桥接说明 + 绑定知识库检索）+ 资料进知识库',
      () async {
    final storage = await newDb();
    final assistantDao = await AssistantDao.create(storage);
    final kbDao = await KnowledgeDao.create(storage);

    final pkg = SkillImportService.parseArchive(buildSkillZip());
    final result = await SkillImportService.import(
      pkg,
      assistantDao: assistantDao,
      knowledgeDao: kbDao,
    );

    expect(result.name, 'novel-writing');
    expect(result.docCount, 2);

    // 助手：名字、提示词含正文与桥接说明、绑定 knowledge_search、useTools。
    final assistants = await assistantDao.getAssistants();
    expect(assistants.length, 1);
    final a = assistants.single;
    expect(a.name, 'novel-writing');
    expect(a.emoji, '🧩');
    expect(a.prompt, contains('# 中文网文写作'));
    expect(a.prompt, contains('知识库检索'));
    expect(a.useTools, isTrue);
    expect(a.toolIds, ['knowledge_search']);

    // 知识库：两篇文档，标题带技能名前缀，可被关键词检索命中。
    final docs = await kbDao.getDocuments();
    expect(docs.length, 2);
    expect(docs.every((d) => d.title.startsWith('novel-writing · ')), isTrue);
    final hits = await kbDao.search('金手指');
    expect(hits, isNotEmpty);
  });

  test('无参考资料的技能：不绑定任何工具', () async {
    final storage = await newDb();
    final assistantDao = await AssistantDao.create(storage);
    final kbDao = await KnowledgeDao.create(storage);

    final archive = Archive()
      ..addFile(ArchiveFile.bytes(
          'SKILL.md',
          utf8.encode('---\nname: pure-prompt\n---\n你是一个助手。')));
    final pkg =
        SkillImportService.parseArchive(ZipEncoder().encodeBytes(archive));
    expect(pkg.references, isEmpty);

    await SkillImportService.import(pkg,
        assistantDao: assistantDao, knowledgeDao: kbDao);
    final a = (await assistantDao.getAssistants()).single;
    expect(a.toolIds, isNull);
    expect(a.prompt, '你是一个助手。');
    expect((await kbDao.getDocuments()), isEmpty);
  });

  test('非法包：缺 SKILL.md 抛 FormatException', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('readme.txt', utf8.encode('hi')));
    final bytes = ZipEncoder().encodeBytes(archive);
    expect(() => SkillImportService.parseArchive(bytes),
        throwsA(isA<FormatException>()));
  });

  test('坏 zip 字节：抛 FormatException', () {
    expect(() => SkillImportService.parseArchive([1, 2, 3, 4]),
        throwsA(isA<FormatException>()));
  });
}
