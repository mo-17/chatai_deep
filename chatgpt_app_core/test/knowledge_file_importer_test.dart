import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
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

  test('自定义字符上限进入知识库正文，旧调用使用提高后的默认值', () async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_chars_');
    addTearDown(() async => dir.delete(recursive: true));
    final file = await File('${dir.path}/novel.txt')
        .writeAsString('NOVEL_START${'x' * 35000}NOVEL_END');
    final dao = await newDao();
    final importer = KnowledgeFileImporter(dao);
    final limited = await importer.importPaths([file.path],
        limits: const AttachmentProcessingLimits(maxTextChars: 1024));
    expect(limited.imported, 1);
    final limitedDoc = (await dao.getDocuments()).single;
    final limitedRows = await dao.storage.db.query('tb_kb_chunk',
        where: 'docId = ?', whereArgs: [limitedDoc.id], orderBy: 'seq');
    final limitedText =
        limitedRows.map((row) => row['content'] as String).join('');
    expect(limitedText, contains('NOVEL_START'));
    expect(limitedText, isNot(contains('NOVEL_END')));
    expect(limitedText, contains('已截断'));
    expect(RegExp('x').allMatches(limitedText).length,
        1024 - 'NOVEL_START'.length);

    final defaultResult = await importer.importPaths([file.path]);
    expect(defaultResult.imported, 1);
    final docs = await dao.getDocuments();
    final defaultDoc = docs.singleWhere((doc) => doc.id != limitedDoc.id);
    final defaultRows = await dao.storage.db.query('tb_kb_chunk',
        where: 'docId = ?', whereArgs: [defaultDoc.id], orderBy: 'seq');
    final defaultText =
        defaultRows.map((row) => row['content'] as String).join('');
    expect(defaultText, contains('NOVEL_END'));
    expect(defaultText, isNot(contains('已截断')));
  });

  test('知识库自定义字节限制拒绝超限文件且不写DAO，同批合法文件照常导入', () async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_bytes_');
    addTearDown(() async => dir.delete(recursive: true));
    final oversized = await File('${dir.path}/oversized.txt')
        .writeAsString('n' * (1024 * 1024 + 1));
    final legal = await File('${dir.path}/legal.txt').writeAsString('legal');
    final dao = await newDao();
    final result = await KnowledgeFileImporter(dao).importPaths([
      oversized.path,
      legal.path
    ], limits: const AttachmentProcessingLimits(maxTextFileBytes: 1024 * 1024));
    expect(result.imported, 1);
    expect(result.failedItems.single.name, 'oversized.txt');
    expect(result.failedItems.single.reason, contains('最多 1 MiB'));
    expect((await dao.getDocuments()).single.title, 'legal');
    final chunks = await dao.storage.db.query('tb_kb_chunk');
    expect(chunks, hasLength(1));
    expect(chunks.single['content'], 'legal');
  });
}
