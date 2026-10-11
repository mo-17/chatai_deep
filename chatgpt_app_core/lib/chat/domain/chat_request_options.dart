import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';

/// 请求用途。普通聊天与翻译可以在同一网络层使用不同的可靠性策略。
enum ChatRequestProfile { standard, translation }

/// 请求对模型推理控制的处理方式。
enum ChatReasoningPolicy { providerDefault, offIfSupported }

enum ChatFailureStage { prepare, connect, response, decode, unknown }

enum ChatFailureKind {
  transport,
  httpStatus,
  timeout,
  cancelled,
  invalidPayload,
  invalidConfiguration,
  state,
  range,
  type,
  unknown
}

/// 传入不含动态记忆的附件准备结果；每次真正发起聊天请求前重新构造副本。
/// 上传结果只准备一次，重试不能复用上一次解析出的账号数据。
typedef ChatAttemptMessagesResolver = Future<List<Map<String, dynamic>>>
    Function(List<Map<String, dynamic>> preparedMessages);

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

  /// null：普通请求最多额外两次；翻译由自身恢复策略负责，避免叠加重试。
  final int? maxAutoRetries;
  final Duration retryBaseDelay;
  final Duration maxRetryDelay;
  final void Function(ChatRequestRetry retry)? onRetry;
  final ChatAttemptMessagesResolver? messagesForAttempt;

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
    this.maxAutoRetries,
    this.retryBaseDelay = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 5),
    this.onRetry,
    this.messagesForAttempt,
  }) : assert(
          maxOutputTokensOverride == null || maxOutputTokensOverride > 0,
        );

  Future<List<Map<String, dynamic>>> resolveAttemptMessages(
      List<Map<String, dynamic>> preparedMessages) async {
    var aborted = false;
    abortTrigger?.then<void>((_) => aborted = true,
        onError: (Object _, StackTrace __) => aborted = true);
    await Future<void>.value();
    void check() {
      if (aborted) {
        throw const ChatTransportException(
            safeCode: 'cancelled',
            safeMessage: '请求已取消',
            failureKind: ChatFailureKind.cancelled);
      }
    }

    check();
    final messages = await (messagesForAttempt?.call(preparedMessages) ??
        Future.value(preparedMessages));
    check();
    return messages;
  }
}

/// 聊天传输层对上暴露的安全失败信息。
///
/// 只保存重试/分类所需的状态、退避和稳定代码，不携带响应正文、请求地址或凭据。
final class ChatTransportException implements Exception {
  final int? statusCode;
  final Duration? retryAfter;
  final String safeCode;
  final String safeMessage;

  /// 已收到成功响应的任意字节，包括尚未组成可见事件的工具分片。
  final bool responseStarted;
  final ChatFailureStage failureStage;
  final ChatFailureKind failureKind;

  const ChatTransportException({
    this.statusCode,
    this.retryAfter,
    required this.safeCode,
    required this.safeMessage,
    this.responseStarted = false,
    this.failureStage = ChatFailureStage.unknown,
    this.failureKind = ChatFailureKind.unknown,
  });

  @override
  String toString() => 'ChatTransportException($safeCode): $safeMessage';
}

final class ChatRequestRetry {
  final int attempt;
  final int maxRetries;
  final Duration delay;
  final String safeCode;
  const ChatRequestRetry(
      {required this.attempt,
      required this.maxRetries,
      required this.delay,
      required this.safeCode});
}
