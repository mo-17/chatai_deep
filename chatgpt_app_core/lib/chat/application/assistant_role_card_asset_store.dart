import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

typedef RoleCardAssetDirectoryResolver = Future<Directory> Function();
typedef RoleCardAssetWriteObserver = FutureOr<void> Function(
  int completedWrites,
);
typedef RoleCardAssetCleanupObserver = FutureOr<void> Function();

/// CHARX 内嵌资源的托管存储。资源只作为文件保存和导出，不会被执行。
class AssistantRoleCardAssetStore {
  static const directoryName = 'assistant_role_assets';
  static const maxAssetBytes = 20 * 1024 * 1024;
  static const maxTotalBytes = 100 * 1024 * 1024;
  static const maxAssets = 256;

  const AssistantRoleCardAssetStore._();

  static Future<String> save({
    required int assistantId,
    required List<AssistantRoleCardResource> resources,
    RoleCardAssetDirectoryResolver? directoryResolver,
    String? accountHash,
    String? generation,
    @visibleForTesting RoleCardAssetWriteObserver? debugAfterAssetWrite,
    @visibleForTesting RoleCardAssetCleanupObserver? debugBeforeBackupCleanup,
  }) async {
    final explicitAccountHash =
        AccountResourceScope.hasExplicitAccountHash(accountHash);
    final resolvedAccountHash =
        AccountResourceScope.currentAccountHash(accountHash);
    final base =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    AccountResourceScope.verifyCapturedAccount(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
    );
    return AccountResourceScope.runCapturedAccountMutation(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
      action: () async {
        final root = AccountResourceScope.legacyRoot(
          base: base,
          resourceDirectoryName: directoryName,
        );
        final scopeSegments = [
          AccountResourceScope.accountsDirectoryName,
          AccountResourceScope.tokenFor(resolvedAccountHash),
        ];
        final accountDirectory =
            await AccountResourceScope.createManagedDirectory(
          root: root,
          relativeSegments: scopeSegments,
        );
        if (!await AccountResourceScope.isCanonicalWithin(
          accountDirectory,
          root,
        )) {
          throw FileSystemException(
            'role asset account directory escaped managed root',
            accountDirectory.path,
          );
        }
        if (generation != null &&
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(generation)) {
          throw const FormatException('角色资源 generation 无效');
        }
        if (resources.length > maxAssets ||
            resources
                .any((item) => (item.bytes?.length ?? 0) > maxAssetBytes) ||
            resources.fold<int>(
                    0, (sum, item) => sum + (item.bytes?.length ?? 0)) >
                maxTotalBytes) {
          throw const FormatException('角色卡资源超过保存预算，未保存任何资源');
        }
        final targetSegments = [
          ...scopeSegments,
          '$assistantId',
          if (generation != null) ...['generations', generation]
        ];
        final directory = Directory('${root.path}/${targetSegments.join('/')}');
        await AccountResourceScope.ensureNoLinks(
          root: root,
          relativeSegments: targetSegments,
        );
        var stagingParent = accountDirectory;
        if (generation != null) {
          stagingParent = await AccountResourceScope.createManagedDirectory(
              root: root,
              relativeSegments: [
                ...scopeSegments,
                '$assistantId',
                'generations'
              ]);
          if (await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const FormatException('角色资源 generation 已存在');
          }
        }
        final staging = await stagingParent
            .createTemp('${generation ?? assistantId}.staging.');
        final stagingType = await FileSystemEntity.type(
          staging.path,
          followLinks: false,
        );
        if (stagingType != FileSystemEntityType.directory ||
            !await AccountResourceScope.isCanonicalWithin(
              staging,
              stagingParent,
            )) {
          throw FileSystemException(
            'role asset staging path is not a managed directory',
            staging.path,
          );
        }

        try {
          final manifest = <Map<String, dynamic>>[];
          var totalBytes = 0;
          var completedWrites = 0;
          for (final entry in resources.asMap().entries) {
            final resource = entry.value;
            final bytes = resource.bytes;
            String localPath = '';
            if (bytes != null &&
                bytes.isNotEmpty &&
                bytes.length <= maxAssetBytes &&
                totalBytes + bytes.length <= maxTotalBytes) {
              final filename = _filename(entry.key, resource);
              final file = File('${staging.path}/$filename');
              await file.create(exclusive: true);
              await file.writeAsBytes(bytes, flush: true);
              if (await FileSystemEntity.type(file.path, followLinks: false) !=
                  FileSystemEntityType.file) {
                throw FileSystemException(
                  'role asset staging item is not a regular file',
                  file.path,
                );
              }
              localPath = '${directory.path}/$filename';
              totalBytes += bytes.length;
              completedWrites++;
              final observer = debugAfterAssetWrite;
              if (observer != null) await observer(completedWrites);
            }
            manifest.add({
              ...resource.toJson(),
              'localPath': localPath,
            });
          }
          await AccountResourceScope.ensureNoLinks(
            root: root,
            relativeSegments: targetSegments,
          );
          await _swapDirectory(
            staging: staging,
            target: directory,
            debugBeforeBackupCleanup: debugBeforeBackupCleanup,
          );
          return jsonEncode(manifest);
        } catch (_) {
          await _deleteDirectoryIfRegular(staging);
          rethrow;
        }
      },
    );
  }

