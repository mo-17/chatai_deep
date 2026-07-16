/// 请求用途。普通聊天与翻译可以在同一网络层使用不同的可靠性策略。
enum ChatRequestProfile { standard, translation }

/// 请求对模型推理控制的处理方式。
enum ChatReasoningPolicy { providerDefault, offIfSupported }

/// 单次聊天请求的不可变选项。
final class ChatRequestOptions {
  final ChatRequestProfile profile;
  final ChatReasoningPolicy reasoningPolicy;
  final Future<void>? abortTrigger;
  final Duration connectTimeout;
  final int? minOutputTokens;
  final bool suppressReasoningControl;

  const ChatRequestOptions({
    this.profile = ChatRequestProfile.standard,
    this.reasoningPolicy = ChatReasoningPolicy.providerDefault,
    this.abortTrigger,
    this.connectTimeout = const Duration(seconds: 20),
    this.minOutputTokens,
    this.suppressReasoningControl = false,
  });
}

/// 聊天传输层对上暴露的安全失败信息。
///
/// 只保存重试/分类所需的状态、退避和稳定代码，不携带响应正文、请求地址或凭据。
final class ChatTransportException implements Exception {
  final int? statusCode;
  final Duration? retryAfter;
  final String safeCode;
  final String safeMessage;

  const ChatTransportException({
    this.statusCode,
    this.retryAfter,
    required this.safeCode,
    required this.safeMessage,
  });

  @override
  String toString() => 'ChatTransportException($safeCode): $safeMessage';
}
