import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

typedef DownLoadListener = void Function(int total, int received, bool done);
typedef DownloadDirectoryProvider = Future<Directory> Function();

class DownloadException implements Exception {
  final String message;
  const DownloadException(this.message);
  @override
  String toString() => 'DownloadException: $message';
}

class DownloadCancelled extends DownloadException {
  const DownloadCancelled() : super('下载已暂停，下次可继续');
}

class DownloadCancellationToken {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  Future<T> guard<T>(Future<T> work) {
    if (isCancelled) return Future.error(const DownloadCancelled());
    return Future.any([
      work,
      _cancelled.future.then<T>((_) => throw const DownloadCancelled())
    ]);
  }
}

/// 只有带完整 SHA-256 的文件允许续传，最终摘要仍必须匹配。
/// URL/摘要改变、Range 不合法或摘要错误时丢弃分片；网络中断可保留分片。
class HiDownLoad {
  static final _activePaths = <String>{};

  Future<String> download({
    required String downLoadUrl,
    required String fileName,
    required DownLoadListener listener,
    String? expectedSha256,
    http.Client? client,
    DownloadDirectoryProvider? directoryProvider,
    DownloadCancellationToken? cancellationToken,
    Duration inactivityTimeout = const Duration(seconds: 45),
    int? maxBytes,
  }) async {
    final uri = Uri.tryParse(downLoadUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const DownloadException('下载地址无效');
    }
    if (fileName.trim().isEmpty ||
        fileName.contains('/') ||
        fileName.contains(r'\') ||
        fileName == '.' ||
        fileName == '..') {
      throw const DownloadException('文件名无效');
    }
    final expected = expectedSha256?.trim().toLowerCase() ?? '';
    if (expected.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      throw const DownloadException('SHA-256 格式无效');
    }
    final directory =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    await directory.create(recursive: true);
    final target = File('${directory.path}${Platform.pathSeparator}$fileName');
    if (!_activePaths.add(target.absolute.path)) {
      throw const DownloadException('该文件正在下载');
    }
    final partial = File('${target.path}.part');
    final metadata = File('${target.path}.part.json');
    final resolvedClient = client ?? http.Client();
    final token = cancellationToken ?? DownloadCancellationToken();
    IOSink? sink;
    StreamIterator<List<int>>? iterator;
    var keepPartial = expected.isNotEmpty;
    try {
      var offset = 0;
      String? etag;
      try {
        final saved = jsonDecode(await metadata.readAsString()) as Map;
        if (expected.isNotEmpty &&
            saved['url'] == uri.toString() &&
            saved['sha256'] == expected &&
            await partial.exists()) {
          offset = await partial.length();
          etag = saved['etag'] as String?;
        }
      } catch (_) {
        // 不可信或缺失的元数据从头下载。
      }
      if (maxBytes != null && offset > maxBytes) offset = 0;
      if (offset == 0 && await partial.exists()) await partial.delete();
      http.StreamedResponse response;
      for (var attempt = 0;; attempt++) {
        final request = http.Request('GET', uri);
        request.headers['Accept-Encoding'] = 'identity';
        if (offset > 0) {
          request.headers['Range'] = 'bytes=$offset-';
          if (etag != null && !etag.startsWith('W/')) {
            request.headers['If-Range'] = etag;
          }
        }
        response = await token
            .guard(resolvedClient.send(request).timeout(inactivityTimeout));
        if (response.statusCode == 416 && offset > 0 && attempt == 0) {
          await response.stream.take(0).drain<void>();
          offset = 0;
          continue;
        }
        break;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.take(0).drain<void>();
        throw DownloadException('下载失败 HTTP ${response.statusCode}');
      }
      var total = response.contentLength ?? 0;
      if (response.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers['content-range'] ?? '');
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[2]!) + 1 != int.parse(range[3]!) ||
            (response.contentLength != null &&
                response.contentLength != int.parse(range[2]!) - offset + 1) ||
            (etag != null &&
                response.headers['etag'] != null &&
                response.headers['etag'] != etag)) {
          keepPartial = false;
          await response.stream.take(0).drain<void>();
          throw const DownloadException('续传响应不匹配，请重新下载');
        }
        total = int.parse(range[3]!);
      } else {
        offset = 0; // 服务器忽略 Range 或资源变更，覆盖而非追加。
      }
      if (maxBytes != null && total > maxBytes) {
        keepPartial = false;
        await response.stream.take(0).drain<void>();
        throw const DownloadException('下载文件超过大小限制');
      }
      await metadata.writeAsString(
          jsonEncode({
            'url': uri.toString(),
            'sha256': expected,
            'etag': response.headers['etag']
          }),
          flush: true);
      sink = partial.openWrite(
          mode: offset > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly);
      var received = offset;
      iterator = StreamIterator(response.stream.timeout(inactivityTimeout));
      while (await token.guard(iterator.moveNext())) {
        final chunk = iterator.current;
        received += chunk.length;
        if ((maxBytes != null && received > maxBytes) ||
            (total > 0 && received > total)) {
          keepPartial = false;
          throw const DownloadException('下载文件超过大小限制');
        }
        sink.add(chunk);
        listener(total, received, false);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received <= 0) throw const DownloadException('下载内容为空');
      if (total > 0 && received != total) {
        throw const DownloadException('下载不完整，请重试续传');
      }
      if (token.isCancelled) throw const DownloadCancelled();
      if (expected.isNotEmpty &&
          (await sha256.bind(partial.openRead()).first).toString() !=
              expected) {
        keepPartial = false;
        throw const DownloadException('下载文件校验失败');
      }
      // 在支持原子替换的平台保留旧完整文件直到 rename 成功。
      await partial.rename(target.path);
      if (await metadata.exists()) await metadata.delete();
      listener(total, received, true);
      return target.absolute.path;
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!keepPartial) {
        for (final file in [partial, metadata]) {
          if (await file.exists()) await file.delete();
        }
      }
      rethrow;
    } finally {
      if (client == null) resolvedClient.close();
      try {
        await iterator?.cancel();
      } finally {
        _activePaths.remove(target.absolute.path);
      }
    }
  }
}