  static Future<List<AssistantRoleCardResource>> load(
    String raw, {
    RoleCardAssetDirectoryResolver? directoryResolver,
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
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    if (decoded.length > maxAssets) {
      throw const FormatException('角色卡资源数量超过安全上限');
    }
    final resources = <AssistantRoleCardResource>[];
    Directory? base;
    var totalBytes = 0;
    for (final item in decoded) {
      if (item is! Map) continue;
      final json = Map<String, dynamic>.from(item);
      final localPath = json['localPath'] as String? ?? '';
      List<int>? bytes;
      if (localPath.isNotEmpty) {
        // 清单来自可导入的角色卡，不能读取其中指定的任意本机路径。
        final suffix = managedSuffix(
          localPath,
          accountHash: resolvedAccountHash,
        );
        if (suffix != null) {
          // 绝对路径也只作为可重定位的旧清单，不直接信任其根目录。
          // 否则只要伪造 assistant_role_assets 路径就可能读取任意文件。
          if (base == null) {
            base =
                await (directoryResolver ?? getApplicationDocumentsDirectory)();
            verifyAccount();
          }
          final root = AccountResourceScope.legacyRoot(
            base: base,
            resourceDirectoryName: directoryName,
          );
          final segments = suffix.split('/');
          await AccountResourceScope.ensureNoLinks(
            root: root,
            relativeSegments: segments,
          );
          verifyAccount();
          final file = File('${root.path}/$suffix');
          final type =
              await FileSystemEntity.type(file.path, followLinks: false);
          verifyAccount();
          final canonical = type == FileSystemEntityType.file &&
              await AccountResourceScope.isCanonicalWithin(file, root);
          verifyAccount();
          if (canonical) {
            await AccountResourceScope.ensureNoLinks(
              root: root,
              relativeSegments: segments,
            );
            verifyAccount();
            final statType =
                await FileSystemEntity.type(file.path, followLinks: false);
            verifyAccount();
            if (statType != FileSystemEntityType.file) {
              throw FileSystemException(
                'role asset changed type before stat',
                file.path,
              );
            }
            final stat = await file.stat();
            verifyAccount();
            if (stat.size > maxAssetBytes) {
              throw const FormatException('单个角色卡资源超过安全上限');
            }
            if (totalBytes + stat.size > maxTotalBytes) {
              throw const FormatException('角色卡资源总大小超过安全上限');
            }
            await AccountResourceScope.ensureNoLinks(
              root: root,
              relativeSegments: segments,
            );
            verifyAccount();
            final readType =
                await FileSystemEntity.type(file.path, followLinks: false);
            verifyAccount();
            if (readType != FileSystemEntityType.file) {
              throw FileSystemException(
                'role asset changed type before reading',
                file.path,
              );
            }
            final loaded = await file.readAsBytes();
            verifyAccount();
            if (loaded.length > maxAssetBytes) {
              throw const FormatException('单个角色卡资源超过安全上限');
            }
            if (totalBytes + loaded.length > maxTotalBytes) {
              throw const FormatException('角色卡资源总大小超过安全上限');
            }
            totalBytes += loaded.length;
            bytes = loaded;
          }
        }
      }
      final metadata = AssistantRoleCardResource.fromJson(json);
      resources.add(AssistantRoleCardResource(
        type: metadata.type,
        uri: metadata.uri,
        name: metadata.name,
        ext: metadata.ext,
        archivePath: metadata.archivePath,
        mimeType: metadata.mimeType,
        size: bytes?.length ?? metadata.size,
        bytes: bytes == null ? null : Uint8List.fromList(bytes),
        includeInCard: metadata.includeInCard,
      ));
    }
    verifyAccount();
    return resources;
  }

  /// 仅清理本次预备目录。它在数据库提交前不会覆盖旧 generation。
  static Future<void> discardGeneration({
    required int assistantId,
    required String generation,
    required String accountHash,
    RoleCardAssetDirectoryResolver? directoryResolver,
  }) async {
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(generation)) {
      throw const FormatException('角色资源 generation 无效');
    }
    final base =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    final root = AccountResourceScope.legacyRoot(
        base: base, resourceDirectoryName: directoryName);
    final segments = [
      AccountResourceScope.accountsDirectoryName,
      AccountResourceScope.tokenFor(accountHash),
      '$assistantId',
      'generations',
      generation
    ];
    await AccountResourceScope.ensureNoLinks(
        root: root, relativeSegments: segments);
    final directory = Directory('${root.path}/${segments.join('/')}');
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    if (!await AccountResourceScope.isCanonicalWithin(directory, root)) {
      throw const FileSystemException('角色资源目录超出托管范围');
    }
    await _ensureTreeContainsNoLinks(directory);
    await _deleteDirectoryIfRegular(directory);
  }

