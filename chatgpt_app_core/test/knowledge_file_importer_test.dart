import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_import_collection.dart';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  Future<File> pdfFile(Directory dir, String name, List<String> pages) async {
    final doc = PdfDocument();
    try {
      for (final text in pages) {
        final page = doc.pages.add();
        if (text.isNotEmpty) {
          page.graphics
              .drawString(text, PdfStandardFont(PdfFontFamily.helvetica, 18));
        }
      }
      return await File('${dir.path}/$name').writeAsBytes(await doc.save());
    } finally {
      doc.dispose();
    }
  }

  test('混合 PDF 只 OCR 缺字页，空白页不使后续引用页码偏移', () async {
    final dir = await Directory.systemTemp.createTemp('kb_pdf_pages_');
    addTearDown(() => dir.delete(recursive: true));
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    addTearDown(() => messenger.setMockMethodCallHandler(pathChannel, null));
    final file = await pdfFile(dir, 'mixed.pdf',
        ['TEXT PAGE ONE preserved verbatim', '', '', '', 'TEXT PAGE FIVE']);
    final dao = await newDao();
    final importer = KnowledgeFileImporter(dao, pdfOcr: (path, pages) async {
      expect(path, file.path);
      expect(pages, [2, 3, 4]);
      return PdfOcrResult(
          totalPages: 5,
          pages: ['', 'SCAN PAGE TWO', '', 'SCAN PAGE FOUR', '']);
    });
    expect((await importer.importPaths([file.path])).imported, 1);
    final chunks = await dao.storage.db.query('tb_kb_chunk', orderBy: 'seq');
    expect(chunks.map((r) => r['pageNumber']), [1, 2, 4, 5]);
    expect(
        chunks.first['content'], contains('TEXT PAGE ONE preserved verbatim'));
    expect(chunks[1]['content'], 'SCAN PAGE TWO');
    expect(chunks[2]['content'], 'SCAN PAGE FOUR');
    expect((await dao.getDocuments()).single.sourceKind, 'pdf');
  });

  test('超页、OCR 页数错误和 OCR 后超字符预算均不落库', () async {
    final dir = await Directory.systemTemp.createTemp('kb_pdf_reject_');
    addTearDown(() => dir.delete(recursive: true));
    final tooMany = await pdfFile(dir, 'limit.pdf', List.filled(21, ''));
    final scan = await pdfFile(dir, 'scan.pdf', ['', '']);
    final dao = await newDao();
    var called = false;
    final importer = KnowledgeFileImporter(dao, pdfOcr: (_, __) async {
      called = true;
      return PdfOcrResult(totalPages: 1, pages: ['wrong']);
    });
    final cap = await importer.importPaths([tooMany.path]);
    expect(cap.imported, 0);
    expect(cap.detailMessage, contains('页数超过'));
    expect(called, false);
    expect((await importer.importPaths([scan.path])).detailMessage,
        contains('页数与原 PDF 不一致'));
    final budget = await KnowledgeFileImporter(dao,
            pdfOcr: (_, __) async =>
                PdfOcrResult(totalPages: 2, pages: ['x' * 1200, 'y' * 1200]))
        .importPaths([scan.path],
            limits: const AttachmentProcessingLimits(maxTextChars: 1024));
    expect(budget.imported, 0);
    expect(budget.detailMessage, contains('文字超过导入预算'));
    expect(await dao.getDocuments(), isEmpty);
  });

  test('资料 ZIP 检查后可通过现有导入器落库并清理临时副本', () async {
    final dir = await Directory.systemTemp.createTemp('kb_collection_db_');
    addTearDown(() => dir.delete(recursive: true));
    final zip = Archive()
      ..addFile(
          ArchiveFile.bytes('folder/alpha.txt', utf8.encode('alpha content')))
      ..addFile(ArchiveFile.bytes('beta.md', utf8.encode('beta content')));
    final input = await File('${dir.path}/documents.zip')
        .writeAsBytes(ZipEncoder().encode(zip));
    final collection = await KnowledgeImportCollection.fromZip(input.path,
        temporaryDirectory: () async => dir);
    final dao = await newDao();
    try {
      final result =
          await KnowledgeFileImporter(dao).importPaths(collection.paths);
      expect(result.imported, 2);
      expect((await dao.getDocuments()).map((d) => d.title),
          containsAll(['alpha', 'beta']));
    } finally {
      await collection.dispose();
    }
    expect(await input.exists(), true);
    expect(await File(collection.paths.first).exists(), false);
  });

  test('账号或页面失效后不再写入本批文档', () async {
    final dir = await Directory.systemTemp.createTemp('kb_importer_identity_');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File('${dir.path}/note.txt').writeAsString('content');
    final dao = await newDao();
    final before = await KnowledgeFileImporter(dao, isCurrent: () => false)
        .importPaths([file.path]);
    expect(before.imported, 0);
    expect(await dao.getDocuments(), isEmpty);
    var checks = 0;
    final during =
        await KnowledgeFileImporter(dao, isCurrent: () => ++checks < 2)
            .importPaths([file.path]);
    expect(during.imported, 0);
    expect(await dao.getDocuments(), isEmpty);
  });

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
