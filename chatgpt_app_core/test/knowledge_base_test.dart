import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/data/knowledge_chunker.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// L4a（关键词知识库）验收：切分器、DAO 增删检索、knowledge_search 工具、注册表登记。
void main() {
  group('KnowledgeChunker.split', () {
    test('空文本 -> 空列表', () {
      expect(KnowledgeChunker.split(''), isEmpty);
      expect(KnowledgeChunker.split('   \n  '), isEmpty);
    });

    test('按段落聚合，不超过上限', () {
      final text = '${'a' * 100}\n\n${'b' * 100}\n\n${'c' * 100}';
      final chunks = KnowledgeChunker.split(text, maxChars: 250);
      // 100+100 拼一块（含换行 201），第三段另起。
      expect(chunks.length, 2);
      expect(chunks.every((c) => c.length <= 250), isTrue);
    });

    test('超长单段按字符硬切', () {
      final chunks = KnowledgeChunker.split('x' * 1000, maxChars: 300);
      expect(chunks.length, 4); // 300+300+300+100
      expect(chunks.first.length, 300);
    });
  });

  group('KnowledgeDao（真实 DAO + ffi 内存库）', () {
    setUpAll(() => sqfliteFfiInit());

    late HiDBManager storage;
    late KnowledgeDao dao;

    setUp(() async {
      storage = HiDBManager.test(
          await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      dao = await KnowledgeDao.create(storage);
    });
    tearDown(() async => storage.db.close());

    test('导入 -> 列表 -> 检索 -> 删除 全链路', () async {
      final id = await dao.addDocument(
          '退款政策', '我们的退款政策：7 天内无理由退款。\n\n运费由买家承担。');
      expect(id, isNotNull);

      final docs = await dao.getDocuments();
      expect(docs.single.title, '退款政策');
      expect(docs.single.chunkCount, greaterThan(0));

      final hits = await dao.search('退款');
      expect(hits, isNotEmpty);
      expect(hits.first.docTitle, '退款政策');
      expect(hits.any((h) => h.content.contains('7 天')), isTrue);

      await dao.deleteDocument(id!);
      expect(await dao.getDocuments(), isEmpty);
      expect(await dao.search('退款'), isEmpty); // chunk 一并删除
    });

    test('多词检索为「与」：全部命中才返回', () async {
      await dao.addDocument('A', '苹果和香蕉都很甜');
      await dao.addDocument('B', '只有苹果');
      expect((await dao.search('苹果 香蕉')).length, 1); // 仅 A 同时含两词
      expect((await dao.search('苹果')).length, 2);
    });

    test('空文本不建文档', () async {
      expect(await dao.addDocument('空', '   '), isNull);
      expect(await dao.getDocuments(), isEmpty);
    });
  });

  group('knowledge_search 工具 + 注册表', () {
    setUpAll(() => sqfliteFfiInit());

    test('execute：检索命中返回 source+content；未命中友好提示', () async {
      final storage = HiDBManager.test(
          await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      final dao = await KnowledgeDao.create(storage);
      await dao.addDocument('手册', 'K8s 的 Pod 是最小调度单元');
      final ctx = ToolActionContext(openStorage: () async => storage);

      final ok =
          await BuiltinTools.knowledgeSearch(ctx).execute({'query': 'Pod'});
      final list = jsonDecode(ok.content) as List;
      expect(list.first['source'], '手册');
      expect((list.first['content'] as String).contains('Pod'), isTrue);

      final miss = await BuiltinTools.knowledgeSearch(ctx)
          .execute({'query': '不存在zzz'});
      expect(miss.content, contains('没有找到'));
      await storage.db.close();
    });

    test('catalog 含 knowledge_search（只读）+ fromAssistant 装配', () async {
      expect(ToolRegistry.catalog.any((d) => d.id == 'knowledge_search'), isTrue);
      final storage = HiDBManager.test(
          await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      final r = ToolRegistry.fromAssistant(
        AISettings.defaults(),
        const ['knowledge_search'],
        actions: ToolActionContext(openStorage: () async => storage),
      );
      expect(r.byName('knowledge_search'), isNotNull);
      // 缺 actions 不装配。
      expect(
          ToolRegistry.fromAssistant(
                  AISettings.defaults(), const ['knowledge_search'])
              .isEmpty,
          isTrue);
      await storage.db.close();
    });
  });
}
