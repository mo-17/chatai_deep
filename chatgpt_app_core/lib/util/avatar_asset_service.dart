import 'dart:io';

import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 会话头像资源托管：把相册临时路径复制到应用 Documents，避免原路径失效。
class AvatarAssetService {
  static const imageType = 'image';
  static const _rootDirName = 'chat_avatar';

  @visibleForTesting
  static Future<Directory> Function()? debugDocumentsDirectoryResolver;

  static Future<String> saveConversationAvatar({
    required String sourcePath,
    required int cid,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('头像文件不存在');
    }
    if (isManagedPath(sourcePath)) return sourcePath;
    final dir = await avatarDir();
    final ext = _extension(sourcePath);
    final dest = File(
        '${dir.path}/conversation_${cid}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await source.copy(dest.path);
    return dest.path;
  }

  static Future<String> saveAssistantAvatarBytes({
    required List<int> bytes,
    required String assistantName,
    String extension = '.png',
    String? accountHash,
  }) async {
    if (bytes.isEmpty) {
      throw Exception('头像文件为空');
    }
    final dir = await avatarDir(accountHash: accountHash);
    final safeName = _safeSegment(assistantName);
    final ext = extension.startsWith('.') ? extension : '.$extension';
    final dest = File(
        '${dir.path}/assistant_${safeName}_${DateTime.now().millisecondsSinceEpoch}$ext');
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  }

  static Future<String> saveAssistantAvatar({
    required String sourcePath,
    required String assistantName,
    String? accountHash,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('头像文件不存在');
    }
    if (isManagedPath(sourcePath)) return sourcePath;
    final bytes = await source.readAsBytes();
    return saveAssistantAvatarBytes(
      bytes: bytes,
      assistantName: assistantName,
      extension: _extension(sourcePath),
      accountHash: accountHash,
    );
  }

  static Future<void> deleteConversationAvatar(String? path) async {
    if (!isManagedPath(path)) return;
    try {
      final file = File(path!);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // best-effort cleanup: 文件被系统清理或权限变化时不影响主流程。
    }
  }

  static Future<void> deleteAssistantAvatar(String? path) =>
      deleteConversationAvatar(path);

  static Future<String?> resolveManagedPath(String? path) async {
    final value = path?.trim() ?? '';
    if (value.isEmpty) return null;
    final file = File(value);
    if (await file.exists()) return value;
    if (!isManagedPath(value)) return value;
    final suffix = managedSuffix(value);
    if (suffix == null) return value;
    final root = await (debugDocumentsDirectoryResolver ??
        getApplicationDocumentsDirectory)();
    final relocated = File('${root.path}/$_rootDirName/$suffix');
    return await relocated.exists() ? relocated.path : value;
  }

  static Future<Directory> avatarDir({String? accountHash}) async {
    final root = await (debugDocumentsDirectoryResolver ??
        getApplicationDocumentsDirectory)();
    final hash = _safeSegment(accountHash ?? HiDBManager.getAccountHash());
    final dir = Directory('${root.path}/$_rootDirName/$hash');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static bool isManagedPath(String? path) =>
      path != null && path.contains('/$_rootDirName/');

  static String? managedSuffix(String? path) {
    final value = path?.trim() ?? '';
    const marker = '/$_rootDirName/';
    final index = value.indexOf(marker);
    if (index < 0) return null;
    final suffix = value.substring(index + marker.length);
    return suffix.trim().isEmpty ? null : suffix;
  }

  static String _safeSegment(String raw) {
    final value = raw.trim().isEmpty ? 'default' : raw.trim();
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  }

  static String _extension(String path) {
    final lower = path.toLowerCase();
    for (final ext in const ['.jpg', '.jpeg', '.png', '.webp', '.heic']) {
      if (lower.endsWith(ext)) return ext == '.jpeg' ? '.jpg' : ext;
    }
    return '.jpg';
  }
}
