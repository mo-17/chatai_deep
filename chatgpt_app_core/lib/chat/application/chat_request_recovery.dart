import 'dart:async';
import 'package:chatgpt_app_core/chat/domain/backend_selection_error.dart';

import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';

/// 只重发尚未开始响应的单次网络请求；不重建任务、附件或工具回路。
Stream<T> recoverChatStream<T>(Stream<T> Function() request,
    {required ChatRequestOptions options}) {
  final cancel = _RequestCancellation(options.abortTrigger);
  late StreamSubscription<T> subscription;
  late StreamController<T> controller;
  controller = StreamController<T>(
      onListen: () {
        subscription = _recoverChatStream(request, options, cancel).listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close);
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () async {
        // 旧调用方可能只 cancel subscription，没有单独传 abortTrigger。
        // 显式通知退避等待，避免取消后再开始一次请求。
        cancel._cancel();
        try {
          await subscription.cancel();
        } on ChatTransportException catch (error) {
          // 退避中的 cancelled 仅用于唤醒 generator，正常取消无需再抛给调用方。
          if (error.safeCode != 'cancelled') rethrow;
        }
      });
  return controller.stream;
}

Stream<T> _recoverChatStream<T>(Stream<T> Function() request,
    ChatRequestOptions options, _RequestCancellation cancel) async* {
  await Future<void>.value();
  var attempt = 0;
  var emitted = false;
  while (true) {
    cancel.check();
    try {
      await for (final event in request()) {
        cancel.check();
        emitted = true;
        yield event;
      }
      cancel.check();
      return;
    } catch (error) {
      cancel.check();
      if (emitted || !_mayRetry(error, attempt, options)) rethrow;
      attempt++;
      await _waitForRetry(
          error as ChatTransportException, attempt, options, cancel);
    }
  }
}

Future<T> recoverChatRequest<T>(Future<T> Function() request,
    {required ChatRequestOptions options}) async {
  final cancel = _RequestCancellation(options.abortTrigger);
  await Future<void>.value();
  var attempt = 0;
  while (true) {
    cancel.check();
    try {
      final result = await request();
      cancel.check();
      return result;
    } catch (error) {
      cancel.check();
      if (!_mayRetry(error, attempt, options)) {
        rethrow;
      }
      attempt++;
      await _waitForRetry(
          error as ChatTransportException, attempt, options, cancel);
    }
  }
}

int _limit(ChatRequestOptions options) => (options.maxAutoRetries ??
        (options.profile == ChatRequestProfile.translation ? 0 : 2))
    .clamp(0, 2);

bool _mayRetry(Object error, int attempts, ChatRequestOptions options) {
  if (attempts >= _limit(options) ||
      error is! ChatTransportException ||
      error.responseStarted ||
      error.requiresUserConfirmation ||
      isBackendSelectionError(error.safeCode)) {
    return false;
  }
  if (const {
    'cancelled',
    'authentication_error',
    'insufficient_balance',
    'invalid_request',
    'unknown_parameter',
    'unsupported_parameter',
    'unsupported_reasoning_control',
    'model_not_found',
    'invalid_endpoint',
    'invalid_response',
    'attachment_upload_failed'
  }.contains(error.safeCode)) {
    return false;
  }
  // 状态码优先，禁止把余额、鉴权、模型和参数错误包装成可重试错误。
  if (error.statusCode != null) {
    return const {429, 500, 503}.contains(error.statusCode);
  }
  return const {'network_error', 'timeout', 'connect_timeout'}
      .contains(error.safeCode);
}

Future<void> _waitForRetry(ChatTransportException error, int attempt,
    ChatRequestOptions options, _RequestCancellation cancel) async {
  final cap = options.maxRetryDelay.inMilliseconds.clamp(0, 5000);
  final base = options.retryBaseDelay.inMilliseconds.clamp(0, cap);
  final milliseconds =
      (error.retryAfter?.inMilliseconds ?? base * (1 << (attempt - 1)))
          .clamp(0, cap);
  final delay = Duration(milliseconds: milliseconds);
  try {
    options.onRetry?.call(ChatRequestRetry(
        attempt: attempt,
        maxRetries: _limit(options),
        delay: delay,
        safeCode: error.safeCode));
  } catch (_) {}
  reportChatSendProgress(options.onProgress,
      ChatSendProgress('等待重试（$attempt/${_limit(options)}）'));
  await cancel.wait(delay);
}

class _RequestCancellation {
  bool cancelled = false;
  final Completer<void> _signal = Completer<void>();
  _RequestCancellation(Future<void>? abort) {
    abort?.then<void>((_) => _cancel(),
        onError: (Object _, StackTrace __) => _cancel());
  }
  void _cancel() {
    cancelled = true;
    if (!_signal.isCompleted) _signal.complete();
  }

  void check() {
    if (cancelled) {
      throw const ChatTransportException(
          safeCode: 'cancelled', safeMessage: '请求已取消');
    }
  }

  Future<void> wait(Duration duration) async {
    final timerDone = Completer<void>();
    final timer = Timer(duration, () => timerDone.complete());
    try {
      await Future.any([timerDone.future, _signal.future]);
      check();
    } finally {
      timer.cancel();
    }
  }
}
