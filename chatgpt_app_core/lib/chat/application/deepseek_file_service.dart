import 'dart:async';
import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:http/http.dart' as http;

/// DeepSeek Files API 当前仅支持图片；PDF / 文本仍由 FileProcessor 抽正文。
/// 调用方应只在本地直连模式使用，避免混用代理与直连账号的 file_id。
class DeepSeekFileService {
  static const maxImageBytes = 64 * 1024 * 1024;
  static const _maxResponseBytes = 256 * 1024;

  final Uri _endpoint;
  final String _apiKey;
  final http.Client? _client;
  final Duration timeout;
  final Future<void> Function(DeepSeekUploadedFile file, Uint8List bytes)?
      _onUploaded;

  DeepSeekFileService({
    required String chatCompletionsUrl,
    required String apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
    Future<void> Function(DeepSeekUploadedFile file, Uint8List bytes)?
        onUploaded,
  })  : _endpoint = filesEndpointFor(chatCompletionsUrl),
        _apiKey = apiKey.trim(),
        _client = client,
        _onUploaded = onUploaded;

  /// 与对话使用相同服务商；兼容自定义反向代理的版本段 / 路径前缀。
  static Uri filesEndpointFor(String chatCompletionsUrl) {
    final uri = Uri.tryParse(chatCompletionsUrl);
    const suffix = '/chat/completions';
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.endsWith(suffix)) {
      throw const FormatException('DeepSeek 服务地址无法派生文件上传接口');
    }
    var prefix = uri.path.substring(0, uri.path.length - suffix.length);
    // 官方 Files API 不需要 Chat Completions 的兼容版本前缀。
    if (uri.host.toLowerCase() == 'api.deepseek.com' &&
        (prefix == '/v1' || prefix == '/beta')) {
      prefix = '';
    }
    return uri.replace(path: '$prefix/files');
  }

  Future<DeepSeekUploadedFile> uploadImage(
    String path, {
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
  }) async {
    await _checkAbort(abortTrigger);
    _validateKey();
    final bytes = await readFileBytesBounded(
      appFile(path),
      maxBytes: maxImageBytes,
      label: 'DeepSeek 图片附件',
    );
    return uploadImageBytes(
      bytes,
      filename: path.split(RegExp(r'[/\\]')).last,
      abortTrigger: abortTrigger,
      onProgress: onProgress,
    );
  }

  /// 支持已有图片附件的 data URI，按实际字节判断格式，不信任扩展名 / MIME。
  Future<DeepSeekUploadedFile> uploadImageDataUri(
    String dataUri, {
    String? filename,
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
  }) async {
    await _checkAbort(abortTrigger);
    _validateKey();
    return uploadImageBytes(
      imageBytesForDataUri(dataUri),
      filename: filename,
      abortTrigger: abortTrigger,
      onProgress: onProgress,
    );
  }

  static Uint8List imageBytesForDataUri(String dataUri) {
    final comma = dataUri.indexOf(',');
    if (comma < 0 ||
        !RegExp(r'^data:image/[^;,]+;base64$', caseSensitive: false)
            .hasMatch(dataUri.substring(0, comma))) {
      throw const FormatException('DeepSeek 图片附件必须是 base64 data URI');
    }
    final encodedLength = dataUri.length - comma - 1;
    if (encodedLength > ((maxImageBytes + 2) ~/ 3) * 4) {
      throw const FormatException('DeepSeek 图片附件过大（最多 64 MiB）');
    }
    late final Uint8List bytes;
    try {
      bytes = base64Decode(dataUri.substring(comma + 1));
    } on FormatException {
      throw const FormatException('DeepSeek 图片附件的 base64 内容无效');
    }
    return bytes;
  }

  void _validateKey() {
    if (_apiKey.isEmpty) {
      throw const DeepSeekFileException('请先配置 DeepSeek API Key，再发送图片');
    }
  }

  Future<DeepSeekUploadedFile> uploadImageBytes(
    Uint8List bytes, {
    String? filename,
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
  }) async {
    await _checkAbort(abortTrigger);
    _validateKey();
    if (bytes.length > maxImageBytes) {
      throw const FormatException('DeepSeek 图片附件过大（最多 64 MiB）');
    }
    final mime = imageMimeForBytes(bytes);
    if (mime == null) {
      throw const FormatException(
          'DeepSeek Files API 仅支持 JPEG、PNG、GIF、WebP 图片');
    }
    final uploadName = _filename(filename, mime);
    final abort = Completer<void>();
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) {
        if (!abort.isCompleted) abort.complete();
      }));
    }
    final request = http.AbortableMultipartRequest(
      'POST',
      _endpoint,
      abortTrigger: abort.future,
    )
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer $_apiKey'
      ..fields['purpose'] = 'user_data'
      ..files.add(http.MultipartFile(
        'file',
        _uploadStream(bytes, uploadName, onProgress),
        bytes.length,
        filename: uploadName,
      ));
    final client = _client ?? http.Client();
    reportChatSendProgress(
        onProgress,
        ChatSendProgress('上传图片',
            fileName: uploadName, completedBytes: 0, totalBytes: bytes.length));
    try {
      final uploaded = await (() async {
        final response = await client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream
              .listen((_) {}, onError: (Object _, StackTrace __) {})
              .cancel();
          // 不展示响应正文：上游 / 代理可能在正文回显 Authorization 或文件内容。
          throw DeepSeekFileException(_statusMessage(response.statusCode));
        }
        final builder = BytesBuilder(copy: false);
        var total = 0;
        await for (final chunk in response.stream) {
          total += chunk.length;
          if (total > _maxResponseBytes) {
            throw const DeepSeekFileException('DeepSeek 文件上传响应过大，请重试');
          }
          builder.add(chunk);
        }
        final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
        final id = decoded is Map ? decoded['id'] : null;
        if (decoded is! Map ||
            decoded['object'] != 'file' ||
            id is! String ||
            !RegExp(r'^file-api-[A-Za-z0-9_-]+$').hasMatch(id)) {
          throw const DeepSeekFileException('DeepSeek 未返回有效的文件 ID，请重试');
        }
        return DeepSeekUploadedFile(
          id: id,
          filename: uploadName,
          mime: mime,
          bytes: bytes.length,
        );
      })()
          .timeout(timeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException('DeepSeek file upload timed out');
      });
      // 只有有效的上传响应才能建立预览映射；缓存失败不影响成功的文件上传。
      try {
        await _onUploaded?.call(uploaded, bytes);
      } catch (_) {}
      return uploaded;
    } on http.RequestAbortedException {
      rethrow;
    } on DeepSeekFileException {
      rethrow;
    } on TimeoutException {
      throw const DeepSeekFileException('DeepSeek 图片上传超时，请检查网络后重试');
    } on FormatException {
      throw const DeepSeekFileException('DeepSeek 文件上传响应格式无效，请重试');
    } catch (_) {
      throw const DeepSeekFileException('DeepSeek 图片上传失败，请检查网络后重试');
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (_client == null) client.close();
    }
  }

  static Stream<List<int>> _uploadStream(
    Uint8List bytes,
    String filename,
    ChatSendProgressCallback? onProgress,
  ) async* {
    const chunkSize = 64 * 1024;
    var reported = 0;
    final timer = Stopwatch()..start();
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end =
          offset + chunkSize < bytes.length ? offset + chunkSize : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
      // 这里只能证明请求流被 HTTP 客户端消费，不能证明服务端已收到或存储。
      if (end == bytes.length ||
          end - reported >= 256 * 1024 ||
          timer.elapsedMilliseconds >= 100) {
        reportChatSendProgress(
            onProgress,
            ChatSendProgress('上传图片',
                fileName: filename,
                completedBytes: end,
                totalBytes: bytes.length));
        reported = end;
        timer.reset();
      }
    }
    reportChatSendProgress(
        onProgress, ChatSendProgress('等待图片上传确认', fileName: filename));
  }

  Future<void> _checkAbort(Future<void>? abortTrigger) async {
    if (abortTrigger == null) return;
    var aborted = false;
    unawaited(abortTrigger.then((_) => aborted = true));
    // 已完成的取消信号先于下一 microtask 执行，避免取消后还分配 / 发送图片。
    await Future<void>.value();
    if (aborted) throw http.RequestAbortedException(_endpoint);
  }

  /// DeepSeek 由文件内容识别格式；本地预检阻止把 PDF 等发进图片接口。
  static String? imageMimeForBytes(List<int> bytes) {
    bool startsWith(List<int> signature) =>
        bytes.length >= signature.length &&
        Iterable<int>.generate(signature.length)
            .every((index) => bytes[index] == signature[index]);
    if (startsWith([0xff, 0xd8, 0xff])) return 'image/jpeg';
    if (startsWith([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return 'image/png';
    }
    if (startsWith(ascii.encode('GIF87a')) ||
        startsWith(ascii.encode('GIF89a'))) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        startsWith(ascii.encode('RIFF')) &&
        Iterable<int>.generate(4)
            .every((index) => bytes[index + 8] == 'WEBP'.codeUnitAt(index))) {
      return 'image/webp';
    }
    return null;
  }

  static String _filename(String? filename, String mime) {
    final name = filename
        ?.split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[\r\n\x00]'), '')
        .trim();
    if (name != null && name.isNotEmpty) return name;
    return 'image.${mime == 'image/jpeg' ? 'jpg' : mime.split('/').last}';
  }

  static String _statusMessage(int status) {
    switch (status) {
      case 401:
      case 403:
        return 'DeepSeek 图片上传鉴权失败，请检查 API Key';
      case 413:
        return 'DeepSeek 拒绝了过大的图片，请缩小文件后重试';
      case 429:
        return 'DeepSeek 图片上传请求过多，请稍后重试';
      default:
        return 'DeepSeek 图片上传失败（HTTP $status），请稍后重试';
    }
  }
}

class DeepSeekUploadedFile {
  final String id;
  final String filename;
  final String mime;
  final int bytes;

  const DeepSeekUploadedFile({
    required this.id,
    required this.filename,
    required this.mime,
    required this.bytes,
  });
}

class DeepSeekFileException implements Exception {
  final String message;

  const DeepSeekFileException(this.message);

  @override
  String toString() => message;
}
