import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/platform/app_io.dart';
import 'package:chatgpt_app_core/dao/ai_catalog_dao.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'import_operation.dart';
import 'knowledge_import_error.dart';
import 'pdf_ocr_result.dart';
import 'attachment_ocr.dart' show AttachmentOcrRequest;

/// 仅由明确选择「服务器 OCR」的导入会话创建；不保存令牌、原件或识别结果。
class ServerOcrClient {
  static const maxBytes = AttachmentOcrRequest.maxBytes;
  final Uri base;
  final Map<String, String> headers;
  final bool Function() isCurrent;
  final http.Client Function() clientFactory;
  final Duration pollInterval;
  ServerOcrClient(
      {required this.base,
      required Map<String, String> headers,
      required this.isCurrent,
      http.Client Function()? clientFactory,
      this.pollInterval = const Duration(seconds: 2)})
      : headers = Map.unmodifiable(headers),
        clientFactory = clientFactory ?? http.Client.new;

  factory ServerOcrClient.capture({bool Function()? additionalCurrent}) {
    final identity = AiCatalogIdentity.capture();
    if (!identity.authenticated) {
      throw const KnowledgeImportFailure(
          KnowledgeImportErrorKind.permission, '登录后可使用服务器 OCR');
    }
    return ServerOcrClient(
        base: BackendConfig.buildUri('/uapi/ocr/'),
        headers: {'Authorization': 'Bearer ${LoginDao.getBoardingPass()}'},
        isCurrent: () =>
            identity.current && (additionalCurrent?.call() ?? true));
  }

  Future<void> checkAvailable() async {
    final client = clientFactory();
    try {
      final value = await _request(client, 'GET', 'capabilities');
      if (value['available'] != true) throw _unavailable;
    } finally {
      client.close();
    }
  }

  static const _unavailable = KnowledgeImportFailure(
      KnowledgeImportErrorKind.recognition, '服务器 OCR 暂不可用，请稍后重试或使用本地识别');

