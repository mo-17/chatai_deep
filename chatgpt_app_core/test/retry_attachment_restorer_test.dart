import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';

import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/retry_attachment_restorer.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory root;
  const restorer = RetryAttachmentRestorer();
  setUp(() async {
    root = await Directory.systemTemp.createTemp('retry_attachment_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${root.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await root.delete(recursive: true);
  });

  Future<FileMetadata> pdf(String text,
      {String name = 'report.pdf', bool empty = false}) async {
    final document = PdfDocument();
    final page = document.pages.add();
    if (!empty) {
      page.graphics
          .drawString(text, PdfStandardFont(PdfFontFamily.helvetica, 12));
    }
    final bytes = await document.save();
    document.dispose();
    final source = await File('${root.path}/$name').writeAsBytes(bytes);
    final managed = await ManagedAttachmentStore.importFile(source);
    return FileMetadata(
        name: name, path: managed, mime: 'application/pdf', size: bytes.length);
  }

  test('沿用已持久化图片和文件正文，不重读旧文件路径', () async {
    const persisted = ChatAttachments(
        images: ['data:image/png;base64,old'], extraText: '已保存的正文');
    final result = await restorer.restore(
        persisted: persisted,
        files: const [
          FileMetadata(
              name: 'old.pdf',
              path: '/missing/file.pdf',
              mime: 'application/pdf',
              extractedText: '旧正文')
        ],
        capabilities: const ModelCapabilities(image: true));
    expect(result.attachments.images, persisted.images);
    expect(result.attachments.extraText, persisted.extraText);
    expect(result.attachments.nativeFiles, isEmpty);
    expect(result.hasWarnings, isFalse);
    final fallback = await restorer.restore(
        persisted: const ChatAttachments(),
        files: const [FileMetadata(name: 'old.txt', extractedText: '旧文件正文')],
        capabilities: const ModelCapabilities.none());
    expect(fallback.attachments.extraText, '旧文件正文');
  });

  test('降低单文件和整轮配置不会重截断旧提问保存的正文或读取旧路径', () async {
    const limits = AttachmentProcessingLimits(
        maxTextChars: 1024,
        maxTextFileBytes: 1024 * 1024,
        maxTotalTextChars: 1024,
        maxTotalFileBytes: 1024 * 1024);
    final original = 'SAVED_START${'n' * 5000}SAVED_END';
    final extracted = 'FILE_START${'f' * 6000}FILE_END';
    final files = [
      FileMetadata(
          name: 'old.txt',
          path: '/missing/old.txt',
          size: 2 * 1024 * 1024,
          extractedText: extracted),
    ];
    final persisted = await restorer.restore(
        persisted: ChatAttachments(extraText: original),
        files: files,
        capabilities: const ModelCapabilities.none(),
        limits: limits);
    expect(persisted.attachments.extraText, original);
    expect(persisted.hasWarnings, isFalse);
    final fallback = await restorer.restore(
        persisted: const ChatAttachments(),
        files: files,
        capabilities: const ModelCapabilities.none(),
        limits: limits);
    expect(fallback.attachments.extraText, extracted);
    expect(fallback.hasWarnings, isFalse);
    expect(await Directory('${root.path}/managed').exists(), isFalse);
  });

  test('原生PDF重试降级提取时使用当前配置的字符上限', () async {
    final text = List.generate(40, (i) => 'line$i ${'n' * 50}').join('\n');
    final file = await pdf(text);
    final result = await restorer.restore(
        persisted: const ChatAttachments(),
        files: [file],
        capabilities: const ModelCapabilities.none(),
        limits: const AttachmentProcessingLimits(maxTextChars: 1024));
    expect(result.attachments.extraText, contains('已截断'));
    expect(result.attachments.extraText, isNot(contains('line39')));
    expect(result.diagnostics.map((d) => d.kind), [
      FileProcessingDiagnosticKind.textFallback,
      FileProcessingDiagnosticKind.truncated,
    ]);
    expect(result.diagnostics.last.message, 'PDF 文字超过 1024 字符，仅发送前 1024 字符');
  });

  test('从安全托管文件恢复原生PDF字节与原始文件名', () async {
    final file = await pdf('original content');
    final progress = <ChatSendProgress>[];
    final result = await restorer.restore(
        persisted: const ChatAttachments(extraText: 'other file'),
        files: [file],
        capabilities: const ModelCapabilities(pdf: true),
        onProgress: progress.add);
    final native = result.attachments.nativeFiles.single;
    expect(native.filename, 'report.pdf');
    expect(base64Decode(native.dataUri.split(',').last),
        await ManagedAttachmentStore.readManagedBytes(file.path));
    expect(result.attachments.extraText, 'other file');
    expect(result.diagnostics, isEmpty);
    expect(progress.single.fileName, 'report.pdf');
    expect(progress.single.index, 1);
    expect(progress.single.total, 1);
  });

  test('当前模型不支持PDF时抽取正文并要求确认降级策略', () async {
    final file = await pdf('degraded content');
    final result = await restorer.restore(
        persisted: const ChatAttachments(extraText: 'cached text'),
        files: [file],
        capabilities: const ModelCapabilities.none());
    expect(result.attachments.nativeFiles, isEmpty);
    expect(result.attachments.extraText, contains('cached text'));
    expect(result.attachments.extraText, contains('degraded content'));
    expect(result.diagnostics.single.kind,
        FileProcessingDiagnosticKind.textFallback);
    expect(result.diagnostics.single.filename, 'report.pdf');
  });

  test('当前模型原生PDF大小限制与扫描件诊断仍生效', () async {
    final file = await pdf('over limit');
    final result = await restorer.restore(
        persisted: const ChatAttachments(),
        files: [file],
        capabilities:
            const ModelCapabilities(pdf: true, fileSizeLimits: {'pdf': 1}));
    expect(result.attachments.extraText, contains('over limit'));
    expect(result.diagnostics.single.message, contains('原生文件上限'));
    final scan = await pdf('', name: 'scan.pdf', empty: true);
    final scanned = await restorer.restore(
        persisted: const ChatAttachments(),
        files: [scan],
        capabilities: const ModelCapabilities.none());
    expect(scanned.diagnostics.map((d) => d.kind),
        contains(FileProcessingDiagnosticKind.scannedPdf));
    expect(scanned.hasWarnings, isTrue);
  });

  test('失效和托管目录之外的PDF必须提示重新选择', () async {
    final file = await pdf('content');
    for (final path in [
      '${root.path}/missing.pdf',
      '${root.path}/report.pdf'
    ]) {
      await expectLater(
          restorer.restore(
              persisted: const ChatAttachments(),
              files: [
                FileMetadata(
                    name: 'old.pdf', path: path, mime: 'application/pdf')
              ],
              capabilities: const ModelCapabilities(pdf: true)),
          throwsA(isA<RetryAttachmentException>()
              .having((e) => e.message, 'message', contains('重新选择'))));
    }
    await File(file.path!).delete();
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(),
            files: [file],
            capabilities: const ModelCapabilities(pdf: true)),
        throwsA(isA<RetryAttachmentException>()));
  });

  test('托管文件发生同长度改写或链接替换时拒绝重试', () async {
    final file = await pdf('checksum content');
    final changed = await File(file.path!).readAsBytes();
    changed[changed.length - 1] ^= 1;
    await File(file.path!).writeAsBytes(changed);
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(),
            files: [file],
            capabilities: const ModelCapabilities(pdf: true)),
        throwsA(isA<RetryAttachmentException>()
            .having((e) => e.message, 'message', contains('校验失败'))));
    if (!Platform.isWindows) {
      await File(file.path!).delete();
      await Link(file.path!).create('${root.path}/report.pdf');
      await expectLater(
          restorer.restore(
              persisted: const ChatAttachments(),
              files: [file],
              capabilities: const ModelCapabilities(pdf: true)),
          throwsA(isA<RetryAttachmentException>()));
    }
  });

  test('原提问有图片时禁止用不支持图片的模型悄悄丢图重试', () async {
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(images: ['old image']),
            files: const [],
            capabilities: const ModelCapabilities.none()),
        throwsA(isA<RetryAttachmentException>()
            .having((e) => e.message, 'message', contains('不支持图片'))));
  });

  test('重试准备可以取消，不继续读取附件或解析PDF', () async {
    final abort = Completer<void>()..complete();
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(),
            files: const [
              FileMetadata(name: 'missing.pdf', mime: 'application/pdf')
            ],
            capabilities: const ModelCapabilities(pdf: true),
            abortTrigger: abort.future),
        throwsA(isA<AttachmentProcessingCancelledException>()));
    final file = await pdf('cancel');
    final processingAbort = Completer<void>();
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(),
            files: [file],
            capabilities: const ModelCapabilities(pdf: true),
            abortTrigger: processingAbort.future,
            onProgress: (_) => processingAbort.complete()),
        throwsA(isA<AttachmentProcessingCancelledException>()));
  });

  test('不同PDF同名时恢复两个原文件，不能按文件名省略内容', () async {
    final first = await pdf('first');
    final second = await pdf('second');
    final result = await restorer.restore(
        persisted: const ChatAttachments(),
        files: [first, second],
        capabilities: const ModelCapabilities(pdf: true));
    expect(result.attachments.nativeFiles, hasLength(2));
    expect(result.attachments.nativeFiles[0].filename,
        result.attachments.nativeFiles[1].filename);
    expect(result.attachments.nativeFiles[0].dataUri,
        isNot(result.attachments.nativeFiles[1].dataUri));
  });
  Future<FileMetadata> generationPdf(String account,
      {bool corrupt = false}) async {
    final document = PdfDocument();
    document.pages.add().graphics.drawString(
        'generation original', PdfStandardFont(PdfFontFamily.helvetica, 12));
    final bytes = await document.save();
    document.dispose();
    final dir =
        Directory('${ManagedAttachmentStore.rootDirectory.path}/accounts/'
            '${AccountResourceScope.tokenFor(account)}/generations/'
            '12345678-1234-4234-8234-123456789abc/${sha256.convert(bytes)}');
    await dir.create(recursive: true);
    final file = await File('${dir.path}/original.pdf')
        .writeAsBytes(corrupt ? [...bytes, 0] : bytes);
    return FileMetadata(
        name: 'original.pdf',
        path: file.path,
        mime: 'application/pdf',
        size: corrupt ? null : bytes.length);
  }

  test(
      'captured account generation PDF uses parent digest and original filename',
      () async {
    final file = await generationPdf('a');
    int guards = 0;
    final result = await restorer.restore(
        persisted: const ChatAttachments(),
        files: [file],
        capabilities: const ModelCapabilities(pdf: true),
        accountHash: 'a',
        beforeRead: () async {
          guards++;
        });
    expect(result.attachments.nativeFiles.single.filename, 'original.pdf');
    expect(guards, 2);
    expect(
        base64Decode(
            result.attachments.nativeFiles.single.dataUri.split(',').last),
        await File(file.path!).readAsBytes());
  });
  for (final which in [
    'other-account',
    'digest',
    'symlink',
    'unsafe-segment'
  ]) {
    test('bound retry rejects $which generation bytes', () async {
      var file = await generationPdf(which == 'other-account' ? 'b' : 'a',
          corrupt: which == 'digest');
      if (which == 'symlink') {
        final original = File(file.path!);
        final target = File('${root.path}/external.pdf');
        await original.copy(target.path);
        await original.delete();
        await Link(original.path).create(target.path);
      }
      if (which == 'unsafe-segment') {
        file = FileMetadata(
            name: file.name,
            mime: file.mime,
            path:
                '${File(file.path!).parent.path}/../${File(file.path!).parent.uri.pathSegments.where((s) => s.isNotEmpty).last}/original.pdf');
      }
      await expectLater(
          restorer.restore(
              persisted: const ChatAttachments(),
              files: [file],
              capabilities: const ModelCapabilities(pdf: true),
              accountHash: 'a',
              beforeRead: () async {}),
          throwsA(isA<RetryAttachmentException>()));
    });
  }
  test('bound legacy digest path remains usable only with original run guard',
      () async {
    final file = await pdf('legacy');
    int guards = 0;
    final restored = await restorer.restore(
        persisted: const ChatAttachments(),
        files: [file],
        capabilities: const ModelCapabilities(pdf: true),
        accountHash: 'a',
        beforeRead: () async {
          guards++;
        });
    expect(restored.attachments.nativeFiles, hasLength(1));
    expect(guards, 2);
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(),
            files: [file],
            capabilities: const ModelCapabilities(pdf: true),
            accountHash: 'a'),
        throwsArgumentError);
  });
  test(
      'source revoked before or after PDF reading cannot return prepared bytes',
      () async {
    final file = await generationPdf('a');
    int guards = 0;
    await expectLater(
        restorer.restore(
            persisted: const ChatAttachments(),
            files: [file],
            capabilities: const ModelCapabilities(pdf: true),
            accountHash: 'a',
            beforeRead: () async {
              if (++guards == 2) throw StateError('source revoked');
            }),
        throwsStateError);
    expect(guards, 2);
  });
}
