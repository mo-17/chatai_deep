import 'package:login_sdk/platform/app_io.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:chatgpt_app_core/chat/domain/attachment_processing_limits.dart';
import 'package:chatgpt_app_core/util/bounded_file_reader.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';

/// 一轮图片与文件共享的资源预算；数量不设上限，字节和正文不能静默丢弃。
final class AttachmentBatchBudget {
  final AttachmentProcessingLimits limits;
  final bool _enforceLimits;
  final Map<String, String> expectedDigests;
  final Future<AttachmentBatchSnapshot> Function(File source, int maxBytes)?
      _snapshotFile;
  int _usedBytes = 0;
  int _usedTextCharacters = 0;

  AttachmentBatchBudget(
      {AttachmentProcessingLimits limits = const AttachmentProcessingLimits(),
      Map<String, String> expectedDigests = const {},
      Future<AttachmentBatchSnapshot> Function(File source, int maxBytes)?
          snapshotFile})
      : expectedDigests = Map.unmodifiable(expectedDigests),
        _snapshotFile = snapshotFile,
        limits = limits.normalized,
        _enforceLimits = true;

  /// 仅用于已保存消息恢复；单文件读取边界仍由每个处理器执行。
  AttachmentBatchBudget.forHistoricalRetry()
      : expectedDigests = const {},
        _snapshotFile = null,
        limits = const AttachmentProcessingLimits(),
        _enforceLimits = false;

  int get usedBytes => _usedBytes;
  int get usedTextCharacters => _usedTextCharacters;
  int get remainingBytes => _enforceLimits
      ? limits.maxTotalFileBytes - _usedBytes
      : int.parse('9223372036854775807');

  /// 只读 stat，不读内容、不占用预算；共享调用方可先预检图片与文件的并集。
  Future<void> preflightPaths(Iterable<String> paths,
      {bool Function()? isCancelled}) async {
    var additionalBytes = 0;
    for (final path in paths) {
      await _checkpoint(isCancelled);
      if (await appFileType(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('附件不存在或不是普通文件');
      }
      additionalBytes += await appFile(path).length();
      _checkBytes(additionalBytes);
    }
    await _checkpoint(isCancelled);
  }

  void consumeBytes(int bytes) {
    if (bytes < 0) throw ArgumentError.value(bytes, 'bytes', '不能小于 0');
    _checkBytes(bytes);
    _usedBytes += bytes;
  }

  void consumeText(String text) {
    final next = _usedTextCharacters + text.length;
    if (_enforceLimits && next > limits.maxTotalTextChars) {
      throw AttachmentBatchLimitException.text(
          used: next, limit: limits.maxTotalTextChars);
    }
    _usedTextCharacters = next;
  }

  /// 清单的保守预留只可替换为更短的真实清单；不会用估计值放行超限内容。
  void replaceTextReservation(int reservedCharacters, String actualText) {
    if (reservedCharacters < actualText.length ||
        reservedCharacters > _usedTextCharacters) {
      throw StateError('附件清单实际长度超过预留预算');
    }
    _usedTextCharacters -= reservedCharacters - actualText.length;
  }

  /// 读取时同时应用单文件上限与剩余聚合上限，再以实际字节确认预算。
  Future<Uint8List> readFileBytes(File file,
      {required int maxBytes, String label = '附件'}) async {
    _checkBytes(await file.length());
    final readLimit = maxBytes < remainingBytes ? maxBytes : remainingBytes;
    final bytes = await _withReadLimit(
        () => readFileBytesBounded(file, maxBytes: readLimit, label: label),
        singleLimit: maxBytes,
        readLimit: readLimit);
    consumeBytes(bytes.length);
    return bytes;
  }

  /// 解析使用托管副本，避免先保存一个版本、再从原路径解析另一个版本。
  Future<AttachmentBatchSnapshot> snapshotFile(File source,
      {required int maxBytes}) async {
    _checkBytes(await source.length());
    final readLimit = maxBytes < remainingBytes ? maxBytes : remainingBytes;
    if (_snapshotFile != null) {
      final snapshot = await _snapshotFile(source, readLimit);
      if (snapshot.bytes.length > readLimit) {
        throw const FormatException('附件快照超过读取上限');
      }
      final expected = expectedDigests[source.path];
      if (expected != null &&
          sha256.convert(snapshot.bytes).toString() != expected) {
        throw const FormatException('引用快照校验失败，请重新选择');
      }
      consumeBytes(snapshot.bytes.length);
      return snapshot;
    }
    final path = await _withReadLimit(
        () => ManagedAttachmentStore.importFile(source, maxBytes: readLimit),
        singleLimit: maxBytes,
        readLimit: readLimit);
    final bytes = await readFileBytes(appFile(path), maxBytes: maxBytes);
    final expected = expectedDigests[source.path];
    if (expected != null && sha256.convert(bytes).toString() != expected) {
      throw const FormatException('引用快照校验失败，请重新选择');
    }
    return AttachmentBatchSnapshot(path: path, bytes: bytes);
  }

  Future<T> _withReadLimit<T>(Future<T> Function() operation,
      {required int singleLimit, required int readLimit}) async {
    try {
      return await operation();
    } on FormatException catch (error) {
      if (remainingBytes <= singleLimit &&
          error.message.toString().contains('过大')) {
        throw AttachmentBatchLimitException.bytes(
            used: _usedBytes + readLimit + 1, limit: limits.maxTotalFileBytes);
      }
      rethrow;
    }
  }

  void _checkBytes(int additional) {
    final next = _usedBytes + additional;
    if (_enforceLimits && next > limits.maxTotalFileBytes) {
      throw AttachmentBatchLimitException.bytes(
          used: next, limit: limits.maxTotalFileBytes);
    }
  }

  static Future<void> _checkpoint(bool Function()? isCancelled) async {
    await Future<void>.delayed(Duration.zero);
    if (isCancelled?.call() == true) {
      throw const AttachmentProcessingCancelledException();
    }
  }
}

final class AttachmentBatchSnapshot {
  final String path;
  final Uint8List bytes;
  const AttachmentBatchSnapshot({required this.path, required this.bytes});
}

final class AttachmentBatchLimitException implements Exception {
  final String message;
  final int used;
  final int limit;

  AttachmentBatchLimitException.bytes({required this.used, required this.limit})
      : message = '本轮附件总大小超过上限（已用 ${_mib(used)}，上限 ${_mib(limit)}）。'
            '请减少附件，或到「我的 → AI 服务设置」调整「每轮附件总大小上限」。';

  AttachmentBatchLimitException.text({required this.used, required this.limit})
      : message = '本轮附件总字数超过上限（已用 ${_characters(used)} 字符，'
            '上限 ${_characters(limit)} 字符）。'
            '请拆分附件，或到「我的 → AI 服务设置」调整「每轮附件总字数上限」。';

  @override
  String toString() => message;

  static String _mib(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';

  static String _characters(int count) =>
      count >= 10000 && count % 10000 == 0 ? '${count ~/ 10000}万' : '$count';
}

final class AttachmentProcessingCancelledException implements Exception {
  const AttachmentProcessingCancelledException();

  @override
  String toString() => '附件处理已取消';
}
