library file_picker;

import 'dart:io';
import 'package:flutter/services.dart';

enum FileType { any, media, image, video, audio, custom }

class PlatformFile {
  final String? path;
  final String name;
  final int size;
  final Uint8List? bytes;
  const PlatformFile({this.path, this.name = '', this.size = 0, this.bytes});
}

class FilePickerResult {
  final List<PlatformFile> files;
  const FilePickerResult(this.files);
}

/// 与共享核心使用的 file_picker 11 API 对齐。
/// 原生侧将授权 URI 复制进缓存；保存返回值仅作结果反馈，不能再次写入。
class FilePicker {
  static const _channel = MethodChannel('com.hzb.flutter_ai/file_picker');
  static const maxFileBytes = 256 * 1024 * 1024;

  static Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
  }) async {
    if (withReadStream) throw UnsupportedError('鸿蒙文件适配暂不支持 readStream');
    final rows = await _channel.invokeListMethod<dynamic>('pickFiles', {
      'type': type.name,
      'allowedExtensions': _extensions(type, allowedExtensions),
      'allowMultiple': allowMultiple,
    });
    if (rows == null || rows.isEmpty) return null;
    final files = <PlatformFile>[];
    for (final row in rows) {
      if (row is! Map ||
          row['path'] is! String ||
          row['name'] is! String ||
          row['size'] is! int ||
          row['size'] < 0 ||
          row['size'] > maxFileBytes) {
        throw const FormatException('鸿蒙文件选择器返回无效结果');
      }
      final path = row['path'] as String;
      final bytes = withData ? await File(path).readAsBytes() : null;
      if (bytes != null && bytes.length > maxFileBytes) {
        throw const FormatException('文件超过 256 MiB 上限');
      }
      files.add(PlatformFile(
          path: path,
          name: row['name'] as String,
          size: bytes?.length ?? row['size'] as int,
          bytes: bytes));
    }
    return FilePickerResult(List.unmodifiable(files));
  }

  static Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) {
    if (bytes == null) throw ArgumentError.notNull('bytes');
    if (bytes.length > maxFileBytes) throw ArgumentError('文件超过 256 MiB 上限');
    return _channel.invokeMethod<String>('saveFile', {
      'fileName': fileName ?? 'export',
      'allowedExtensions': _extensions(type, allowedExtensions),
      'bytes': bytes,
    });
  }

  // 离线模型目录涉及递归授权，保留明确的不支持边界。
  static Future<String?> getDirectoryPath(
          {String? dialogTitle,
          String? initialDirectory,
          bool lockParentWindow = false}) async =>
      throw UnsupportedError('鸿蒙暂不支持目录导入，请使用模型压缩包');

  static Future<bool?> clearTemporaryFiles() =>
      _channel.invokeMethod<bool>('clearTemporaryFiles');

  static List<String> _extensions(FileType type, List<String>? extensions) {
    const images = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'];
    const videos = ['mp4', 'mov', 'mkv', 'webm', 'avi'];
    switch (type) {
      case FileType.any:
        return const [];
      case FileType.image:
        return images;
      case FileType.video:
        return videos;
      case FileType.audio:
        return const ['mp3', 'wav', 'aac', 'm4a', 'ogg', 'flac'];
      case FileType.media:
        return [...images, ...videos];
      case FileType.custom:
        break;
    }
    if (extensions == null ||
        extensions.isEmpty ||
        extensions.length > 100 ||
        extensions.any((e) => !RegExp(r'^[a-zA-Z0-9]{1,16}$').hasMatch(e))) {
      throw ArgumentError('custom 文件类型需要有效扩展名');
    }
    return extensions.map((e) => e.toLowerCase()).toSet().toList();
  }
}
