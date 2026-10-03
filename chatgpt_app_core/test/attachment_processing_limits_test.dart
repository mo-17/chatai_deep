import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('attachment_limits_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
  });

  test('默认提高至二十万字符和10MiB，非法字段分别兜底', () {
    const defaults = AttachmentProcessingLimits();
    expect(defaults.maxTextChars, 200000);
    expect(defaults.maxTextFileBytes, 10 * 1024 * 1024);
    final invalidChars = const AttachmentProcessingLimits(
            maxTextChars: 0, maxTextFileBytes: 1024 * 1024)
        .normalized;
    expect(invalidChars.maxTextChars, defaults.maxTextChars);
    expect(invalidChars.maxTextFileBytes, 1024 * 1024);
    final invalidBytes = const AttachmentProcessingLimits(
            maxTextChars: 1048576, maxTextFileBytes: 33 * 1024 * 1024)
        .normalized;
    expect(invalidBytes.maxTextChars, 1048576);
    expect(invalidBytes.maxTextFileBytes, defaults.maxTextFileBytes);
  });

  test('默认接收超过旧30000字符的正文，发送与落库均保留全文', () async {
    final text = '${'n' * 35000}NOVEL_END';
    final file = await File('${root.path}/novel.txt').writeAsString(text);
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none());
    expect(result.hasWarnings, isFalse);
    expect(result.extraText, contains(text));
    expect(result.metas.single.extractedText, result.extraText);
  });

  test('用户字符限制决定实际截断位置和预检文案，知识库入口同样生效', () async {
    const limits = AttachmentProcessingLimits(maxTextChars: 5000);
    final file = await File('${root.path}/novel.txt')
        .writeAsString('${'n' * 5000}NOVEL_END');
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        limits: limits);
    expect(result.extraText, contains('n' * 5000));
    expect(result.extraText, isNot(contains('NOVEL_END')));
    expect(
        result.diagnostics.single.kind, FileProcessingDiagnosticKind.truncated);
    expect(result.diagnostics.single.message, '文字超过 5000 字符，仅发送前 5000 字符');
    expect(result.metas.single.extractedText, result.extraText);
    final imported =
        await FileProcessor.extractTextForImport(file.path, limits: limits);
    expect(imported, startsWith('n' * 5000));
    expect(imported, isNot(contains('NOVEL_END')));
  });

  test('提高字节限制后可处理超过旧2MiB文件，自定义1MiB仍在读取前拒绝', () async {
    final file = await File('${root.path}/large.txt')
        .writeAsString('n' * (2 * 1024 * 1024 + 1));
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none());
    expect(result.metas.single.size, 2 * 1024 * 1024 + 1);
    expect(result.diagnostics.single.message, '文字超过 200000 字符，仅发送前 200000 字符');
    const limits = AttachmentProcessingLimits(maxTextFileBytes: 1024 * 1024);
    final tooLarge = isA<FormatException>()
        .having((e) => e.message, 'message', contains('最多 1 MiB'));
    await expectLater(
        FileProcessor.process([file.path], const ModelCapabilities.none(),
            limits: limits),
        throwsA(tooLarge));
    await expectLater(
        FileProcessor.validateKnowledgeImportFile(file.path, limits: limits),
        throwsA(tooLarge));
  });

  test('知识库预检对非整数MiB配置显示准确字节，不向下取整', () async {
    const limits =
        AttachmentProcessingLimits(maxTextFileBytes: 1024 * 1024 + 1);
    final file = await File('${root.path}/large.txt')
        .writeAsBytes(Uint8List(1024 * 1024 + 2));
    await expectLater(
        FileProcessor.validateKnowledgeImportFile(file.path, limits: limits),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('最多 1048577 bytes'))));
  });

  test('PDF降级与重试均使用字符配置，PDF页数和字节限制保持不变', () async {
    final document = PdfDocument();
    final text = List.generate(40, (i) => 'line$i ${'n' * 50}').join('\n');
    document.pages
        .add()
        .graphics
        .drawString(text, PdfStandardFont(PdfFontFamily.helvetica, 12));
    final bytes = Uint8List.fromList(await document.save());
    document.dispose();
    final file = await File('${root.path}/long.pdf').writeAsBytes(bytes);
    const limits = AttachmentProcessingLimits(maxTextChars: 1024);
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        limits: limits);
    final retry = await FileProcessor.processPdfBytes(
        bytes, const ModelCapabilities.none(),
        filename: 'long.pdf', limits: limits);
    expect(result.diagnostics.single.message, 'PDF 文字超过 1024 字符，仅发送前 1024 字符');
    expect(retry.extraText, result.extraText);
    expect(retry.diagnostics.single.message, result.diagnostics.single.message);
    final imported =
        await FileProcessor.extractTextForImport(file.path, limits: limits);
    expect(imported, contains('已截断'));
    expect(result.extraText, contains(imported));
    expect(FileProcessor.maxPdfPages, 20);
    expect(FileProcessor.defaultPdfLimit, 32 * 1024 * 1024);
  });
}