  static Future<void> cleanupPreviousGenerations({
    required int assistantId,
    required String accountHash,
    required String previousManifest,
    required Iterable<String> referencedManifests,
    RoleCardAssetDirectoryResolver? directoryResolver,
  }) async {
    Set<String> generations(String manifest) {
      final output = <String>{};
      try {
        final items = jsonDecode(manifest);
        if (items is! List) return output;
        for (final item in items) {
          if (item is! Map || item['localPath'] is! String) continue;
          final suffix = managedSuffix(item['localPath'] as String,
              accountHash: accountHash);
          if (suffix == null) continue;
          final parts = suffix.split('/');
          if (parts.length >= 6 &&
              parts[2] == '$assistantId' &&
              parts[3] == 'generations' &&
              RegExp(r'^[a-f0-9-]{36}$').hasMatch(parts[4])) {
            output.add(parts[4]);
          }
        }
      } catch (_) {/* 非法旧清单不作为可删除路径。 */}
      return output;
    }

    final referenced = referencedManifests.expand(generations).toSet();
    for (final generation
        in generations(previousManifest).difference(referenced)) {
      await discardGeneration(
          assistantId: assistantId,
          generation: generation,
          accountHash: accountHash,
          directoryResolver: directoryResolver);
    }
    // 旧固定目录可能仍有其它对象引用，只保留可识别文件，不删整个 id 目录。
  }

  static String? managedSuffix(
    String path, {
    String? accountHash,
  }) {
    const marker = '/$directoryName/';
    var normalized = path.replaceAll('\\', '/').trim();
    final index = normalized.indexOf(marker);
    if (index >= 0) {
      normalized = normalized.substring(index + marker.length).trim();
    } else if (normalized.startsWith('$directoryName/')) {
      normalized = normalized.substring(directoryName.length + 1).trim();
    } else if (_isAbsolutePath(normalized)) {
      return null;
    }
    final suffix = normalized;
    if (suffix.isEmpty) return null;
    final segments = suffix.split('/');
    if (segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      return null;
    }
    if (segments.first == AccountResourceScope.accountsDirectoryName) {
      if (segments.length < 4 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(segments[1]) ||
          !_isAssistantId(segments[2])) {
        return null;
      }
      if (accountHash != null &&
          segments[1] != AccountResourceScope.tokenFor(accountHash)) {
        return null;
      }
    } else if (segments.length < 2 || !_isAssistantId(segments.first)) {
      return null;
    }
    return segments.join('/');
  }

