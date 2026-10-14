import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chatgpt_app_core/chat/application/deepseek_file_service.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 对话发送前将 inline 图片上传成 DeepSeek file_id。
/// 缓存只活在同一个直连服务实例中，不落库；切换 key / host 时实例随服务重建。
class DeepSeekAttachmentAdapter {
  static const _maxCachedFiles = 128;
  static final _liveAdapters = <WeakReference<DeepSeekAttachmentAdapter>>{};
  late final DeepSeekFileService _files;
  final String _cacheScope;
  final LinkedHashMap<String, String> _uploaded = LinkedHashMap();
  final Set<String> _deletedDuringPreparation = {};
  int _activePreparations = 0;

  DeepSeekAttachmentAdapter({
    required String chatCompletionsUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 90),
    Future<void> Function(DeepSeekUploadedFile file, Uint8List bytes)?
        onUploaded,
  }) : _cacheScope = _scopeFor(chatCompletionsUrl, apiKey) {
    _files = DeepSeekFileService(
      chatCompletionsUrl: chatCompletionsUrl,
      apiKey: apiKey,
      client: client,
      timeout: timeout,
      onUploaded: (file, bytes) async {
        _checkDeletedFile(file.id);
        await onUploaded?.call(file, bytes);
        _checkDeletedFile(file.id);
      },
    );
    _liveAdapters.removeWhere((reference) => reference.target == null);
    _liveAdapters.add(WeakReference(this));
  }

  /// 云端删除成功后清除同一服务地址和 key 的缓存，下次发送从原图重新上传。
  /// 只保存作用域摘要与弱引用，不在全局保留服务实例或明文凭据。
  static void invalidateFile({
    required String chatCompletionsUrl,
    required String apiKey,
    required String fileId,
  }) {
    final scope = _scopeFor(chatCompletionsUrl, apiKey);
    _liveAdapters.removeWhere((reference) {
      final adapter = reference.target;
      if (adapter == null) return true;
      if (adapter._cacheScope == scope) {
        adapter._uploaded.removeWhere((_, id) => id == fileId);
        // 删除与准备消息并发时，迟到的上传响应也不能重新发布已删除 ID。
        if (adapter._activePreparations > 0) {
          adapter._deletedDuringPreparation.add(fileId);
        }
      }
      return false;
    });
  }

  static String _scopeFor(String chatCompletionsUrl, String apiKey) => sha256
      .convert(utf8.encode(
          '${DeepSeekFileService.filesEndpointFor(chatCompletionsUrl)}\u0000${apiKey.trim()}'))
      .toString();

  Future<List<Map<String, dynamic>>> prepareMessages(
    List<Map<String, dynamic>> messages, {
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    Future<void> Function()? beforeUpload,
  }) async {
    _activePreparations++;
    try {
      final prepared = await _prepareMessages(messages,
          abortTrigger: abortTrigger,
          onProgress: onProgress,
          beforeUpload: beforeUpload);
      // 某一张图已处理完但请求仍在等待其他附件时，也要阻止使用被删除的 ID。
      for (final message in prepared) {
        final content = message['content'];
        if (message['role'] != 'user' || content is! List) continue;
        for (final part in content) {
          if (part is Map && part['type'] == 'file') {
            _checkDeletedFile(part['file_id']);
          }
        }
      }
      return prepared;
    } finally {
      _activePreparations--;
      if (_activePreparations == 0) _deletedDuringPreparation.clear();
    }
  }

  void _checkDeletedFile(dynamic id) {
    if (_deletedDuringPreparation.contains(id)) {
      throw const DeepSeekFileException('图片云端文件刚被删除，请重新发送以重新上传');
    }
  }

  /// 成功上传回调的异步缓存写入也必须避开本轮刚删除的文件。
  bool isFileDeleted(String fileId) =>
      _deletedDuringPreparation.contains(fileId);

  Future<List<Map<String, dynamic>>> _prepareMessages(
    List<Map<String, dynamic>> messages, {
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    Future<void> Function()? beforeUpload,
  }) async {
    var aborted = false;
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) => aborted = true));
      await Future<void>.value();
    }
    void checkAbort() {
      if (aborted) throw http.RequestAbortedException();
    }

    checkAbort();
    final prepared = <Map<String, dynamic>>[];
    final totalImages = messages.fold<int>(0, (total, message) {
      final content = message['content'];
      if (message['role'] != 'user' || content is! List) return total;
      return total + content.where(_hasInlineImage).length;
    });
    var imageIndex = 0;
    for (final message in messages) {
      checkAbort();
      final copy = Map<String, dynamic>.from(message);
      final content = message['content'];
      if (message['role'] == 'user' && content is List) {
        final parts = <dynamic>[];
        for (final part in content) {
          checkAbort();
          final index = _hasInlineImage(part) ? ++imageIndex : imageIndex;
          parts.add(part is Map
              ? await _preparePart(
                  Map<String, dynamic>.from(part),
                  abortTrigger: abortTrigger,
                  beforeUpload: beforeUpload,
                  onProgress: onProgress == null
                      ? null
                      : (progress) {
                          reportChatSendProgress(
                              onProgress,
                              ChatSendProgress(progress.label,
                                  fileName: progress.fileName,
                                  index: index,
                                  total: totalImages,
                                  completedBytes: progress.completedBytes,
                                  totalBytes: progress.totalBytes));
                        },
                )
              : part);
          checkAbort();
        }
        copy['content'] = parts;
      }
      prepared.add(copy);
    }
    checkAbort();
    return prepared;
  }

  Future<Map<String, dynamic>> _preparePart(
    Map<String, dynamic> part, {
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    Future<void> Function()? beforeUpload,
  }) async {
    String? dataUri;
    String? filename;
    if (part['type'] == 'image_url') {
      final image = part['image_url'];
      final url = image is Map ? image['url'] : null;
      if (url is! String) {
        throw const FormatException('DeepSeek 图片附件缺少 URL');
      }
      if (url.startsWith('data:')) {
        dataUri = url;
      } else {
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !(uri.isScheme('https') || uri.isScheme('http')) ||
            uri.host.isEmpty) {
          throw const FormatException('DeepSeek 图片地址必须是 HTTP(S) URL');
        }
        if (url.length > 8192) {
          throw const FormatException('DeepSeek 图片 URL 最多允许 8192 个字符');
        }
      }
    } else if (part['type'] == 'file') {
      // 通用附件采用 OpenAI 的嵌套 file；DeepSeek 的 file 字段是平铺的。
      final file = part['file'] is Map ? part['file'] as Map : part;
      final value = file['file_data'];
      if (value is String && value.startsWith('data:image/')) {
        dataUri = value;
        filename = file['filename'] as String?;
      } else if (file['file_id'] is String) {
        return {'type': 'file', 'file_id': file['file_id']};
      } else if (value != null) {
        throw const FormatException('DeepSeek Files API 仅支持图片，PDF / 文本请抽取正文');
      }
    }
    if (dataUri == null) return part;

    final bytes = DeepSeekFileService.imageBytesForDataUri(dataUri);
    // 不把 data URI 留在 cache，避免多轮会话保留大份图片副本。
    final hash = sha256.convert(bytes).toString();
    var id = _uploaded.remove(hash);
    if (id == null) {
      await beforeUpload?.call();
      final uploaded = await _files.uploadImageBytes(
        bytes,
        filename: filename,
        abortTrigger: abortTrigger,
        onProgress: onProgress,
      );
      id = uploaded.id;
    }
    _checkDeletedFile(id);
    _uploaded[hash] = id;
    if (_uploaded.length > _maxCachedFiles) {
      _uploaded.remove(_uploaded.keys.first);
    }
    return {'type': 'file', 'file_id': id};
  }

  static bool _hasInlineImage(dynamic part) {
    if (part is! Map) return false;
    if (part['type'] == 'image_url') {
      final image = part['image_url'];
      return image is Map &&
          image['url'] is String &&
          (image['url'] as String).startsWith('data:');
    }
    if (part['type'] == 'file') {
      final file = part['file'] is Map ? part['file'] as Map : part;
      final data = file['file_data'];
      return data is String && data.startsWith('data:image/');
    }
    return false;
  }
}
