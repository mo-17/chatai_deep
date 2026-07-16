import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

typedef ImageSaveDirectoryResolver = Future<Directory> Function();
typedef ImageSaveCleanupObserver = FutureOr<void> Function();

class GeneratedImageAlbumItem {
  final String path;
  final String filename;
  final int sizeBytes;
  final DateTime modifiedAt;

  const GeneratedImageAlbumItem({
    required this.path,
    required this.filename,
    required this.sizeBytes,
    required this.modifiedAt,
  });
}

class GeneratedImageSaveService {
  static const albumDirectoryName = 'generated_images';
  static const _imageExtensions = {'.png', '.jpg', '.jpeg', '.webp', '.gif'};

  static Future<String> saveToAppAlbum(
    GeneratedImageSavePlan plan, {
    ImageSaveDirectoryResolver? directoryResolver,
    http.Client? client,
    String? accountHash,
    @visibleForTesting ImageSaveCleanupObserver? debugBeforeBackupCleanup,
  }) async {
    final explicitAccountHash =
        AccountResourceScope.hasExplicitAccountHash(accountHash);
    final resolvedAccountHash =
        AccountResourceScope.currentAccountHash(accountHash);
    final filename = _basename(plan.filename);
    if (filename.isEmpty || filename == '.' || filename == '..') {
      throw ArgumentError.value(plan.filename, 'filename', '图片文件名不合法');
    }
    final baseDir =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    AccountResourceScope.verifyCapturedAccount(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
    );
    final bytes = await _readSource(plan.source, client: client);
    AccountResourceScope.verifyCapturedAccount(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
    );
    return AccountResourceScope.runCapturedAccountMutation(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
      action: () async {
        final root = AccountResourceScope.legacyRoot(
          base: baseDir,
          resourceDirectoryName: albumDirectoryName,
        );
        final scopeSegments = [
          AccountResourceScope.accountsDirectoryName,
          AccountResourceScope.tokenFor(resolvedAccountHash),
        ];
        final targetDir = await AccountResourceScope.createManagedDirectory(
          root: root,
          relativeSegments: scopeSegments,
        );
        if (!await AccountResourceScope.isCanonicalWithin(targetDir, root)) {
          throw FileSystemException(
            'generated image directory escaped managed root',
            targetDir.path,
          );
        }
        final target = File('${targetDir.path}/$filename');
        if (!await AccountResourceScope.isCanonicalDirectChild(
          target,
          targetDir,
        )) {
          throw FileSystemException(
            'generated image target escaped account directory',
            target.path,
          );
        }
        await AccountResourceScope.ensureNoLinks(
          root: root,
          relativeSegments: [...scopeSegments, filename],
        );
        await _replaceRegularFile(
          target,
          bytes,
          debugBeforeBackupCleanup: debugBeforeBackupCleanup,
        );
        return target.path;
      },
    );
  }

  static Future<List<GeneratedImageAlbumItem>> listSavedImages({
    ImageSaveDirectoryResolver? directoryResolver,
    String? accountHash,
  }) async {
    final explicitAccountHash =
        AccountResourceScope.hasExplicitAccountHash(accountHash);
    final resolvedAccountHash =
        AccountResourceScope.currentAccountHash(accountHash);
    void verifyAccount() => AccountResourceScope.verifyCapturedAccount(
          capturedAccountHash: resolvedAccountHash,
          explicitAccountHash: explicitAccountHash,
        );
    final baseDir =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    verifyAccount();
    final legacyRoot = AccountResourceScope.legacyRoot(
      base: baseDir,
      resourceDirectoryName: albumDirectoryName,
    );
    final scopedDir = AccountResourceScope.scopedDirectory(
      base: baseDir,
      resourceDirectoryName: albumDirectoryName,
      accountHash: resolvedAccountHash,
    );
    final scopedSegments = [
      AccountResourceScope.accountsDirectoryName,
      AccountResourceScope.tokenFor(resolvedAccountHash),
    ];
    final items = <GeneratedImageAlbumItem>[];
    await _appendImageFiles(
      root: legacyRoot,
      directory: scopedDir,
      relativeSegments: scopedSegments,
      items: items,
      verifyAccount: verifyAccount,
    );
    verifyAccount();
    // 旧版图片位于 generated_images 顶层，继续对当前账号可见；
    // accounts/ 是子目录，不会被这里递归扫描。
    await _appendImageFiles(
      root: legacyRoot,
      directory: legacyRoot,
      relativeSegments: const [],
      items: items,
      verifyAccount: verifyAccount,
    );
    verifyAccount();
    items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return items;
  }