  static Future<void> delete({
    required int assistantId,
    RoleCardAssetDirectoryResolver? directoryResolver,
    String? accountHash,
  }) async {
    final explicitAccountHash =
        AccountResourceScope.hasExplicitAccountHash(accountHash);
    final resolvedAccountHash =
        AccountResourceScope.currentAccountHash(accountHash);
    final base =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    AccountResourceScope.verifyCapturedAccount(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
    );
    return AccountResourceScope.runCapturedAccountMutation<void>(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
      action: () async {
        final root = AccountResourceScope.legacyRoot(
          base: base,
          resourceDirectoryName: directoryName,
        );
        final scopeSegments = [
          AccountResourceScope.accountsDirectoryName,
          AccountResourceScope.tokenFor(resolvedAccountHash),
        ];
        final accountDirectory = Directory(
          '${root.path}/${scopeSegments.join(Platform.pathSeparator)}',
        );
        final directory = Directory('${accountDirectory.path}/$assistantId');
        await AccountResourceScope.ensureNoLinks(
          root: root,
          relativeSegments: [...scopeSegments, '$assistantId'],
        );
        final type =
            await FileSystemEntity.type(directory.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) return;
        if (type != FileSystemEntityType.directory ||
            !await AccountResourceScope.isCanonicalWithin(
              directory,
              accountDirectory,
            )) {
          throw FileSystemException(
            'role asset path is not a regular managed directory',
            directory.path,
          );
        }
        await _ensureTreeContainsNoLinks(directory);
        await AccountResourceScope.ensureNoLinks(
          root: root,
          relativeSegments: [...scopeSegments, '$assistantId'],
        );
        await directory.delete(recursive: true);
      },
    );
  }

  static Future<void> _swapDirectory({
    required Directory staging,
    required Directory target,
    RoleCardAssetCleanupObserver? debugBeforeBackupCleanup,
  }) async {
    final targetType =
        await FileSystemEntity.type(target.path, followLinks: false);
    if (targetType == FileSystemEntityType.link ||
        (targetType != FileSystemEntityType.directory &&
            targetType != FileSystemEntityType.notFound)) {
      throw FileSystemException(
        'role asset target is not a regular directory',
        target.path,
      );
    }

    Directory? backup;
    if (targetType == FileSystemEntityType.directory) {
      await _ensureTreeContainsNoLinks(target);
      backup = Directory(await _unusedSiblingDirectoryPath(target, 'backup'));
      await target.rename(backup.path);
    }
    try {
      await staging.rename(target.path);
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
      // staging -> target 已是提交点；清理失败只留下无引用备份，
      // 不能向上抛错让 DB 丢失已生效的新 manifest。
      try {
        final observer = debugBeforeBackupCleanup;
        if (observer != null) await observer();
        await _deleteDirectoryIfRegular(backup);
      } catch (_) {}
    }
  }

  static Future<String> _unusedSiblingDirectoryPath(
    Directory target,
    String label,
  ) async {
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
      'cannot allocate a unique role asset sibling path',
      target.path,
    );
  }

  static Future<void> _ensureTreeContainsNoLinks(Directory root) async {
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'role asset tree root is not a regular directory',
        root.path,
      );
    }
    await for (final entity in root.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw FileSystemException(
          'role asset tree must not contain links',
          entity.path,
        );
      }
      if (type == FileSystemEntityType.directory) {
        await _ensureTreeContainsNoLinks(Directory(entity.path));
      } else if (type != FileSystemEntityType.file) {
        throw FileSystemException(
          'role asset tree contains an unsupported entity',
          entity.path,
        );
      }
    }
  }

  static Future<void> _deleteDirectoryIfRegular(Directory directory) async {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'refusing to delete a non-directory role asset path',
        directory.path,
      );
    }
    await _ensureTreeContainsNoLinks(directory);
    await directory.delete(recursive: true);
  }

  static bool _isAssistantId(String value) {
    final id = int.tryParse(value);
    return id != null && id > 0;
  }

  static bool _isAbsolutePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
  }

  static String _filename(int index, AssistantRoleCardResource resource) {
    final type = _safePart(resource.type, fallback: 'asset');
    final name = _safePart(resource.name, fallback: 'item');
    final ext = _safePart(
      resource.ext.replaceFirst('.', ''),
      fallback: 'bin',
    );
    return '${index.toString().padLeft(3, '0')}_${type}_$name.$ext';
  }

  static String _safePart(String value, {required String fallback}) {
    final safe = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (safe.isEmpty) return fallback;
    return safe.length > 64 ? safe.substring(0, 64) : safe;
  }
}
