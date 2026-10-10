import 'dart:async';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment_preflight_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
  });

  Future<File> textFile(String name, String content) async =>
      File('${root.path}/$name').writeAsString(content);

  Future<File> pdfFile(String name, {int pages = 1, bool empty = false}) async {
    final document = PdfDocument();
    for (var i = 0; i < pages; i++) {
      final page = document.pages.add();
      if (!empty) {
        page.graphics.drawString(
            'page ${i + 1}', PdfStandardFont(PdfFontFamily.helvetica, 12));
      }
    }
    final bytes = await document.save();
    document.dispose();
    return File('${root.path}/$name').writeAsBytes(bytes);
  }

  test('老调用与落库格式不变，正常文件无诊断并逐个报告准备阶段', () async {
    final first = await textFile('first.txt', 'old text');
    final second = await textFile('second.md', 'new text');
    final progress = <ChatSendProgress>[];
    final result = await FileProcessor.process(
        [first.path, second.path], const ModelCapabilities.none(),
        onProgress: progress.add);
    expect(result.hasWarnings, isFalse);
    expect(result.extraText, contains('old text'));
    expect(result.metas.first.extractedText, contains('old text'));
    expect(result.metas.first.toJson().keys,
        unorderedEquals(['name', 'path', 'mime', 'size', 'extractedText']));
    expect(progress.map((p) => p.fileName), ['first.txt', 'second.md']);
    expect(progress.map((p) => p.index), [1, 2]);
    expect(progress.map((p) => p.total), [2, 2]);
    expect(progress.every((p) => p.fraction == null), isTrue);
    expect(const ProcessedFiles().diagnostics, isEmpty);
  });

  test('截断、空文件及非法UTF8会给出明确预检诊断而保留旧文本包裹', () async {
    final long =
        await textFile('long.txt', 'x' * (FileProcessor.maxTextChars + 10));
    final blank = await textFile('blank.txt', '   \n');
    final invalid =
        await File('${root.path}/invalid.txt').writeAsBytes([0xff, 0xfe]);
    final result = await FileProcessor.process(
        [long.path, blank.path, invalid.path], const ModelCapabilities.none());
    expect(result.hasWarnings, isTrue);
    expect(result.diagnostics.map((d) => d.kind), [
      FileProcessingDiagnosticKind.truncated,
      FileProcessingDiagnosticKind.empty,
      FileProcessingDiagnosticKind.failed,
    ]);
    expect(result.diagnostics.map((d) => d.filename),
        ['long.txt', 'blank.txt', 'invalid.txt']);
    expect(result.extraText, contains('已截断'));
    expect(result.extraText, contains('[附件「invalid.txt」内容开始]'));
    expect(result.extraText, isNot(contains(root.path)));
  });

  test('扫描PDF、超过20页与损坏PDF分别诊断，原生PDF保持原来的part', () async {
    final scan = await pdfFile('scan.pdf', empty: true);
    final long =
        await pdfFile('long.pdf', pages: FileProcessor.maxPdfPages + 1);
    final broken = await textFile('broken.pdf', 'broken');
    final result = await FileProcessor.process(
        [scan.path, long.path, broken.path], const ModelCapabilities.none());
    expect(result.diagnostics.map((d) => d.kind), [
      FileProcessingDiagnosticKind.scannedPdf,
      FileProcessingDiagnosticKind.truncated,
      FileProcessingDiagnosticKind.failed,
    ]);
    expect(result.extraText, contains('仅抽取前 20 页'));
    expect(result.extraText, contains('可能是扫描件'));
    final native = await FileProcessor.process(
        [scan.path], const ModelCapabilities(pdf: true));
    expect(native.nativeFiles.single.filename, 'scan.pdf');
    expect(native.extraText, isEmpty);
    expect(native.diagnostics, isEmpty);
  });

  test('取消在文件读取前生效，取消后不继续下一附件', () async {
    final first = await textFile('first.txt', 'first');
    final second = await textFile('second.txt', 'second');
    final abort = Completer<void>();
    final progress = <ChatSendProgress>[];
    await expectLater(
        FileProcessor.process(
          [first.path, second.path],
          const ModelCapabilities.none(),
          abortTrigger: abort.future,
          onProgress: (p) {
            progress.add(p);
            abort.complete();
          },
        ),
        throwsA(isA<AttachmentProcessingCancelledException>()));
    expect(progress, hasLength(1));
    expect(await Directory('${root.path}/managed').exists(), isFalse);
    final done = Completer<void>()..complete();
    await expectLater(
        FileProcessor.encodeImages(['${root.path}/missing.png'],
            abortTrigger: done.future),
        throwsA(isA<AttachmentProcessingCancelledException>()));
  });

  test('图片准备按个报告，展示回调异常不阻止附件处理', () async {
    final first = await File('${root.path}/first.png').writeAsBytes([1]);
    final second = await File('${root.path}/second.jpg').writeAsBytes([2]);
    final progress = <ChatSendProgress>[];
    final encoded = await FileProcessor.encodeImages([first.path, second.path],
        onProgress: progress.add);
    expect(encoded, hasLength(2));
    expect(progress.map((p) => p.label), everyElement('准备图片'));
    expect(progress.map((p) => p.index), [1, 2]);
    final file = await textFile('plain.txt', 'ok');
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        onProgress: (_) => throw StateError('disposed widget'));
    expect(result.extraText, contains('ok'));
  });
}
