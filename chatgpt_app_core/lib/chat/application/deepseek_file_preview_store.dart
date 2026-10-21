import 'dart:async';
import 'dart:convert';
import 'package:login_sdk/platform/app_io.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:chatgpt_app_core/platform/app_paths.dart';

/// 官方文件接口仅返回元数据；上传成功时保存与 file_id 精确关联的本地缩略图。
/// 目录和文件名只包含摘要，不落盘账号、API Key 或原图。
class DeepSeekFilePreviewStore {
  static final instance = DeepSeekFilePreviewStore();
  static Future<void> _operationTail = Future<void>.value();
  static final _cacheName = RegExp(r'^[a-f0-9]{64}_[a-f0-9]{64}\.png$');
  static final _fileId = RegExp(r'^file-api-[A-Za-z0-9_-]+$');

  final Future<Directory> Function() _rootDirectory;
  final int maxCacheBytes;
  final int maxFiles;
  final int maxThumbnailEdge;
  final int maxThumbnailBytes;

  DeepSeekFilePreviewStore({
    Future<Directory> Function()? rootDirectory,
    this.maxCacheBytes = 64 * 1024 * 1024,
    this.maxFiles = 128,
    this.maxThumbnailEdge = 1280,
    this.maxThumbnailBytes = 8 * 1024 * 1024,
  }) : _rootDirectory = rootDirectory ?? _defaultRoot {
    if (maxCacheBytes < 1 ||
        maxFiles < 1 ||
        maxThumbnailEdge < 1 ||
        maxThumbnailEdge > 1280 ||
        maxThumbnailBytes < 1 ||
        maxThumbnailBytes > 8 * 1024 * 1024) {
      throw ArgumentError('图片预览缓存预算无效');
    }
  }

  static Future<Directory> _defaultRoot() async => appDirectory(
      '${(await getApplicationSupportDirectory()).path}/deepseek_file_previews_v1');

  Future<Uint8List?> read({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) async {
    final name = _name(accountHash, chatCompletionsUrl, apiKey, fileId);
    if (name == null) return null;
    return _serialize(() async {
      try {
        final root = await _rootDirectory();
        await AccountResourceScope.ensureNoLinks(
            root: root, relativeSegments: [name]);
        final file = appFile('${root.path}/$name');
        if (await appFileType(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return null;
        }
        final bytes = await readFileBytesBounded(file,
            maxBytes: maxThumbnailBytes, label: '图片预览');
        if (!await _validThumbnail(bytes)) {
          await file.delete();
          return null;
        }
        await file.setLastModified(DateTime.now());
        await _trim(root);
        return bytes;
      } catch (_) {
        // 预览不是上传/聊天的必要条件；损坏、权限或平台失败只显示占位图。
        return null;
      }
    });
  }

  Future<void> save({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
    required Uint8List bytes,
    bool Function()? shouldSave,
  }) async {
    final name = _name(accountHash, chatCompletionsUrl, apiKey, fileId);
    if (name == null ||
        bytes.isEmpty ||
        bytes.length > DeepSeekFileService.maxImageBytes ||
        DeepSeekFileService.imageMimeForBytes(bytes) == null) {
      return;
    }
    // 调用方可以复用自己的 buffer；异步排队后仍处理上传时的准确内容。
    final source = Uint8List.fromList(bytes);
    await _serialize(() async {
      File? temporary;
      try {
        if (shouldSave != null && !shouldSave()) return;
        final thumbnail = await _thumbnail(source);
        if (thumbnail == null || thumbnail.length > maxCacheBytes) return;
        // DELETE 可能在图片解码或账号 lease 排队期间完成。
        if (shouldSave != null && !shouldSave()) return;
        final root = await _rootDirectory();
        await AccountResourceScope.createManagedDirectory(root: root);
        await AccountResourceScope.ensureNoLinks(
            root: root, relativeSegments: [name]);
        await AccountResourceScope.ensureNoLinks(
            root: root, relativeSegments: ['$name.part']);
        if (shouldSave != null && !shouldSave()) return;
        final file = appFile('${root.path}/$name');
        temporary = appFile('${file.path}.part');
        await temporary.writeAsBytes(thumbnail, flush: true);
        await AccountResourceScope.ensureNoLinks(
            root: root, relativeSegments: [name]);
        await AccountResourceScope.ensureNoLinks(
            root: root, relativeSegments: ['$name.part']);
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
        temporary = null;
        await _trim(root);
      } catch (_) {
        // 缓存失败不会让已经成功上传的图片变成聊天失败。
      } finally {
        try {
          if (temporary != null &&
              await appFileType(temporary.path, followLinks: false) ==
                  FileSystemEntityType.file) {
            await temporary.delete();
          }
        } catch (_) {}
      }
    });
  }

  Future<void> remove({
    required String accountHash,
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) async {
    final name = _name(accountHash, chatCompletionsUrl, apiKey, fileId);
    if (name == null) return;
    await _serialize(() async {
      try {
        final root = await _rootDirectory();
        await AccountResourceScope.ensureNoLinks(
            root: root, relativeSegments: [name]);
        final file = appFile('${root.path}/$name');
        if (await appFileType(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          await file.delete();
        }
      } catch (_) {}
    });
  }

  static String? _name(String accountHash, String chatCompletionsUrl,
      String apiKey, String fileId) {
    if (accountHash.trim().isEmpty ||
        apiKey.trim().isEmpty ||
        fileId.length > 256 ||
        !_fileId.hasMatch(fileId)) {
      return null;
    }
    try {
      final endpoint =
          DeepSeekFileService.filesEndpointFor(chatCompletionsUrl).toString();
      final scope = sha256
          .convert(utf8.encode(
              jsonEncode([accountHash.trim(), endpoint, apiKey.trim()])))
          .toString();
      final id = sha256.convert(utf8.encode(fileId)).toString();
      return '${scope}_$id.png';
    } catch (_) {
      return null;
    }
  }

  /// 所有实例共用短队列，避免重建缓存对象时读到半写入文件或竞态驱逐。
  static Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _operationTail.then((_) => action());
    _operationTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<Uint8List?> _thumbnail(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width < 1 ||
          height < 1 ||
          width > 100000 ||
          height > 100000 ||
          width * height > 100000000) {
        return null;
      }
      final scale = math.min(1.0, maxThumbnailEdge / math.max(width, height));
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > maxThumbnailBytes) {
        return null;
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<bool> _validThumbnail(Uint8List bytes) async {
    if (DeepSeekFileService.imageMimeForBytes(bytes) != 'image/png') {
      return false;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width > maxThumbnailEdge ||
          descriptor.height > maxThumbnailEdge) {
        return false;
      }
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      return true;
    } catch (_) {
      return false;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> _trim(Directory root) async {
    final entries = <({File file, FileStat stat})>[];
    var bytes = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File ||
          !_cacheName.hasMatch(entity.uri.pathSegments.last)) {
        continue;
      }
      final stat = await entity.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      entries.add((file: entity, stat: stat));
      bytes += stat.size;
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var count = entries.length;
    for (final entry in entries) {
      if (bytes <= maxCacheBytes && count <= maxFiles) break;
      await entry.file.delete();
      bytes -= entry.stat.size;
      count--;
    }
  }
}
