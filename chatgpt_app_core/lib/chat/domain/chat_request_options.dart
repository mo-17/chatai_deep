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

/// 仅发送前检查能给出确定证据；连接/响应异常仍保持 unknown。
enum ChatUnsentReason { configurationRevoked }

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

  /// 后端非流式单次网络响应期限；null保留chatWithUsage的15秒默认。
  /// chat显式期限沿此选项传递，仍经过原scope与dispatch检查。
  final Duration? nonStreamingTimeout;
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

  /// 最终消息已构造后、每次真实传输尝试前预留协作预算。与动态记忆独立，
  /// 不替换 messagesForAttempt，也不允许 DB 失败后继续发请求。
  final Future<void> Function(List<Map<String, dynamic>> messages)?
      beforeDispatch;
  final bool Function()? dispatchIsCurrent;

  /// 附件上传也使用原运行身份；此检查不计作聊天 dispatch。
  final Future<void> Function()? beforeAttachmentUpload;

  const ChatRequestOptions({
    this.profile = ChatRequestProfile.standard,
    this.reasoningPolicy = ChatReasoningPolicy.providerDefault,
    this.deepSeekReasoningEffort,
    this.abortTrigger,
    this.connectTimeout = const Duration(seconds: 20),
    this.nonStreamingTimeout,
    this.minOutputTokens,
    this.suppressReasoningControl = false,
    this.maxOutputTokensOverride,
    this.onProgress,
    this.maxAutoRetries,
    this.retryBaseDelay = const Duration(milliseconds: 500),
    this.maxRetryDelay = const Duration(seconds: 5),
    this.onRetry,
    this.messagesForAttempt,
    this.beforeDispatch,
    this.dispatchIsCurrent,
    this.beforeAttachmentUpload,
  }) : assert(
          maxOutputTokensOverride == null || maxOutputTokensOverride > 0,
        );

  ChatRequestOptions copyWith({
    int? maxAutoRetries,
    Future<void>? abortTrigger,
    ChatSendProgressCallback? onProgress,
    ChatAttemptMessagesResolver? messagesForAttempt,
    bool clearMessagesForAttempt = false,
  }) =>
      ChatRequestOptions(
          profile: profile,
          reasoningPolicy: reasoningPolicy,
          deepSeekReasoningEffort: deepSeekReasoningEffort,
          abortTrigger: abortTrigger ?? this.abortTrigger,
          connectTimeout: connectTimeout,
          nonStreamingTimeout: nonStreamingTimeout,
          minOutputTokens: minOutputTokens,
          suppressReasoningControl: suppressReasoningControl,
          maxOutputTokensOverride: maxOutputTokensOverride,
          onProgress: onProgress ?? this.onProgress,
          maxAutoRetries: maxAutoRetries ?? this.maxAutoRetries,
          retryBaseDelay: retryBaseDelay,
          maxRetryDelay: maxRetryDelay,
          onRetry: onRetry,
          messagesForAttempt: clearMessagesForAttempt
              ? null
              : messagesForAttempt ?? this.messagesForAttempt,
          beforeDispatch: beforeDispatch,
          dispatchIsCurrent: dispatchIsCurrent,
          beforeAttachmentUpload: beforeAttachmentUpload);

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
    await beforeDispatch?.call(messages);
    check();
    if (dispatchIsCurrent?.call() == false) {
      throw const ChatTransportException(
          safeCode: 'cancelled',
          safeMessage: '任务许可已失效',
          failureKind: ChatFailureKind.cancelled);
    }
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
  final ChatUnsentReason? unsentReason;

  /// 本地直连失败只能由可见原作用域中的用户确认新增尝试。
  final bool requiresUserConfirmation;

  const ChatTransportException({
    this.statusCode,
    this.retryAfter,
    required this.safeCode,
    required this.safeMessage,
    this.responseStarted = false,
    this.failureStage = ChatFailureStage.unknown,
    this.failureKind = ChatFailureKind.unknown,
    this.unsentReason,
    this.requiresUserConfirmation = false,
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
