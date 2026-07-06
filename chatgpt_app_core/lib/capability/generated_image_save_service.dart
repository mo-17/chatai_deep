import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

typedef ImageSaveDirectoryResolver = Future<Directory> Function();

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
  }) async {
    final baseDir =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    final targetDir = Directory('${baseDir.path}/$albumDirectoryName');
    if (!targetDir.existsSync()) {
      await targetDir.create(recursive: true);
    }
    final target = File('${targetDir.path}/${plan.filename}');
    final bytes = await _readSource(plan.source, client: client);
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  static Future<List<GeneratedImageAlbumItem>> listSavedImages({
    ImageSaveDirectoryResolver? directoryResolver,
  }) async {
    final baseDir =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    final targetDir = Directory('${baseDir.path}/$albumDirectoryName');
    if (!targetDir.existsSync()) return const [];
    final items = <GeneratedImageAlbumItem>[];
    await for (final entity in targetDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!_imageExtensions.any((ext) => name.toLowerCase().endsWith(ext))) {
        continue;
      }
      final stat = await entity.stat();
      items.add(GeneratedImageAlbumItem(
        path: entity.path,
        filename: name,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
      ));
    }
    items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return items;
  }

  static Future<bool> deleteSavedImage(
    String path, {
    ImageSaveDirectoryResolver? directoryResolver,
  }) async {
    final baseDir =
        await (directoryResolver ?? getApplicationDocumentsDirectory)();
    final albumDir = Directory('${baseDir.path}/$albumDirectoryName');
    final albumPrefix = '${albumDir.absolute.path}${Platform.pathSeparator}';
    final file = File(path).absolute;
    if (!file.path.startsWith(albumPrefix)) {
      throw FileSystemException('image is outside generated album', path);
    }
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
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
