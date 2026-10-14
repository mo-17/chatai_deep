import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:login_sdk/dao/login_dao.dart';

/// 多账号文件资源的脱敏路径约定。
///
/// [base] 始终是 documents 根目录，不改变现有 resolver 的语义；
/// 账号原文只用于计算完整 SHA-256，不会出现在文件路径中。
class AccountResourceScope {
  static const accountsDirectoryName = 'accounts';

  const AccountResourceScope._();

  /// 解析资源路径账号。未初始化/无 profile 时的 `guest` 仅是路径兼容 fallback；
  /// 隐式异步 mutation 仍需 [verifyCapturedAccount] 确认真实稳定账号。
  static String currentAccountHash([String? accountHash]) {
    final explicit = accountHash?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    String current = '';
    try {
      current = LoginDao.getAccountHash()?.trim() ?? '';
    } catch (_) {
      // 应用初始化前的纯 Dart 场景没有安装 LoginSdkConfig。
    }
    return current.isEmpty ? 'guest' : current;
  }

  static bool hasExplicitAccountHash(String? accountHash) =>
      accountHash?.trim().isNotEmpty == true;

  /// 隐式使用当前账号的调用在异步边界后必须重新校验；显式账号由上层业务绑定。
  static void verifyCapturedAccount({
    required String capturedAccountHash,
    required bool explicitAccountHash,
  }) {
    if (explicitAccountHash) return;
    String? current;
    try {
      final raw = LoginDao.getAccountHash()?.trim();
      current = raw == null || raw.isEmpty ? null : raw;
    } catch (_) {}
    if (current != capturedAccountHash) {
      throw const LoginAccountChangedException();
    }
  }

  /// 文件 mutation 只在稳定账号 lease 内执行；显式账号由调用方 lease 负责。
  static Future<T> runCapturedAccountMutation<T>({
    required String capturedAccountHash,
    required bool explicitAccountHash,
    required Future<T> Function() action,
  }) {
    if (explicitAccountHash) return action();
    verifyCapturedAccount(
      capturedAccountHash: capturedAccountHash,
      explicitAccountHash: false,
    );
    return LoginDao.runWithStableAccount(
      expectedAccountHash: capturedAccountHash,
      action: action,
    );
  }

  static String tokenFor(String accountHash) {
    final normalized = accountHash.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(accountHash, 'accountHash', '账号标识不能为空');
    }
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  static Directory legacyRoot({
    required Directory base,
    required String resourceDirectoryName,
  }) =>
      Directory('${base.path}/$resourceDirectoryName');

  static Directory scopedDirectory({
    required Directory base,
    required String resourceDirectoryName,
    String? accountHash,
  }) {
    final resolved = currentAccountHash(accountHash);
    return Directory(
      '${base.path}/$resourceDirectoryName/$accountsDirectoryName/'
      '${tokenFor(resolved)}',
    );
  }

  static bool isDirectChild(File file, Directory directory) =>
      file.absolute.parent.path == directory.absolute.path;

  /// 逐级检查托管目录，不跟随任何符号链接。
  ///
  /// [relativeSegments] 必须是已拆分的单级安全路径；缺失项允许存在，便于写入前
  /// 先检查再创建。调用方在异步 I/O 后应再次检查，以缩小 TOCTOU 窗口。
  static Future<void> ensureNoLinks({
    required Directory root,
    Iterable<String> relativeSegments = const [],
  }) async {
    var currentPath = root.path;
    await _rejectLink(currentPath);
    for (final segment in relativeSegments) {
      _validateSegment(segment);
      currentPath = '$currentPath${Platform.pathSeparator}$segment';
      await _rejectLink(currentPath);
    }
  }

  /// 在托管根目录下逐级创建普通目录；任何已存在的 Link/文件都会失败。
  static Future<Directory> createManagedDirectory({
    required Directory root,
    Iterable<String> relativeSegments = const [],
    void Function()? beforeMutation,
  }) async {
    var current = root;
    await _ensureDirectory(current, beforeMutation: beforeMutation);
    for (final segment in relativeSegments) {
      _validateSegment(segment);
      current = Directory(
        '${current.path}${Platform.pathSeparator}$segment',
      );
      await _ensureDirectory(current, beforeMutation: beforeMutation);
    }
    return current;
  }

  /// 文件父目录与托管目录必须解析到同一个真实目录。
  static Future<bool> isCanonicalDirectChild(
    File file,
    Directory directory,
  ) async {
    try {
      final expected = await directory.resolveSymbolicLinks();
      final actual = await file.parent.resolveSymbolicLinks();
      return actual == expected;
    } on FileSystemException {
      return false;
    }
  }

  /// 已存在实体解析后的真实路径必须仍位于托管根目录内。
  static Future<bool> isCanonicalWithin(
    FileSystemEntity entity,
    Directory root,
  ) async {
    try {
      final rootPath = await root.resolveSymbolicLinks();
      final entityPath = await entity.resolveSymbolicLinks();
      final prefix = rootPath.endsWith(Platform.pathSeparator)
          ? rootPath
          : '$rootPath${Platform.pathSeparator}';
      return entityPath == rootPath || entityPath.startsWith(prefix);
    } on FileSystemException {
      return false;
    }
  }

  static Future<void> _ensureDirectory(Directory directory,
      {void Function()? beforeMutation}) async {
    final before = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (before == FileSystemEntityType.link) {
      throw FileSystemException(
          'managed path must not be a link', directory.path);
    }
    if (before != FileSystemEntityType.notFound &&
        before != FileSystemEntityType.directory) {
      throw FileSystemException(
        'managed directory path is not a directory',
        directory.path,
      );
    }
    if (before == FileSystemEntityType.notFound) {
      beforeMutation?.call();
      await directory.create(recursive: true);
    }
    final after = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (after != FileSystemEntityType.directory) {
      throw FileSystemException(
        'managed directory path is not a regular directory',
        directory.path,
      );
    }
  }

  static Future<void> _rejectLink(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw FileSystemException('managed path must not be a link', path);
    }
  }

  static void _validateSegment(String segment) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains('\\')) {
      throw ArgumentError.value(segment, 'segment', '托管路径分段不合法');
    }
  }
}