  static Future<void> _appendImageFiles({
    required Directory root,
    required Directory directory,
    required List<String> relativeSegments,
    required List<GeneratedImageAlbumItem> items,
    required void Function() verifyAccount,
  }) async {
    await AccountResourceScope.ensureNoLinks(
      root: root,
      relativeSegments: relativeSegments,
    );
    verifyAccount();
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    verifyAccount();
    if (directoryType == FileSystemEntityType.notFound) return;
    final canonicalDirectory =
        directoryType == FileSystemEntityType.directory &&
            await AccountResourceScope.isCanonicalWithin(directory, root);
    verifyAccount();
    if (!canonicalDirectory) {
      throw FileSystemException(
        'generated image album is not a regular managed directory',
        directory.path,
      );
    }
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!_imageExtensions.any((ext) => name.toLowerCase().endsWith(ext))) {
        continue;
      }
      await AccountResourceScope.ensureNoLinks(
        root: root,
        relativeSegments: [...relativeSegments, name],
      );
      verifyAccount();
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      verifyAccount();
      final directChild = type == FileSystemEntityType.file &&
          await AccountResourceScope.isCanonicalDirectChild(
            entity,
            directory,
          );
      verifyAccount();
      final withinRoot = directChild &&
          await AccountResourceScope.isCanonicalWithin(entity, root);
      verifyAccount();
      if (!withinRoot) {
        throw FileSystemException(
          'generated image is not a regular managed file',
          entity.path,
        );
      }
      final stat = await entity.stat();
      verifyAccount();
      items.add(GeneratedImageAlbumItem(
        path: entity.path,
        filename: name,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
      ));
    }
  }

  static Future<bool> deleteSavedImage(
    String path, {
    ImageSaveDirectoryResolver? directoryResolver,
    String? accountHash,
  }) async {
    final explicitAccountHash =
        AccountResourceScope.hasExplicitAccountHash(accountHash);
    final resolvedAccountHash =
        AccountResourceScope.currentAccountHash(accountHash);
    final baseDir =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    AccountResourceScope.verifyCapturedAccount(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
    );
    return AccountResourceScope.runCapturedAccountMutation(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
      action: () async {
        final legacyRoot = AccountResourceScope.legacyRoot(
          base: baseDir,
          resourceDirectoryName: albumDirectoryName,
        );
        final scopedDir = AccountResourceScope.scopedDirectory(
          base: baseDir,
          resourceDirectoryName: albumDirectoryName,
          accountHash: resolvedAccountHash,
        );
        final file = File(path).absolute;
        final filename = _basename(file.path);
        late final Directory allowedDirectory;
        late final List<String> directorySegments;
        if (AccountResourceScope.isDirectChild(file, scopedDir)) {
          allowedDirectory = scopedDir;
          directorySegments = [
            AccountResourceScope.accountsDirectoryName,
            AccountResourceScope.tokenFor(resolvedAccountHash),
          ];
        } else if (AccountResourceScope.isDirectChild(file, legacyRoot)) {
          allowedDirectory = legacyRoot;
          directorySegments = const [];
        } else {
          throw FileSystemException(
            'image is outside current account generated album',
            path,
          );
        }
        await AccountResourceScope.ensureNoLinks(
          root: legacyRoot,
          relativeSegments: [...directorySegments, filename],
        );
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) return false;
        if (type != FileSystemEntityType.file ||
            !await AccountResourceScope.isCanonicalDirectChild(
              file,
              allowedDirectory,
            ) ||
            !await AccountResourceScope.isCanonicalWithin(file, legacyRoot)) {
          throw FileSystemException(
            'image is not a regular managed file',
            path,
          );
        }
        await file.delete();
        return true;
      },
    );
  }

  static Future<void> _replaceRegularFile(
    File target,
    Uint8List bytes, {
    ImageSaveCleanupObserver? debugBeforeBackupCleanup,
  }) async {
    final temp = await _createSiblingTempFile(target, 'tmp');
    File? backup;
    try {
      await temp.writeAsBytes(bytes, flush: true);
      if (await FileSystemEntity.type(temp.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException(
            'temporary image is not a regular file', temp.path);
      }

      final targetType =
          await FileSystemEntity.type(target.path, followLinks: false);
      if (targetType == FileSystemEntityType.link ||
          (targetType != FileSystemEntityType.file &&
              targetType != FileSystemEntityType.notFound)) {
        throw FileSystemException(
          'generated image target is not a regular file',
          target.path,
        );
      }
      if (targetType == FileSystemEntityType.file) {
        backup = File(await _unusedSiblingPath(target, 'backup'));
        await target.rename(backup.path);
      }
      try {
        await temp.rename(target.path);
      } catch (error, stackTrace) {
        if (backup != null &&
            await FileSystemEntity.type(target.path, followLinks: false) ==
                FileSystemEntityType.notFound) {
          await backup.rename(target.path);
          backup = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (backup != null) {
        // staging -> target 已是提交点；清理旧备份失败不能再把
        // 本次保存报成失败，否则上层会遗失已生效的新路径。
        try {
          final observer = debugBeforeBackupCleanup;
          if (observer != null) await observer();
          await backup.delete();
        } catch (_) {}
        backup = null;
      }
    } finally {
      if (await FileSystemEntity.type(temp.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await temp.delete();
      }
    }
  }

  static Future<File> _createSiblingTempFile(
    File target,
    String label,
  ) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final path = await _unusedSiblingPath(target, label);
      final file = File(path);
      try {
        await file.create(exclusive: true);
        return file;
      } on FileSystemException {
        // 极低概率同名，重新生成即可。
      }
    }
    throw FileSystemException(
      'cannot create a unique temporary image file',
      target.path,
    );
  }

  static Future<String> _unusedSiblingPath(File target, String label) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final nonce = '${DateTime.now().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}';
      final candidate = '${target.path}.$label.$nonce';
      if (await FileSystemEntity.type(candidate, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    throw FileSystemException(
      'cannot allocate a unique sibling path',
      target.path,
    );
  }

  static Future<Uint8List> _readSource(String source,
      {http.Client? client}) async {
    if (source.startsWith('data:image/')) {
      final comma = source.indexOf(',');
      if (comma < 0) throw const FormatException('invalid image data uri');
      return base64Decode(source.substring(comma + 1));
    }
    if (source.startsWith('http://') || source.startsWith('https://')) {
      final ownsClient = client == null;
      final httpClient = client ?? http.Client();
      try {
        final response = await httpClient.get(Uri.parse(source));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('download failed: ${response.statusCode}');
        }
        return response.bodyBytes;
      } finally {
        if (ownsClient) httpClient.close();
      }
    }
    final file = File(source);
    if (!file.existsSync()) {
      throw FileSystemException('image source not found', source);
    }
    return file.readAsBytes();
  }

  static String _basename(String path) {
    final parts =
        path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}
