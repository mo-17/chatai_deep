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
