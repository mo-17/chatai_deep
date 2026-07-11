import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

typedef CreativePickFiles = Future<FilePickerResult?> Function({
  String? dialogTitle,
  String? initialDirectory,
  List<String>? allowedExtensions,
  required bool withData,
});

typedef CreativeSaveFile = Future<String?> Function({
  String? dialogTitle,
  String? fileName,
  String? initialDirectory,
  List<String>? allowedExtensions,
  required Uint8List bytes,
});

typedef CreativeReadBytes = Future<Uint8List> Function(String path);

class CreativeFileTransferException implements Exception {
  final String message;
  final Object? cause;

  const CreativeFileTransferException(this.message, {this.cause});

  @override
  String toString() => 'CreativeFileTransferException: $message';
}

class CreativePickedFile {
  final String name;
  final String? path;
  final Uint8List bytes;

  const CreativePickedFile({
    required this.name,
    required this.bytes,
    this.path,
  });

  int get sizeBytes => bytes.length;
}

class CreativeFileSaveResult {
  final bool saved;
  final String? path;

  const CreativeFileSaveResult({
    required this.saved,
    this.path,
  });

  bool get cancelled => !saved;
}

/// 创作和酒馆文件传输的系统边界。
///
/// 选择器、文件读写和移动端判断均可替换，页面只需要依赖这个 gateway，
/// 测试也不需要真正打开系统文件选择器。
class CreativeFileTransferGateway {
  static const defaultMaxBytes = 256 * 1024;

  final CreativePickFiles _pickFiles;
  final CreativeSaveFile _saveFile;
  final CreativeReadBytes _readBytes;
  final int maxBytes;

  CreativeFileTransferGateway({
    CreativePickFiles? pickFiles,
    CreativeSaveFile? saveFile,
    CreativeReadBytes? readBytes,
    this.maxBytes = defaultMaxBytes,
  })  : _pickFiles = pickFiles ?? _pickWithFilePicker,
        _saveFile = saveFile ?? _saveWithFilePicker,
        _readBytes = readBytes ?? _readFileBytes {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', '必须大于 0');
    }
  }

  /// 选择单个文件，并始终以实际读取到的 bytes 长度做限制判断。
  ///
  /// [withData] 由 gateway 固定开启；移动端通常直接提供 [PlatformFile.bytes]，
  /// 桌面端或插件未提供 bytes 时则回退到 [PlatformFile.path] 读取。
  /// 用户取消或选择器返回空列表时返回 null。
  Future<CreativePickedFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    List<String>? allowedExtensions,
  }) async {
    final result = await _pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      allowedExtensions: allowedExtensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final platformFile = result.files.first;
    final bytes = platformFile.bytes ?? await _readPickedPath(platformFile);
    if (bytes.length > maxBytes) {
      throw CreativeFileTransferException(
        '文件「${platformFile.name}」实际大小 ${bytes.length} bytes，'
        '超过 $maxBytes bytes 上限。',
      );
    }
    return CreativePickedFile(
      name: platformFile.name,
      path: platformFile.path,
      bytes: Uint8List.fromList(bytes),
    );
  }

  /// 选择并严格按 UTF-8 解码文本文件。
  ///
  /// 非法 UTF-8 不会被替换成 �，而是抛出带有明确说明的异常；取消仍返回 null。
  Future<String?> pickUtf8Text({
    String? dialogTitle,
    String? initialDirectory,
    List<String>? allowedExtensions,
  }) async {
    final picked = await pickFile(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      allowedExtensions: allowedExtensions,
    );
    if (picked == null) return null;
    try {
      final decoded = utf8.decode(picked.bytes, allowMalformed: false);
      return decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
    } on FormatException catch (error) {
      throw CreativeFileTransferException(
        '文件「${picked.name}」不是有效的 UTF-8 文本。',
        cause: error,
      );
    }
  }

  /// 保存 bytes。file_picker 11.x 在所有支持平台都会消费 [bytes]，
  /// 返回路径仅用于反馈，不能再次写入，否则桌面端会重复覆盖同一文件。
  Future<CreativeFileSaveResult> saveBytes(
    Uint8List bytes, {
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    List<String>? allowedExtensions,
  }) async {
    final payload = Uint8List.fromList(bytes);
    final path = await _saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      initialDirectory: initialDirectory,
      allowedExtensions: allowedExtensions,
      bytes: payload,
    );
    if (path == null) return const CreativeFileSaveResult(saved: false);

    return CreativeFileSaveResult(saved: true, path: path);
  }

  Future<Uint8List> _readPickedPath(PlatformFile platformFile) async {
    final path = platformFile.path;
    if (path == null || path.isEmpty) {
      throw CreativeFileTransferException(
        '文件「${platformFile.name}」没有可读取的 bytes 或 path。',
      );
    }
    try {
      return await _readBytes(path);
    } catch (error) {
      throw CreativeFileTransferException(
        '无法读取文件「${platformFile.name}」的内容。',
        cause: error,
      );
    }
  }

  static Future<FilePickerResult?> _pickWithFilePicker({
    String? dialogTitle,
    String? initialDirectory,
    List<String>? allowedExtensions,
    required bool withData,
  }) {
    return FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: allowedExtensions?.isNotEmpty == true
          ? FileType.custom
          : FileType.any,
      allowedExtensions: allowedExtensions,
      allowMultiple: false,
      withData: withData,
    );
  }

  static Future<String?> _saveWithFilePicker({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    List<String>? allowedExtensions,
    required Uint8List bytes,
  }) {
    return FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      initialDirectory: initialDirectory,
      type: allowedExtensions?.isNotEmpty == true
          ? FileType.custom
          : FileType.any,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }

  static Future<Uint8List> _readFileBytes(String path) async =>
      Uint8List.fromList(await File(path).readAsBytes());
}
