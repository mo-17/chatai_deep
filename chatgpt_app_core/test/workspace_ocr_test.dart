import 'dart:io';
import 'dart:typed_data';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/attachment_ocr.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:chatgpt_app_core/chat/application/workspace_attachment_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late AgentWorkspaceService workspace;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('workspace_ocr_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${directory.path}/managed');
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    workspace =
        await AgentWorkspaceService.create(HiDBManager.test(db), cid: 41);
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await directory.delete(recursive: true);
  });
  Future<Uint8List> pdf(List<String> pages) async {
    final document = PdfDocument();
    try {
      for (final text in pages) {
        document.pages
            .add()
            .graphics
            .drawString(text, PdfStandardFont(PdfFontFamily.helvetica, 12));
      }
      return Uint8List.fromList(await document.save());
    } finally {
      document.dispose();
    }
  }

  test('混合扫描件只识别缺字页，按页工具可读且清单不携带全文', () async {
    final bytes = await pdf([
      'FIRST native readable text preserved',
      '',
      'THIRD native readable text preserved'
    ]);
    final file = await File('${directory.path}/mixed.pdf').writeAsBytes(bytes);
    final processed = await WorkspaceAttachmentProcessor(workspace)
        .process([file.path], limits: const AttachmentProcessingLimits(),
            ocr: (request) async {
      expect(request.bytes, bytes);
      expect(request.totalPages, 3);
      expect(request.pageNumbers, [2]);
      return PdfOcrResult(
          totalPages: 3, pages: ['forged', 'SECOND scanned text', 'forged']);
    });
    final id = processed.metas.single.workspaceFileId!;
    final revision = await workspace.getRevision(id);
    expect(revision.pageTexts[0], contains('FIRST native'));
    expect(revision.pageTexts[1], 'SECOND scanned text');
    expect(revision.pageTexts[2], contains('THIRD native'));
    expect(
        ((await workspace.readFile(id, page: 2))['content'] as String).trim(),
        'SECOND scanned text');
    expect(processed.extraText, isNot(contains('SECOND scanned text')));
    expect(processed.extraText, contains('read_file'));
  });
  test('图片可作为任务输入，原件大小及分页正文持久化', () async {
    final file = await workspace.importBytes(Uint8List.fromList([1, 2, 3]),
        name: 'scan.png', maxBytes: 1024, ocr: (request) async {
      expect(request.pdf, false);
      return PdfOcrResult(totalPages: 1, pages: ['图片中的文字']);
    });
    expect(file.sizeBytes, 3);
    expect((await workspace.getRevision(file.id)).pageTexts, ['图片中的文字']);
  });
  test('识别期间停止时不写入工作区', () async {
    var current = true;
    await expectLater(
        workspace.importBytes(await pdf(['']),
            name: 'scan.pdf',
            maxBytes: 100000,
            canCommit: () => current,
            ocr: (_) async {
              current = false;
              return PdfOcrResult(totalPages: 1, pages: ['late']);
            }),
        throwsA(isA<AttachmentOcrException>()));
    expect(await workspace.listFiles(), isEmpty);
  });
  test('OCR 错页和拒绝上传均不留下输入文件', () async {
    final bytes = await pdf(['', '']);
    await expectLater(
        workspace.importBytes(bytes,
            name: 'scan.pdf',
            maxBytes: 100000,
            ocr: (_) async => PdfOcrResult(totalPages: 1, pages: ['wrong'])),
        throwsA(isA<AttachmentOcrException>()));
    await expectLater(
        workspace.importBytes(bytes,
            name: 'scan.pdf',
            maxBytes: 100000,
            ocr: (_) async => throw const AttachmentOcrException('已取消')),
        throwsA(isA<AttachmentOcrException>()));
    expect(await workspace.listFiles(), isEmpty);
  });
  test('识别正文仍在落库前应用整批字数上限', () async {
    final source =
        await File('${directory.path}/scan.pdf').writeAsBytes(await pdf(['']));
    await expectLater(
        WorkspaceAttachmentProcessor(workspace).process([source.path],
            limits: const AttachmentProcessingLimits(maxTotalTextChars: 1024),
            ocr: (_) async => PdfOcrResult(totalPages: 1, pages: ['X' * 2000])),
        throwsA(isA<AttachmentBatchLimitException>()));
    expect(await workspace.listFiles(), isEmpty);
  });
  test('文本 PDF 和 Office/文本原通路不调用 OCR', () async {
    var calls = 0;
    await workspace.importBytes(await pdf(['native text is long enough']),
        name: 'text.pdf', maxBytes: 100000, ocr: (_) async {
      calls++;
      throw StateError('unexpected');
    });
    await workspace.importBytes(Uint8List.fromList('plain text'.codeUnits),
        name: 'text.txt', maxBytes: 100000, ocr: (_) async {
      calls++;
      throw StateError('unexpected');
    });
    expect(calls, 0);
    expect((await workspace.listFiles()).length, 2);
  });
  test('超过服务器页数上限保留本地提取并明确说明未识别扫描页', () async {
    final warnings = <String>[];
    await workspace.importBytes(await pdf(List.filled(21, '')),
        name: 'long.pdf',
        maxBytes: 1000000,
        onWarnings: warnings.addAll,
        ocr: (_) async => throw StateError('must not upload'));
    expect(warnings.join(), contains('最多 20 页'));
  });
}
