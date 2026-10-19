import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';
export 'package:cross_file/cross_file.dart' show XFile;

class ShareParams {
  final String? text, subject, title;
  final List<XFile>? files;
  final Object? sharePositionOrigin;
  const ShareParams({
    this.text,
    this.subject,
    this.title,
    this.files,
    this.sharePositionOrigin,
  });
}

enum ShareResultStatus { success, dismissed, unavailable }

class ShareResult {
  final String raw;
  final ShareResultStatus status;
  const ShareResult(this.raw, this.status);
}

class SharePlus {
  SharePlus._();
  static final instance = SharePlus._();
  static const _channel = MethodChannel('com.hzb.flutter_ai/share');

  Future<ShareResult> share(ShareParams params) async {
    final files = params.files ?? const <XFile>[];
    if ((params.text?.trim().isEmpty ?? true) && files.isEmpty) {
      throw ArgumentError('分享内容不能为空');
    }
    if (files.length > 10 || (params.text?.length ?? 0) > 100000) {
      throw ArgumentError('分享内容超过上限');
    }
    final paths = <Map<String, String>>[];
    var total = 0;
    for (final file in files) {
      // 当前应用的文件分享均来自本机文件；内存 XFile 需要调用方先保存。
      if (!file.path.startsWith('/')) throw ArgumentError('请先保存待分享文件');
      final size = await file.length();
      total += size;
      if (size > 64 * 1024 * 1024 || total > 128 * 1024 * 1024) {
        throw ArgumentError('分享文件超过上限');
      }
      paths.add({'path': file.path, 'name': file.name});
    }
    final status = await _channel.invokeMethod<String>('share', {
      'text': params.text,
      'title': params.title ?? params.subject,
      'files': paths,
    });
    return switch (status) {
      'success' => const ShareResult('success', ShareResultStatus.success),
      'dismissed' => const ShareResult('', ShareResultStatus.dismissed),
      _ => const ShareResult('', ShareResultStatus.unavailable),
    };
  }
}
