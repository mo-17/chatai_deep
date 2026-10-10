import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
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
    expect(defaults.maxTotalFileBytes, 64 * 1024 * 1024);
    expect(defaults.maxTotalTextChars, 1000000);
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

  test('每轮汇总限制接受边界，非法字段独立回退且保留单附件配置', () {
    for (final bytes in [1024 * 1024, 256 * 1024 * 1024]) {
      for (final chars in [1024, 4194304]) {
        final limits = AttachmentProcessingLimits(
                maxTotalFileBytes: bytes, maxTotalTextChars: chars)
            .normalized;
        expect(limits.maxTotalFileBytes, bytes);
        expect(limits.maxTotalTextChars, chars);
      }
    }
    final invalidBytes = const AttachmentProcessingLimits(
      maxTextChars: 8192,
      maxTextFileBytes: 2 * 1024 * 1024,
      maxTotalFileBytes: 256 * 1024 * 1024 + 1,
      maxTotalTextChars: 4194304,
    ).normalized;
    expect(invalidBytes.maxTotalFileBytes, 64 * 1024 * 1024);
    expect(invalidBytes.maxTotalTextChars, 4194304);
    expect(invalidBytes.maxTextChars, 8192);
    expect(invalidBytes.maxTextFileBytes, 2 * 1024 * 1024);
    final invalidChars = const AttachmentProcessingLimits(
            maxTotalFileBytes: 1024 * 1024, maxTotalTextChars: 1023)
        .normalized;
    expect(invalidChars.maxTotalFileBytes, 1024 * 1024);
    expect(invalidChars.maxTotalTextChars, 1000000);
    for (final bytes in [0, -1, 1024 * 1024 - 1]) {
      expect(
          AttachmentProcessingLimits(maxTotalFileBytes: bytes)
              .normalized
              .maxTotalFileBytes,
          64 * 1024 * 1024);
    }
    for (final chars in [0, -1, 4194305]) {
      expect(
          AttachmentProcessingLimits(maxTotalTextChars: chars)
              .normalized
              .maxTotalTextChars,
          1000000);
    }
  });

  test('旧设置与旧备份缺少汇总字段时获得默认值，不影响既有单文件值', () {
    final old = AISettings.defaults().toJson()
      ..remove('attachmentTotalMaxFileBytes')
      ..remove('attachmentTotalMaxChars')
      ..['attachmentTextMaxChars'] = 8192
      ..['attachmentTextMaxFileBytes'] = 3 * 1024 * 1024;
    final restored = AISettings.fromJson(old);
    expect(restored.attachmentTotalMaxFileBytes, 64 * 1024 * 1024);
    expect(restored.attachmentTotalMaxChars, 1000000);
    expect(restored.attachmentTextMaxChars, 8192);
    expect(restored.attachmentTextMaxFileBytes, 3 * 1024 * 1024);
    final legacy = AISettings.fromJson({
      'localProvider': 'deepseek',
      'deepseek': {'model': 'deepseek-chat'},
    });
    expect(
        legacy.attachmentProcessingLimits.maxTotalFileBytes, 64 * 1024 * 1024);
    expect(legacy.attachmentProcessingLimits.maxTotalTextChars, 1000000);
  });

  test('汇总配置通过JSON备份、克隆及切换服务商完整保留', () {
    final settings = AISettings.defaults()
      ..attachmentTotalMaxFileBytes = 128 * 1024 * 1024
      ..attachmentTotalMaxChars = 2000000;
    final backup = (jsonDecode(jsonEncode(settings.toJson())) as Map)
        .cast<String, dynamic>();
    final restored = AISettings.fromJson(backup);
    final switched = restored.clone()
      ..activeProviderId = restored.providers.first.id;
    expect(switched.attachmentTotalMaxFileBytes, 128 * 1024 * 1024);
    expect(switched.attachmentTotalMaxChars, 2000000);
    expect(switched.attachmentProcessingLimits.maxTotalFileBytes,
        128 * 1024 * 1024);
    expect(switched.attachmentProcessingLimits.maxTotalTextChars, 2000000);
    expect(switched.toJson()['attachmentTotalMaxFileBytes'], 128 * 1024 * 1024);
    expect(switched.toJson()['attachmentTotalMaxChars'], 2000000);
  });

  test('JSON汇总字段拒绝错误类型与越界，运行时非法值同样分别兜底', () {
    for (final value in [null, '8388608', 8388608.0, true, 0, 268435457]) {
      final settings = AISettings.fromJson({
        'attachmentTotalMaxFileBytes': value,
        'attachmentTotalMaxChars': 4194304,
      });
      expect(settings.attachmentTotalMaxFileBytes, 64 * 1024 * 1024);
      expect(settings.attachmentTotalMaxChars, 4194304);
    }
    for (final value in [null, '2048', 2048.0, false, 1023, 4194305]) {
      final settings = AISettings.fromJson({
        'attachmentTotalMaxFileBytes': 1024 * 1024,
        'attachmentTotalMaxChars': value,
      });
      expect(settings.attachmentTotalMaxFileBytes, 1024 * 1024);
      expect(settings.attachmentTotalMaxChars, 1000000);
    }
    final mutated = AISettings.defaults()
      ..attachmentTotalMaxFileBytes = -1
      ..attachmentTotalMaxChars = 4194304;
    expect(
        mutated.attachmentProcessingLimits.maxTotalFileBytes, 64 * 1024 * 1024);
    expect(mutated.attachmentProcessingLimits.maxTotalTextChars, 4194304);
    expect(mutated.toJson()['attachmentTotalMaxFileBytes'], 64 * 1024 * 1024);
    expect(mutated.clone().attachmentTotalMaxChars, 4194304);
    mutated.attachmentTotalMaxChars = 0;
    expect(mutated.toJson()['attachmentTotalMaxChars'], 1000000);
    expect(mutated.clone().attachmentTotalMaxChars, 1000000);
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
