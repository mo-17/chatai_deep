import 'package:crypto/crypto.dart';

final class BackupEntryDigest {
  static const int currentSchemaVersion = 1;
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  final String sha256;
  final int bytes;
  final int schemaVersion;

  const BackupEntryDigest({
    required this.sha256,
    required this.bytes,
    required this.schemaVersion,
  });

  factory BackupEntryDigest.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('备份 entry 完整性声明格式不合法');
    }
    final value = Map<Object?, Object?>.from(raw);
    final hash = value['sha256'];
    final byteCount = value['bytes'];
    final version = value['schemaVersion'];
    if (hash is! String || !_sha256Pattern.hasMatch(hash)) {
      throw const FormatException('备份 entry SHA-256 格式不合法');
    }
    if (byteCount is! int || byteCount < 0) {
      throw const FormatException('备份 entry bytes 格式不合法');
    }
    if (version is! int || version != currentSchemaVersion) {
      throw const FormatException('备份 entry schemaVersion 不受支持');
    }
    return BackupEntryDigest(
      sha256: hash,
      bytes: byteCount,
      schemaVersion: version,
    );
  }

  Map<String, Object> toJson() => {
        'sha256': sha256,
        'bytes': bytes,
        'schemaVersion': schemaVersion,
      };
}

/// 对已经确定的原始 archive bytes 计算逐 entry 摘要。
///
/// `manifest.json` 不参与计算，避免 manifest 自引用。
Map<String, BackupEntryDigest> digestEntries(
  Map<String, List<int>> entries, {
  int schemaVersion = BackupEntryDigest.currentSchemaVersion,
}) {
  if (schemaVersion != BackupEntryDigest.currentSchemaVersion) {
    throw ArgumentError.value(
      schemaVersion,
      'schemaVersion',
      '不受支持',
    );
  }
  validateBackupEntryNames(entries.keys);
  return {
    for (final entry in entries.entries)
      if (entry.key != 'manifest.json')
        entry.key: BackupEntryDigest(
          sha256: sha256.convert(entry.value).toString(),
          bytes: entry.value.length,
          schemaVersion: schemaVersion,
        ),
  };
}

/// 校验 v11 manifest 中声明的全部 entry，任何缺失、额外或 byte 变化都拒绝。
///
/// [entries] 必须来自 archive 原始内容，而不是重新编码后的业务 JSON。
void verifyEntryDigests(
  Map<String, List<int>> entries,
  Object? manifestEntries,
) {
  validateBackupEntryNames(entries.keys);
  if (manifestEntries is! Map) {
    throw const FormatException('备份缺少 entry 完整性声明');
  }

  final declared = <String, BackupEntryDigest>{};
  for (final rawEntry in manifestEntries.entries) {
    final name = rawEntry.key;
    if (name is! String) {
      throw const FormatException('备份 entry 名称格式不合法');
    }
    validateBackupEntryNames([name]);
    if (name == 'manifest.json') {
      throw const FormatException('manifest.json 不能声明自身摘要');
    }
    if (declared.containsKey(name)) {
      throw const FormatException('备份包含重复 entry 声明');
    }
    declared[name] = BackupEntryDigest.fromJson(rawEntry.value);
  }

  final actualNames =
      entries.keys.where((name) => name != 'manifest.json').toSet();
  if (declared.length != actualNames.length ||
      !declared.keys.every(actualNames.contains)) {
    throw const FormatException('备份 entry 声明与 archive 内容不一致');
  }

  for (final name in actualNames) {
    final bytes = entries[name];
    final expected = declared[name];
    if (bytes == null || expected == null) {
      throw const FormatException('备份 entry 不完整');
    }
    if (bytes.length != expected.bytes ||
        sha256.convert(bytes).toString() != expected.sha256) {
      throw const FormatException('备份 entry 完整性校验失败');
    }
  }
}

/// 在把 archive 文件折叠为 Map 前调用，可拒绝重复文件名、
/// 大小写不敏感文件系统上的路径碰撞和路径穿越。
void validateBackupEntryNames(Iterable<String> names) {
  final seen = <String>{};
  final caseFoldedSeen = <String>{};
  for (final name in names) {
    _validateEntryName(name);
    if (!seen.add(name)) {
      throw const FormatException('备份包含重复 entry');
    }
    if (!caseFoldedSeen.add(name.toLowerCase())) {
      throw const FormatException('备份包含大小写冲突的重复 entry');
    }
  }
}

void _validateEntryName(String name) {
  if (name.isEmpty ||
      name != name.trim() ||
      name.startsWith('/') ||
      name.contains(r'\') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(name) ||
      name.codeUnits.any((value) => value < 0x20)) {
    throw const FormatException('备份 entry 路径不合法');
  }
  final segments = name.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw const FormatException('备份 entry 路径不合法');
  }
}
