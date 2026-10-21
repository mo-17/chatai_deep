import 'package:login_sdk/platform/app_io.dart';
import 'dart:math';
import 'dart:typed_data';

import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// FileBlock 可持久化路径的唯一可信根。备份导出只读取这里的普通文件，归档
/// 元数据或旧数据库中的任意绝对路径都不会再成为文件系统读取能力。
final class ManagedAttachmentStore {
  static const maxAttachmentBytes = 32 * 1024 * 1024;

  @visibleForTesting
  static Directory? debugRootDirectory;

  static Directory get rootDirectory =>
      debugRootDirectory ??
      appDirectory('${appTemporaryDirectory.path}/chatai_attachment_files');

  /// 返回经 no-follow 校验的可信目录。固定根若被本机其他进程预置为链接，
  /// 必须拒绝而不是沿链接获得任意文件读写能力。
  static Future<Directory> ensureRootDirectory() async {
    final root = rootDirectory;
    var type = await appFileType(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
      type = await appFileType(root.path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('附件安全目录不可用');
    }
    return appDirectory(await root.resolveSymbolicLinks());
  }

  static Future<String> importFile(
    File source, {
    int maxBytes = maxAttachmentBytes,
  }) async {
    final type = await appFileType(source.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const FormatException('附件不允许使用符号链接');
    }
    if (type != FileSystemEntityType.file) {
      throw const FormatException('附件不是普通文件');
    }
    final bytes = await readFileBytesBounded(
      source,
      maxBytes: maxBytes,
      label: '附件',
    );
    final root = await ensureRootDirectory();
    final extension = _safeExtension(source.path);
    final digest = sha256.convert(bytes);
    final name = '$digest$extension';
    final target = appFile('${root.path}/$name');
    final targetType =
        await appFileType(target.path, followLinks: false);
    if (targetType == FileSystemEntityType.file) {
      final existing = await readFileBytesBounded(
        target,
        maxBytes: maxBytes,
        label: '附件',
      );
      if (sha256.convert(existing).toString() != digest.toString()) {
        throw const FormatException('附件安全目录中的文件校验失败');
      }
      return target.path;
    }
    if (targetType != FileSystemEntityType.notFound) {
      throw const FormatException('附件目标不是普通文件');
    }

    final random = Random.secure();
    final suffix = List<int>.generate(16, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    final temporary = appFile('${root.path}/.$name.$suffix.tmp');
    try {
      await temporary.create(exclusive: true);
      await temporary.writeAsBytes(bytes, flush: true);
      // rename 替换的是目录项本身，不会沿攻击者竞态插入的 symlink 写目标。
      await temporary.rename(target.path);
    } on FileSystemException {
      final concurrentType =
          await appFileType(target.path, followLinks: false);
      if (concurrentType != FileSystemEntityType.file) rethrow;
      final existing = await readFileBytesBounded(
        target,
        maxBytes: maxBytes,
        label: '附件',
      );
      if (sha256.convert(existing).toString() != digest.toString()) rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return target.path;
  }

  static Future<Uint8List?> readManagedBytes(
    String? path, {
    int maxBytes = maxAttachmentBytes,
  }) async {
    if (path == null || path.isEmpty) return null;
    final rawRoot = rootDirectory;
    final rootType =
        await appFileType(rawRoot.path, followLinks: false);
    if (rootType != FileSystemEntityType.directory) return null;
    final candidate = appFile(path);
    if (await appFileType(candidate.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    try {
      final rootCanonical = await rawRoot.resolveSymbolicLinks();
      final fileCanonical = await candidate.resolveSymbolicLinks();
      final prefix = rootCanonical.endsWith(Platform.pathSeparator)
          ? rootCanonical
          : '$rootCanonical${Platform.pathSeparator}';
      if (!fileCanonical.startsWith(prefix)) return null;
      return await readFileBytesBounded(
        appFile(fileCanonical),
        maxBytes: maxBytes,
        label: '附件',
      );
    } catch (_) {
      return null;
    }
  }

  static String _safeExtension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    final extension = name.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension) ? extension : '';
  }
}
