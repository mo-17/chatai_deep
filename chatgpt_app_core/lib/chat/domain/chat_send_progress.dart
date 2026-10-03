/// 单次发送的阶段进度。字节数仅表示 HTTP 客户端已消费的数据，
/// 不代表服务端已经确认上传；等待确认与等待回答使用无百分比的阶段。
final class ChatSendProgress {
  final String label;
  final String? fileName;
  final int index;
  final int total;
  final int? completedBytes;
  final int? totalBytes;

  const ChatSendProgress(
    this.label, {
    this.fileName,
    this.index = 0,
    this.total = 0,
    this.completedBytes,
    this.totalBytes,
  });

  double? get fraction {
    final done = completedBytes;
    final size = totalBytes;
    if (done == null || size == null || size <= 0) return null;
    return (done / size).clamp(0.0, 1.0);
  }
}

typedef ChatSendProgressCallback = void Function(ChatSendProgress progress);

/// 展示层的失效回调不能影响上传、取消与请求成功的判断。
void reportChatSendProgress(
  ChatSendProgressCallback? callback,
  ChatSendProgress progress,
) {
  try {
    callback?.call(progress);
  } catch (_) {}
}
