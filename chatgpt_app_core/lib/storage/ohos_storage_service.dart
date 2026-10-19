import 'dart:io';
import 'package:flutter/services.dart';
import 'local_media_references.dart';

class StorageCandidate {
  final String path, name, kind;
  final int bytes, created;
  const StorageCandidate(
      this.path, this.name, this.kind, this.bytes, this.created);
}

class OhosStorageInventory {
  final String token;
  final List<StorageCandidate> entries;
  final int fileBytes, imageBytes;
  const OhosStorageInventory(
      this.token, this.entries, this.fileBytes, this.imageBytes);
  static int _integer(Object? value) {
    if (value is! num ||
        !value.isFinite ||
        value < 0 ||
        value > 9007199254740991 ||
        value != value.toInt()) {
      throw const FormatException('存储统计无效');
    }
    return value.toInt();
  }

  factory OhosStorageInventory.parse(Object? value) {
    if (value is! Map ||
        value['token'] is! String ||
        (value['token'] as String).isEmpty ||
        (value['token'] as String).length > 100 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > 5000) {
      throw const FormatException('存储统计无效');
    }
    final entries = <StorageCandidate>[], paths = <String>{};
    for (final row in value['entries'] as List) {
      if (row is! Map ||
          row['path'] is! String ||
          row['name'] is! String ||
          !['file', 'image'].contains(row['kind'])) {
        throw const FormatException('存储条目无效');
      }
      final path = row['path'] as String, name = row['name'] as String;
      if (!path.startsWith('/') ||
          path.length > 4096 ||
          path.contains('\x00') ||
          path.contains('\\') ||
          path.split('/').any((part) => part == '..' || part == '.') ||
          path.split('/').last != name ||
          !paths.add(path) ||
          !(row['kind'] == 'file'
                  ? RegExp(r'^(?:tree_)?[0-9]+_[0-9]+$')
                  : RegExp(r'^image_[0-9]+_[0-9]+\.(png|jpg)$'))
              .hasMatch(name)) {
        throw const FormatException('存储路径无效');
      }
      entries.add(StorageCandidate(path, name, row['kind'] as String,
          _integer(row['bytes']), _integer(row['created'])));
    }
    return OhosStorageInventory(
        value['token'] as String,
        List.unmodifiable(entries),
        _integer(value['fileBytes']),
        _integer(value['imageBytes']));
  }
}

class StorageCleanupResult {
  final int removed, bytes, retained;
  const StorageCleanupResult(this.removed, this.bytes, this.retained);
}

class OhosStorageService {
  static const channel = MethodChannel('com.hzb.flutter_ai/file_picker');
  static final shared = OhosStorageService();
  static bool get isSupported => Platform.operatingSystem == 'ohos';
  final LocalMediaReferences references;
  bool _busy = false;
  OhosStorageService({LocalMediaReferences? references})
      : references = references ?? LocalMediaReferences();

  Future<OhosStorageInventory> inspect({bool images = true}) async =>
      OhosStorageInventory.parse(await channel
          .invokeMethod<Object?>('storageInventory', {'images': images}));

  Future<StorageCleanupResult> clean(
      {bool images = true,
      bool manual = false,
      bool Function()? isCurrent}) async {
    if (_busy) throw StateError('存储正在检查，请稍后重试');
    _busy = true;
    try {
      final inventory = await inspect(images: images);
      if (inventory.entries.isEmpty) return const StorageCleanupResult(0, 0, 0);
      final now = DateTime.now().millisecondsSinceEpoch;
      final candidates = inventory.entries
          .where((entry) =>
              now - entry.created >=
              (entry.kind == 'image'
                      ? const Duration(days: 7)
                      : manual
                          ? Duration.zero
                          : const Duration(days: 1))
                  .inMilliseconds)
          .toList();
      if (candidates.isEmpty) {
        return StorageCleanupResult(0, 0, inventory.entries.length);
      }
      final names = await references.collect(candidates);
      // 扫描期间刚跨过过期边界的文件仍需保留，不能被当作已核对。
      names.addAll(inventory.entries
          .where((entry) => !candidates.contains(entry))
          .map((entry) => entry.name));
      if (isCurrent?.call() == false) throw StateError('账号已变化，请重新打开存储管理');
      final raw = await channel.invokeMethod<Object?>('cleanupStorage', {
        'token': inventory.token,
        'referenced': names.toList(),
        'manual': manual,
      });
      if (raw is! Map) throw const FormatException('存储清理结果无效');
      return StorageCleanupResult(
          OhosStorageInventory._integer(raw['removed']),
          OhosStorageInventory._integer(raw['bytes']),
          OhosStorageInventory._integer(raw['retained']));
    } finally {
      _busy = false;
    }
  }

  /// 选择前仅自动回收过期、无引用副本。核对失败不删除；原生配额仍独立生效。
  Future<void> prepareSelection() async {
    try {
      await clean();
    } catch (_) {/* 无完整证明就保留现有文件，选择仍受原生配额约束。 */}
  }
}
