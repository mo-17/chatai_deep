import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<KnowledgeDao> newDao() async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_db_');
    addTearDown(() async => dir.delete(recursive: true));
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/test.db');
    addTearDown(db.close);
    return KnowledgeDao.create(HiDBManager.test(db));
  }

  test('批量导入多个文本文件，并按文件名创建知识库文档', () async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_test_');
    addTearDown(() async => dir.delete(recursive: true));
    final a = File('${dir.path}/alpha.txt')..writeAsStringSync('alpha content');
    final b = File('${dir.path}/beta.md')..writeAsStringSync('beta content');
    final dao = await newDao();

    final result =
        await KnowledgeFileImporter(dao).importPaths([a.path, b.path]);

    expect(result.total, 2);
    expect(result.imported, 2);
    expect(result.skipped, 0);
    expect(result.message, '已导入 2 个文档');
    final docs = await dao.getDocuments();
    expect(docs.map((doc) => doc.title), containsAll(['alpha', 'beta']));
  });

  test('批量导入时跳过不支持或空内容文件，不影响其它文件', () async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_test_');
    addTearDown(() async => dir.delete(recursive: true));
    final ok = File('${dir.path}/ok.txt')..writeAsStringSync('usable text');
    final unsupported = File('${dir.path}/binary.bin')
      ..writeAsBytesSync([0, 1, 2, 3]);
    final empty = File('${dir.path}/empty.txt')..writeAsStringSync('');
    final dao = await newDao();

    final result = await KnowledgeFileImporter(dao)
        .importPaths([ok.path, unsupported.path, empty.path]);

    expect(result.total, 3);
    expect(result.imported, 1);
    expect(result.skipped, 2);
    expect(result.message, '已导入 1 个文档，2 个文件跳过');
    expect(result.failedItems, hasLength(2));
    expect(result.detailMessage, contains('binary.bin：'));
    expect(result.detailMessage, contains('empty.txt：未提取到文字'));
    expect(
        result.items.where((item) => !item.imported).map((item) => item.name),
        containsAll(['binary.bin', 'empty.txt']));
    final docs = await dao.getDocuments();
    expect(docs, hasLength(1));
    expect(docs.single.title, 'ok');
  });

  test('超限文本在读取/解析前被拒绝，同行合法文件仍可导入', () async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_limit_');
    addTearDown(() async => dir.delete(recursive: true));
    final oversized = File('${dir.path}/oversized.txt')
      ..writeAsBytesSync(
        List<int>.filled(FileProcessor.maxTextFileBytes + 1, 0x41),
      );
    final legal = File('${dir.path}/legal.txt')
      ..writeAsStringSync('bounded legal text');
    final dao = await newDao();

    final result = await KnowledgeFileImporter(dao)
        .importPaths([oversized.path, legal.path]);

    expect(result.imported, 1);
    expect(result.failedItems.single.name, 'oversized.txt');
    expect(result.failedItems.single.reason, contains('文件过大'));
    expect((await dao.getDocuments()).single.title, 'legal');
  });
}
