import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';

/// 请求用途。普通聊天与翻译可以在同一网络层使用不同的可靠性策略。
enum ChatRequestProfile { standard, translation }

/// 请求对模型推理控制的处理方式。
enum ChatReasoningPolicy { providerDefault, offIfSupported }

int? validateMaxOutputTokensOverride(int? value) {
  if (value != null && value <= 0) {
    throw ArgumentError.value(
      value,
      'maxOutputTokensOverride',
      '必须大于 0',
    );
  }
  return value;
}

/// 单次聊天请求的不可变选项。
final class ChatRequestOptions {
  final ChatRequestProfile profile;
  final ChatReasoningPolicy reasoningPolicy;

  /// 单次请求覆盖设置中的等级；null 沿用设置（旧设置仍跟随服务端默认）。
  final DeepSeekReasoningEffort? deepSeekReasoningEffort;
  final Future<void>? abortTrigger;
  final Duration connectTimeout;
  final int? minOutputTokens;
  final bool suppressReasoningControl;
  final int? maxOutputTokensOverride;
  final ChatSendProgressCallback? onProgress;

  const ChatRequestOptions({
    this.profile = ChatRequestProfile.standard,
    this.reasoningPolicy = ChatReasoningPolicy.providerDefault,
    this.deepSeekReasoningEffort,
    this.abortTrigger,
    this.connectTimeout = const Duration(seconds: 20),
    this.minOutputTokens,
    this.suppressReasoningControl = false,
    this.maxOutputTokensOverride,
    this.onProgress,
  }) : assert(
          maxOutputTokensOverride == null || maxOutputTokensOverride > 0,
        );
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
