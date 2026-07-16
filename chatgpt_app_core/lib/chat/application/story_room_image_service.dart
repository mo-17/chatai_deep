import 'dart:convert';

import 'package:chatgpt_app_core/capability/generated_image_save_service.dart';
import 'package:chatgpt_app_core/capability/product_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/account_resource_scope.dart';
import 'package:http/http.dart' as http;

enum StoryRoomImageSourceKind { url, dataUri, localPath }

/// 已校验、可交给图片保存层处理的房间图片来源。
class StoryRoomImageSource {
  final String value;
  final StoryRoomImageSourceKind kind;
  final String mimeType;
  final String extension;
  final String suggestedFilename;

  const StoryRoomImageSource({
    required this.value,
    required this.kind,
    required this.mimeType,
    required this.extension,
    required this.suggestedFilename,
  });

  static StoryRoomImageSource? fromEvent(StreamEvent event) {
    if (event.type != StreamEventType.image) return null;
    return normalize(event.imageUrl);
  }

  static StoryRoomImageSource? normalize(String? raw) {
    final input = raw?.trim() ?? '';
    if (input.isEmpty || input.contains('\u0000')) return null;

    final dataMatch = RegExp(
      r'^data:(image/[a-z0-9.+-]+);base64,(.*)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(input);
    if (dataMatch != null) {
      final mimeType = dataMatch.group(1)!.toLowerCase();
      final payload = dataMatch.group(2)!.replaceAll(RegExp(r'\s+'), '');
      try {
        final normalizedPayload = base64.normalize(payload);
        base64Decode(normalizedPayload);
        final extension = _extensionForMime(mimeType);
        return StoryRoomImageSource(
          value: 'data:$mimeType;base64,$normalizedPayload',
          kind: StoryRoomImageSourceKind.dataUri,
          mimeType: mimeType,
          extension: extension,
          suggestedFilename: 'generated$extension',
        );
      } on FormatException {
        return null;
      }
    }

    final uri = Uri.tryParse(input);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      if (uri!.host.isEmpty) return null;
      final value = input.substring(input.indexOf(':') + 1);
      final canonical = '$scheme:$value';
      final filename = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      final extension = _extensionOf(filename) ?? '.png';
      return StoryRoomImageSource(
        value: canonical,
        kind: StoryRoomImageSourceKind.url,
        mimeType: _mimeTypeForExtension(extension),
        extension: extension,
        suggestedFilename: filename.isEmpty ? 'generated$extension' : filename,
      );
    }

    final isWindowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(input);
    if (scheme.isNotEmpty && scheme != 'file' && !isWindowsPath) return null;

    final String localPath;
    if (scheme == 'file') {
      if (uri == null) return null;
      try {
        localPath = uri.toFilePath();
      } on FormatException {
        return null;
      }
    } else {
      localPath = input;
    }
    final filename = _basename(localPath);
    final extension = _extensionOf(filename) ?? '.png';
    return StoryRoomImageSource(
      value: localPath,
      kind: StoryRoomImageSourceKind.localPath,
      mimeType: _mimeTypeForExtension(extension),
      extension: extension,
      suggestedFilename: filename.isEmpty ? 'generated$extension' : filename,
    );
  }

  static String safeFilename(String? candidate, {String extension = '.png'}) {
    final fallbackExtension = _normalizeExtension(extension);
    final name = _basename(candidate?.trim() ?? '');
    final dot = name.lastIndexOf('.');
    final candidateExtension = dot > 0 ? name.substring(dot).toLowerCase() : '';
    final outputExtension = _imageExtensions.contains(candidateExtension)
        ? candidateExtension
        : fallbackExtension;
    final stem = dot > 0 ? name.substring(0, dot) : name;
    var safeStem = stem
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^[_\.]+|[_\.]+$'), '');
    if (safeStem.isEmpty) safeStem = 'generated_image';
    if (safeStem.length > 80) safeStem = safeStem.substring(0, 80);
    return '$safeStem$outputExtension';
  }

  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
  };

  static String _basename(String path) {
    final parts =
        path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  static String? _extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0 || dot == filename.length - 1) return null;
    final extension = '.${filename.substring(dot + 1).toLowerCase()}';
    return _imageExtensions.contains(extension) ? extension : null;
  }

  static String _extensionForMime(String mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return '.jpg';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      default:
        return '.png';
    }
  }

  static String _mimeTypeForExtension(String extension) {
    switch (extension) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      default:
        return 'image/png';
    }
  }

  static String _normalizeExtension(String extension) {
    final normalized = extension.startsWith('.') ? extension : '.$extension';
    return _imageExtensions.contains(normalized.toLowerCase())
        ? normalized.toLowerCase()
        : '.png';
  }
}

class StoryRoomSavedImage {
  final String path;
  final String source;
  final StoryRoomImageSourceKind sourceKind;

  const StoryRoomSavedImage({
    required this.path,
    required this.source,
    required this.sourceKind,
  });

  /// 将本地路径和原始来源写入消息，供 StoryRoomDao 的 JSON 列持久化。
  void attachTo(StoryMessageModel message) {
    if (!message.imagePaths.contains(path)) {
      message.imagePaths = [...message.imagePaths, path];
    }
    if (source.isNotEmpty && !message.imageSources.contains(source)) {
      message.imageSources = [...message.imageSources, source];
    }
  }
}

class StoryRoomImageService {
  const StoryRoomImageService();

  static StoryRoomImageSource? normalize(StreamEvent event) =>
      StoryRoomImageSource.fromEvent(event);

  static Future<StoryRoomSavedImage?> saveEvent(
    StreamEvent event, {
    String? filename,
    DateTime? now,
    ImageSaveDirectoryResolver? directoryResolver,
    http.Client? client,
    String? accountHash,
  }) async {
    final explicitAccountHash =
        AccountResourceScope.hasExplicitAccountHash(accountHash);
    final resolvedAccountHash =
        AccountResourceScope.currentAccountHash(accountHash);
    final source = normalize(event);
    if (source == null) return null;
    final safeName = StoryRoomImageSource.safeFilename(
      filename ?? 'story_${now ?? DateTime.now()}_${source.suggestedFilename}',
      extension: source.extension,
    );
    final path = await GeneratedImageSaveService.saveToAppAlbum(
      GeneratedImageSavePlan(
        source: source.value,
        albumName: 'ChatAI Deep',
        filename: safeName,
        needsPhotoPermission: false,
      ),
      directoryResolver: directoryResolver,
      client: client,
      accountHash: explicitAccountHash ? resolvedAccountHash : null,
    );
    AccountResourceScope.verifyCapturedAccount(
      capturedAccountHash: resolvedAccountHash,
      explicitAccountHash: explicitAccountHash,
    );
    return StoryRoomSavedImage(
      path: path,
      source: source.value,
      sourceKind: source.kind,
    );
  }
}
