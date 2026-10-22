import 'dart:async';
import 'dart:io';
import 'package:chatgpt_app_core/chat/application/knowledge_file_importer.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/knowledge_dao.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late KnowledgeDao dao;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('knowledge_operation_');
    dao = await KnowledgeDao.create(HiDBManager.test(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
            options: OpenDatabaseOptions(singleInstance: false))));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => directory.path);
  });
  tearDown(() async {
    await dao.storage.db.close();
    await directory.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
  });
  Future<File> scan() async {
    final pdf = PdfDocument();
    pdf.pages.add();
    pdf.pages.add();
    try {
      return await File('${directory.path}/scan.pdf')
          .writeAsBytes(await pdf.save());
    } finally {
      pdf.dispose();
    }
  }

  test('取消保留已提交文档，重试仅包含失败及未完成文件', () async {
    final paths = <String>[];
    for (final name in ['alpha', 'beta', 'gamma']) {
      paths.add((await File('${directory.path}/$name.txt')
              .writeAsString('$name content'))
          .path);
    }
    final cancel = ImportCancellation();
    final progress = <KnowledgeImportProgress>[];
    final result = await KnowledgeFileImporter(dao)
        .importPaths(paths, cancellation: cancel, onProgress: (value) {
      progress.add(value);
      if (value.filename == 'beta.txt' && value.stage == '正在保存') {
        cancel.cancel();
      }
    });
    expect(result.cancelled, true);
    expect(result.total, 3);
    expect(result.imported, 1);
    expect(result.retryPaths, paths.skip(1));
    expect((await dao.getDocuments()).single.title, 'alpha');
    expect(progress.last.completed, 1);
    final retry =
        await KnowledgeFileImporter(dao).importPaths(result.retryPaths);
    expect(retry.imported, 2);
    expect(await dao.getDocuments(), hasLength(3));
  });

  test('OCR 等待期间账号或页面变化，拒绝迟到内容和后续文件', () async {
    final file = await scan();
    final next = await File('${directory.path}/next.txt').writeAsString('next');
    var current = true;
    final started = Completer<void>(), release = Completer<void>();
    final importing = KnowledgeFileImporter(dao,
        isCurrent: () => current,
        pdfOcr: (_, __) async {
          started.complete();
          await release.future;
          return PdfOcrResult(
              totalPages: 2, pages: ['late page one', 'late page two']);
        }).importPaths([file.path, next.path]);
    await started.future;
    current = false;
    release.complete();
    final result = await importing;
    expect(result.cancelled, true);
    expect(result.imported, 0);
    expect(await dao.getDocuments(), isEmpty);
  });

  test('取消已发起的 OCR 后不存入部分正文，逐页进度保持原页码', () async {
    final file = await scan();
    final operation = ImportCancellation();
    final events = <KnowledgeImportProgress>[];
    final result = await KnowledgeFileImporter(dao, pdfOcr: (_, __) async {
      operation.cancel();
      return PdfOcrResult(totalPages: 2, pages: ['discard', 'discard']);
    }).importPaths([file.path],
        cancellation: operation, onProgress: events.add);
    expect(events.where((e) => e.page != null).map((e) => e.page), [1, 2]);
    expect(result.imported, 0);
    expect(result.cancelled, true);
    expect(await dao.getDocuments(), isEmpty);
  });

  test('SQLite 提交前作用域失效回滚文档与分块', () async {
    var checks = 0;
    await expectLater(
        dao.addPagedDocument('atomic', ['content'], beforeCommit: () {
          if (++checks == 3) throw const ImportCancelled();
        }),
        throwsA(isA<ImportCancelled>()));
    expect(await dao.getDocuments(), isEmpty);
    expect(await dao.storage.db.query('tb_kb_chunk'), isEmpty);
  });

  test('错误分类使用固定中文，不泄露异常中的路径或正文', () {
    for (final entry in <Object, KnowledgeImportErrorKind>{
      ArgumentError(
              'Cannot open encrypted document /private/user.pdf secret-body'):
          KnowledgeImportErrorKind.encrypted,
      const FormatException('PDF页数超过当前导入上限'): KnowledgeImportErrorKind.tooLarge,
      const FormatException('导入文件过大 /private/user.pdf secret-body'):
          KnowledgeImportErrorKind.tooLarge,
      ArgumentError('Invalid position -1 secret-body'):
          KnowledgeImportErrorKind.damaged,
      const FileSystemException(
              'secret-body', '/private/user.pdf', OSError('missing', 2)):
          KnowledgeImportErrorKind.missing,
      TimeoutException('secret-body'): KnowledgeImportErrorKind.timeout,
      PlatformException(code: 'ocr_busy', message: 'secret-body'):
          KnowledgeImportErrorKind.busy,
    }.entries) {
      final failure = KnowledgeImportFailure.from(entry.key, pdf: true);
      expect(failure.kind, entry.value);
      expect(failure.message, isNot(contains('secret-body')));
      expect(failure.message, isNot(contains('/private')));
    }
  });
}
