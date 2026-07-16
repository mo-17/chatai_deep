import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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

class HiDownLoad {
  int _total = 0, _received = 0;

  Future<String> download({
    required String downLoadUrl,
    required String fileName,
    required DownLoadListener listener,
    String? expectedSha256,
    http.Client? client,
    DownloadDirectoryProvider? directoryProvider,
  }) async {
    final uri = Uri.tryParse(downLoadUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
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
    if (expected.isNotEmpty &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      throw const DownloadException('SHA-256 格式无效');
    }

    final resolvedClient = client ?? http.Client();
    final ownClient = client == null;
    File? partialFile;
    IOSink? sink;
    try {
      debugPrint('start download');
      final response = await resolvedClient.send(http.Request('GET', uri));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>();
        throw DownloadException('下载失败 HTTP ${response.statusCode}');
      }

      _total = response.contentLength ?? 0;
      _received = 0;
      final directory = await (directoryProvider ??
          () => getApplicationDocumentsDirectory())();
      await directory.create(recursive: true);
      final targetFile = File(
        '${directory.path}${Platform.pathSeparator}$fileName',
      );
      partialFile = File('${targetFile.path}.part');
      if (await partialFile.exists()) await partialFile.delete();
      sink = partialFile.openWrite(mode: FileMode.writeOnly);

      await for (final chunk in response.stream) {
        sink.add(chunk);
        _received += chunk.length;
        listener(_total, _received, false);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (_received <= 0) {
        throw const DownloadException('下载内容为空');
      }
      if (_total > 0 && _received != _total) {
        throw DownloadException('下载不完整：期望 $_total 字节，收到 $_received 字节');
      }

      if (expected.isNotEmpty) {
        final actual =
            (await sha256.bind(partialFile.openRead()).first).toString();
        if (actual != expected) {
          throw const DownloadException('下载文件校验失败');
        }
      }

      if (await targetFile.exists()) await targetFile.delete();
      await partialFile.rename(targetFile.path);
      partialFile = null;
      listener(_total, _received, true);
      debugPrint('download completed');
      return targetFile.absolute.path;
    } catch (_) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 清理失败不覆盖原始下载错误。
        }
      }
      if (partialFile != null && await partialFile.exists()) {
        try {
          await partialFile.delete();
        } catch (_) {
          // 清理失败不覆盖原始下载错误。
        }
      }
      rethrow;
    } finally {
      if (ownClient) resolvedClient.close();
    }
  }
}
