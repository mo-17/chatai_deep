import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/assistant_role_card_service.dart';
import 'package:path_provider/path_provider.dart';

typedef RoleCardAssetDirectoryResolver = Future<Directory> Function();

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
  }) async {
    final base =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    final directory = Directory(
      '${base.path}/$directoryName/$assistantId',
    );
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    final manifest = <Map<String, dynamic>>[];
    var totalBytes = 0;
    for (final entry in resources.take(maxAssets).toList().asMap().entries) {
      final resource = entry.value;
      final bytes = resource.bytes;
      String localPath = '';
      if (bytes != null &&
          bytes.isNotEmpty &&
          bytes.length <= maxAssetBytes &&
          totalBytes + bytes.length <= maxTotalBytes) {
        final filename = _filename(entry.key, resource);
        final file = File('${directory.path}/$filename');
        await file.writeAsBytes(bytes, flush: true);
        localPath = file.path;
        totalBytes += bytes.length;
      }
      manifest.add({
        ...resource.toJson(),
        'localPath': localPath,
      });
    }
    return jsonEncode(manifest);
  }

  static Future<List<AssistantRoleCardResource>> load(
    String raw, {
    RoleCardAssetDirectoryResolver? directoryResolver,
  }) async {
    if (raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final resources = <AssistantRoleCardResource>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final json = Map<String, dynamic>.from(item);
      final localPath = json['localPath'] as String? ?? '';
      List<int>? bytes;
      if (localPath.isNotEmpty) {
        var file = File(localPath);
        if (!await file.exists()) {
          final suffix = managedSuffix(localPath);
          if (suffix != null) {
            final base =
                await (directoryResolver ?? getApplicationDocumentsDirectory)();
            file = File('${base.path}/$directoryName/$suffix');
          }
        }
        if (await file.exists()) bytes = await file.readAsBytes();
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
    return resources;
  }

  static String? managedSuffix(String path) {
    const marker = '/$directoryName/';
    final index = path.indexOf(marker);
    if (index < 0) return null;
    final suffix = path.substring(index + marker.length).trim();
    return suffix.isEmpty ? null : suffix;
  }

  static Future<void> delete({
    required int assistantId,
    RoleCardAssetDirectoryResolver? directoryResolver,
  }) async {
    final base =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    final directory = Directory('${base.path}/$directoryName/$assistantId');
    if (await directory.exists()) await directory.delete(recursive: true);
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
