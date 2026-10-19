import 'dart:io';
import 'package:archive/archive.dart';
import 'package:chatgpt_app_core/backup/backup_archive_limits.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 先完整检查选中文件集合，再交给现有导入器；ZIP 只解到本次专属临时目录。
class KnowledgeImportCollection {
  static const maxEntries = 1024;
  static const maxFiles = 256;
  static const maxDepth = 12;
  static const maxFileBytes = 64 * 1024 * 1024;
  static const maxTotalBytes = 128 * 1024 * 1024;
  static const archiveLimits = BackupArchiveLimits(
    maxCompressedBytes: 64 * 1024 * 1024,
    maxEntries: maxEntries,
    maxEntryUncompressedBytes: maxFileBytes,
    maxTotalUncompressedBytes: maxTotalBytes,
  );
  static const _channel = MethodChannel('com.hzb.flutter_ai/file_picker');
  final List<String> paths;
  final Directory? _temporary;
  KnowledgeImportCollection._(List<String> paths, [this._temporary])
      : paths = List.unmodifiable(paths);

  static Future<bool> supportsDirectorySelection() async {
    if (kIsWeb) return false;
    if (Platform.operatingSystem != 'ohos') return true;
    try {
      return await _channel.invokeMethod<bool>('supportsDirectories') == true;
    } catch (_) {
      return false;
    }
  }

  /// OHOS 返回的是选择器生成的沙箱副本，只让原生端删除精确匹配的本次目录。
  static Future<void> releasePickedDirectory(String path) async {
    if (kIsWeb || Platform.operatingSystem != 'ohos') return;
    await _channel.invokeMethod<bool>('releaseDirectory', {'path': path});
  }

  static Future<KnowledgeImportCollection> fromDirectory(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('请选择普通文件夹，不支持符号链接');
    }
    final paths = <String>[], seen = <String>{};
    var entries = 0, total = 0;
    Future<void> visit(Directory directory, String prefix, int depth) async {
      if (depth > maxDepth) throw const FormatException('文件夹层级超过 12 层');
      await for (final entry in directory.list(followLinks: false)) {
        if (++entries > maxEntries) {
          throw const FormatException('文件夹条目超过 1024 个');
        }
        final name = entry.uri.pathSegments.where((p) => p.isNotEmpty).last;
        final relative = prefix + name;
        _validateName(relative);
        if (!seen.add(relative.toLowerCase())) {
          throw const FormatException('文件夹包含重名或大小写冲突');
        }
        if (entry is Directory) {
          await visit(entry, '$relative/', depth + 1);
        } else if (entry is File) {
          final size = await entry.length();
          total += size;
          if (size > maxFileBytes ||
              total > maxTotalBytes ||
              paths.length >= maxFiles) {
            throw const FormatException(
                '文件夹超过导入预算：最多 256 个文件、单文件 64 MiB、总计 128 MiB');
          }
          paths.add(entry.path);
        } else {
          throw const FormatException('文件夹包含符号链接或特殊文件');
        }
      }
    }

    await visit(Directory(path), '', 0);
    paths.sort();
    return KnowledgeImportCollection._(paths);
  }

  static Future<KnowledgeImportCollection> fromZip(
    String path, {
    Future<Directory> Function()? temporaryDirectory,
  }) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('ZIP 必须是普通文件');
    }
    final size = await File(path).length();
    validateBackupCompressedSize(size, limits: archiveLimits);
    final root = await (temporaryDirectory ?? getTemporaryDirectory)();
    final directory = await root.createTemp('knowledge-batch-');
    InputFileStream? input;
    try {
      input = InputFileStream(path);
      final preflight = preflightBoundedZip(input,
          compressedInputBytes: size, limits: archiveLimits);
      final budget = BackupArchiveOutputBudget(limits: archiveLimits);
      var files = 0;
      for (final entry in preflight.entries) {
        _validateName(entry.isDirectory
            ? entry.name.substring(0, entry.name.length - 1)
            : entry.name);
        if (!entry.isDirectory && ++files > maxFiles) {
          throw const FormatException('ZIP 文件超过 256 个');
        }
      }
      for (var i = 0; i < preflight.entries.length; i++) {
        final header = preflight.directory.fileHeaders[i],
            entry = preflight.entries[i];
        final local = header.file!;
        if (local.flags != header.generalPurposeBitFlag ||
            local.compressedSize != header.compressedSize ||
            local.uncompressedSize != header.uncompressedSize) {
          throw const FormatException('ZIP 本地文件头与中央目录不一致');
        }
        final target = '${directory.path}/${entry.name}';
        if (entry.isDirectory) {
          if (header.uncompressedSize != 0) {
            throw const FormatException('ZIP 目录大小不合法');
          }
          await Directory(target).create(recursive: true);
          continue;
        }
        final sink = budget.newEntry(entry.name);
        local.decompress(sink);
        final bytes = sink.takeBytes();
        if (bytes.length != header.uncompressedSize ||
            getCrc32(bytes) != header.crc32) {
          throw const FormatException('ZIP 文件大小或 CRC 校验失败');
        }
        await File(target).parent.create(recursive: true);
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const FormatException('ZIP 路径在当前文件系统上冲突');
        }
        await File(target).writeAsBytes(bytes, flush: true);
      }
      final collection = await fromDirectory(directory.path);
      return KnowledgeImportCollection._(collection.paths, directory);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    } finally {
      input?.closeSync();
    }
  }

  static void _validateName(String name) {
    final parts = name.split('/');
    if (parts.length > maxDepth + 1 ||
        parts
            .any((p) => p.isEmpty || p == '.' || p == '..' || p.length > 180) ||
        name.contains(r'\') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('导入路径无效或超过层级上限');
    }
  }

  Future<void> dispose() async {
    final temporary = _temporary;
    if (temporary != null && await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  }
}
