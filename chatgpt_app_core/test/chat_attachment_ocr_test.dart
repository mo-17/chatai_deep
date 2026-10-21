import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:chatgpt_app_core/chat/application/attachment_ocr.dart';
import 'package:chatgpt_app_core/chat/application/attachment_batch_budget.dart';
import 'package:chatgpt_app_core/chat/application/conversation_attachment_ocr.dart';
import 'package:chatgpt_app_core/chat/application/file_processor.dart';
import 'package:chatgpt_app_core/chat/application/knowledge_import_error.dart';
import 'package:chatgpt_app_core/chat/application/pdf_ocr_result.dart';
import 'package:chatgpt_app_core/chat/application/server_ocr_client.dart';
import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chat_ocr_');
    ManagedAttachmentStore.debugRootDirectory =
        Directory('${directory.path}/managed');
  });
  tearDown(() async {
    ManagedAttachmentStore.debugRootDirectory = null;
    await directory.delete(recursive: true);
  });
  Future<File> pdfFile(List<String> pages) async {
    final pdf = PdfDocument();
    try {
      for (final text in pages) {
        pdf.pages
            .add()
            .graphics
            .drawString(text, PdfStandardFont(PdfFontFamily.helvetica, 12));
      }
      return File('${directory.path}/scan.pdf').writeAsBytes(await pdf.save());
    } finally {
      pdf.dispose();
    }
  }

  Future<File> image() =>
      File('${directory.path}/scan.png').writeAsBytes([1, 2, 3]);

  test('混合 PDF 只请求缺字页，正文保留页号并与持久化元数据一致', () async {
    final file = await pdfFile([
      'FIRST PAGE original text preserved',
      '',
      'THIRD PAGE original text preserved'
    ]);
    final original = await file.readAsBytes();
    final processed = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(), ocr: (request) async {
      expect(request.pdf, true);
      expect(request.filename, 'scan.pdf');
      expect(request.totalPages, 3);
      expect(request.pageNumbers, [2]);
      expect(request.bytes, original);
      return PdfOcrResult(
          totalPages: 3,
          pages: ['forged first', 'SCAN SECOND', 'forged third']);
    });
    expect(processed.hasWarnings, false);
    expect(processed.extraText, contains('【第 2 页】\nSCAN SECOND'));
    expect(processed.extraText, contains('FIRST PAGE original'));
    expect(processed.extraText, contains('THIRD PAGE original'));
    expect(processed.extraText, isNot(contains('forged')));
    expect(processed.metas.single.extractedText, processed.extraText);
  });

  test('正常文本 PDF 与模型原生 PDF 均不触发 OCR', () async {
    final file = await pdfFile(['NATIVE TEXT CONTENT long enough']);
    var calls = 0;
    Future<PdfOcrResult> ocr(AttachmentOcrRequest _) async {
      calls++;
      throw StateError('unexpected');
    }

    final local = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        ocr: ocr);
    final native = await FileProcessor.process(
        [file.path], const ModelCapabilities(pdf: true),
        ocr: ocr);
    expect(calls, 0);
    expect(local.extraText, contains('NATIVE TEXT CONTENT'));
    expect(native.nativeFiles.single.filename, 'scan.pdf');
    expect(native.extraText, isEmpty);
  });

  test('图片作为文字附件发送，超过文字限额时保留明确截断诊断', () async {
    final file = await image();
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        limits: const AttachmentProcessingLimits(maxTextChars: 1024),
        ocr: (request) async {
      expect(request.pdf, false);
      return PdfOcrResult(totalPages: 1, pages: ['X' * 2000]);
    });
    expect(result.nativeFiles, isEmpty);
    expect(result.metas.single.mime, 'image/png');
    expect(result.metas.single.extractedText, result.extraText);
    expect(result.extraText, contains('已截断'));
    expect(
        result.diagnostics.single.kind, FileProcessingDiagnosticKind.truncated);
  });

  test('OCR 结果仍受整轮文字预算限制', () async {
    final file = await image();
    await expectLater(
        FileProcessor.process([file.path], const ModelCapabilities.none(),
            limits: const AttachmentProcessingLimits(maxTotalTextChars: 1024),
            ocr: (_) async => PdfOcrResult(totalPages: 1, pages: ['X' * 2000])),
        throwsA(isA<AttachmentBatchLimitException>()));
  });

  test('取消与错误 OCR 页数均不能产生待发送正文', () async {
    final file = await pdfFile(['', '']);
    await expectLater(
        FileProcessor.process([file.path], const ModelCapabilities.none(),
            ocr: (_) async => PdfOcrResult(totalPages: 1, pages: ['wrong'])),
        throwsA(isA<AttachmentOcrException>()));
    final abort = Completer<void>();
    await expectLater(
        FileProcessor.process([file.path], const ModelCapabilities.none(),
            abortTrigger: abort.future, ocr: (_) async {
          abort.complete();
          return PdfOcrResult(totalPages: 2, pages: ['late', 'late']);
        }),
        throwsA(isA<AttachmentProcessingCancelledException>()));
  });

  test('空白识别不覆盖原有短文字，空白页需明确诊断', () async {
    final file = await pdfFile(['short', '']);
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        ocr: (_) async => PdfOcrResult(totalPages: 2, pages: ['', '']));
    expect(result.extraText, contains('short'));
    expect(result.diagnostics.single.message, contains('保留原有文字'));
  });

  test('超过 20 页的 PDF 不上传，保持原有截断预检', () async {
    final file =
        await pdfFile(List.filled(21, 'long enough local text on every page'));
    final result = await FileProcessor.process(
        [file.path], const ModelCapabilities.none(),
        ocr: (_) async => throw StateError('must not upload'));
    expect(
        result.diagnostics.single.kind, FileProcessingDiagnosticKind.truncated);
  });

  test('OCR 请求冻结实际字节，不受原缓冲区变化影响', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final request =
        AttachmentOcrRequest(filename: 'image.png', bytes: bytes, pdf: false);
    bytes[0] = 9;
    expect(request.bytes, [1, 2, 3]);
    expect(() => request.bytes[0] = 8, throwsUnsupportedError);
    expect(
        () => AttachmentOcrRequest(
            filename: 'large.pdf',
            bytes: Uint8List(AttachmentOcrRequest.maxBytes + 1),
            pdf: true),
        throwsA(isA<AttachmentOcrException>()));
  });

  group('真实客户端与聊天确认桥接', () {
    late Completer<void> abort;
    late bool current;
    late List<http.Request> calls;
    setUp(() {
      abort = Completer();
      current = true;
      calls = [];
    });
    AttachmentOcrRequest request() => AttachmentOcrRequest(
        filename: 'private.png',
        bytes: Uint8List.fromList([1, 2, 3]),
        pdf: false);
    ServerOcrClient client({bool queued = false}) => ServerOcrClient(
        base: Uri.parse('https://captured.example/uapi/ocr/'),
        headers: {'Authorization': 'Bearer original'},
        isCurrent: () => current,
        pollInterval: Duration.zero,
        clientFactory: () => MockClient((req) async {
              calls.add(req);
              final id = req.url.pathSegments.last;
              return http.Response(
                  jsonEncode({
                    'code': 0,
                    'data': {
                      'id': id,
                      'state': req.method == 'DELETE'
                          ? 'cancelled'
                          : queued
                              ? 'queued'
                              : 'completed',
                      if (!queued && req.method != 'DELETE')
                        'result': {
                          'totalPages': 1,
                          'pages': [
                            {'page': 1, 'text': 'RECOGNIZED'}
                          ]
                        },
                    }
                  }),
                  200);
            }));
    ConversationAttachmentOcr session(
            Future<bool> Function(String, String) confirm,
            {ServerOcrClient Function()? createClient,
            void Function()? progress}) =>
        ConversationAttachmentOcr(
            verify: () async {},
            isCurrent: () => current,
            abortTrigger: abort.future,
            confirm: confirm,
            createClient: createClient ?? () => client(),
            onProgress: (_) => progress?.call());

    test('明确同意前不上传，同意后上传快照并删除服务器结果', () async {
      final gate = Completer<bool>();
      String? detail;
      final future = session((title, message) {
        detail = message;
        return gate.future;
      }).recognize(request());
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(detail, contains('captured.example'));
      expect(detail, contains('当前模型服务'));
      gate.complete(true);
      expect((await future).text, 'RECOGNIZED');
      expect(calls.map((c) => c.method), ['POST', 'DELETE']);
      expect(calls.first.bodyBytes, [1, 2, 3]);
    });

    test('拒绝确认不上传，返回可展示的保留草稿提示', () async {
      await expectLater(
          session((_, __) async => false).recognize(request()),
          throwsA(isA<AttachmentOcrException>()
              .having((e) => e.message, 'message', contains('原输入已保留'))));
      expect(calls, isEmpty);
    });

    test('确认等待期间账号或配置变化，不向旧服务器上传', () async {
      final gate = Completer<bool>();
      final future = session((_, __) => gate.future).recognize(request());
      await Future<void>.delayed(Duration.zero);
      current = false;
      gate.complete(true);
      await expectLater(
          future, throwsA(isA<AttachmentProcessingCancelledException>()));
      expect(calls, isEmpty);
    });

    test('排队期间停止，取消服务器任务且不返回迟到文字', () async {
      final ocr = session((_, __) async => true,
          createClient: () => client(queued: true),
          progress: () {
            if (calls.isNotEmpty && !abort.isCompleted) abort.complete();
          });
      await expectLater(ocr.recognize(request()),
          throwsA(isA<AttachmentProcessingCancelledException>()));
      expect(calls.first.method, 'POST');
      expect(calls.last.method, 'DELETE');
    });

    test('游客不会出现可确认的上传操作或暴露底层错误', () async {
      var prompts = 0;
      await expectLater(
          session((_, __) async {
            prompts++;
            return true;
          },
                  createClient: () => throw const KnowledgeImportFailure(
                      KnowledgeImportErrorKind.permission, 'private detail'))
              .recognize(request()),
          throwsA(isA<AttachmentOcrException>().having((e) => e.message, 'safe',
              allOf(contains('登录'), isNot(contains('private'))))));
      expect(prompts, 0);
      expect(calls, isEmpty);
    });
  });
}