  Future<Map<String, dynamic>> _request(
      http.Client client, String method, String path,
      {Uint8List? body, Future<void>? abort, bool cleanup = false}) async {
    if (!cleanup && !isCurrent()) throw const ImportCancelled();
    final timeout = Completer<void>();
    // 大文件上传允许弱网传输；查询和清理无需长期占用连接。
    final timer = Timer(
        Duration(
            seconds: cleanup
                ? 5
                : body == null
                    ? 15
                    : 60),
        () => timeout.complete());
    try {
      final request = http.AbortableRequest(method, base.resolve(path),
          abortTrigger: Future.any([timeout.future, if (abort != null) abort]))
        ..followRedirects = false
        ..headers.addAll(headers);
      if (body != null) {
        request.headers['Content-Type'] = 'application/octet-stream';
        request.bodyBytes = body;
      }
      final response = await client.send(request);
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.stream) {
        if (bytes.length + part.length > 2 * 1024 * 1024) throw _unavailable;
        bytes.add(part);
      }
      if (!cleanup && !isCurrent()) throw const ImportCancelled();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const KnowledgeImportFailure(
            KnowledgeImportErrorKind.permission, '登录已过期，请重新登录后识别');
      }
      if (response.statusCode == 429) {
        throw const KnowledgeImportFailure(
            KnowledgeImportErrorKind.busy, '服务器 OCR 繁忙或已达使用限额，请稍后重试');
      }
      if (response.statusCode == 404) {
        throw const KnowledgeImportFailure(
            KnowledgeImportErrorKind.recognition, 'OCR 任务已过期，请重新识别');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _unavailable;
      }
      final result = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (result is! Map || result['code'] != 0 || result['data'] is! Map) {
        throw _unavailable;
      }
      return (result['data'] as Map).cast<String, dynamic>();
    } on KnowledgeImportFailure {
      rethrow;
    } on ImportCancelled {
      rethrow;
    } catch (_) {
      if (!cleanup && !isCurrent()) throw const ImportCancelled();
      if (timeout.isCompleted) {
        throw const KnowledgeImportFailure(
            KnowledgeImportErrorKind.timeout, '服务器 OCR 请求超时，请稍后重试');
      }
      throw _unavailable;
    } finally {
      timer.cancel();
    }
  }

  Future<PdfOcrResult> recognize(String path,
      {required bool pdf,
      List<int> pageNumbers = const [],
      bool includePreview = false,
      ImportCancellation? cancellation,
      void Function(String stage, int? page, int? pages)? onProgress}) async {
    final operation = cancellation ?? ImportCancellation();
    void check() {
      if (!isCurrent()) operation.cancel();
      operation.check();
    }

    check();
    final bytes = await readFileBytesBounded(appFile(path), maxBytes: maxBytes);
    check();
    return recognizeBytes(bytes,
        pdf: pdf,
        pageNumbers: pageNumbers,
        includePreview: includePreview,
        cancellation: operation,
        onProgress: onProgress);
  }

  Future<PdfOcrResult> recognizeBytes(Uint8List source,
      {required bool pdf,
      List<int> pageNumbers = const [],
      bool includePreview = false,
      ImportCancellation? cancellation,
      void Function(String stage, int? page, int? pages)? onProgress}) async {
    final operation = cancellation ?? ImportCancellation();
    void check() {
      if (!isCurrent()) operation.cancel();
      operation.check();
    }

    check();
    if (source.isEmpty || source.length > maxBytes) {
      throw const KnowledgeImportFailure(
          KnowledgeImportErrorKind.tooLarge, '服务器 OCR 文件不能为空，单文件最多 8 MiB');
    }
    final bytes = Uint8List.fromList(source).asUnmodifiableView();
    final random = Random.secure();
    final id = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final client = clientFactory();
    final abort = Completer<void>();
    final removeListener = operation.listen(() {
      if (!abort.isCompleted) abort.complete();
    });
    final watch = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!isCurrent()) operation.cancel();
    });
    var attempted = false;
    try {
      check();
      onProgress?.call('正在上传至服务器', null, null);
      final query = Uri(queryParameters: {
        'kind': pdf ? 'pdf' : 'image',
        if (includePreview) 'preview': 'true',
        if (pageNumbers.isNotEmpty) 'pages': pageNumbers.join(',')
      }).query;
      attempted = true;
      var job = await _request(client, 'POST', 'jobs/$id?$query',
          body: bytes, abort: abort.future);
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (true) {
        check();
        if (job['id'] != id) throw _unavailable;
        final state = job['state'];
        if (state == 'completed') {
          try {
            final raw = job['result'];
            final result = PdfOcrResult.fromJson(raw,
                expectedPages:
                    pageNumbers.isEmpty ? null : pageNumbers.toSet());
            if (!pdf && result.totalPages != 1) throw _unavailable;
            check();
            return result;
          } on FormatException {
            throw _unavailable;
          }
        }
        if (state == 'cancelled') throw const ImportCancelled();
        if (state == 'failed') {
          final code = job['error'];
          if (code == 'timeout') {
            throw const KnowledgeImportFailure(
                KnowledgeImportErrorKind.timeout, '服务器识别超时，请拆分文件后重试');
          }
          if (['pages_limit', 'pixels_limit', 'result_limit'].contains(code)) {
            throw const KnowledgeImportFailure(
                KnowledgeImportErrorKind.tooLarge,
                '文件页数、分辨率或文字超过服务器 OCR 限额，请拆分或缩小后重试');
          }
          throw const KnowledgeImportFailure(
              KnowledgeImportErrorKind.recognition,
              '服务器无法识别文件，请使用 PNG / JPEG / WebP / BMP 或未加密 PDF');
        }
        if (state != 'queued' && state != 'running') throw _unavailable;
        onProgress?.call(
            state == 'queued' ? '服务器排队中' : '服务器正在识别',
            job['completedPages'] as int?,
            pageNumbers.isEmpty
                ? job['totalPages'] as int?
                : pageNumbers.length);
        if (DateTime.now().isAfter(deadline)) {
          throw const KnowledgeImportFailure(
              KnowledgeImportErrorKind.timeout, '服务器 OCR 等待超时，请稍后重试');
        }
        await Future.any([Future<void>.delayed(pollInterval), abort.future]);
        check();
        job = await _request(client, 'GET', 'jobs/$id', abort: abort.future);
      }
    } catch (_) {
      check();
      rethrow;
    } finally {
      watch.cancel();
      removeListener();
      // 用原账号、原地址删除。取消早于上传到达时，worker 也会留下取消标记。
      if (attempted) {
        try {
          await _request(client, 'DELETE', 'jobs/$id', cleanup: true);
        } catch (_) {}
      }
      client.close();
    }
  }
}
