import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';

enum TranslationFailureKind {
  cancelled,
  authentication,
  invalidRequest,
  unsupportedReasoningControl,
  rateLimited,
  server,
  network,
  firstEventTimeout,
  idleTimeout,
  totalTimeout,
  invalidOutput,
}

enum TranslationStreamPhase { waiting, thinking, receiving }

final class TranslationRequestFailure implements Exception {
  final TranslationFailureKind kind;
  final int? statusCode;
  final Duration? retryAfter;
  final String safeCode;

  const TranslationRequestFailure({
    required this.kind,
    this.statusCode,
    this.retryAfter,
    required this.safeCode,
  });

  @override
  String toString() => 'TranslationRequestFailure(${kind.name})';
}

abstract interface class TranslationCancellationToken {
  bool get isCancelled;

  Future<void> get whenCancelled;
}

final class TranslationCancellationController
    implements TranslationCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  @override
  bool get isCancelled => _cancelled.isCompleted;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class TranslationStreamExecutor {
  final ChatService _service;
  TranslationRequestProfile _profile;
  final Future<void> Function(TranslationRequestProfile profile)?
      _onProfileChanged;
  final Duration _firstEventTimeout;
  final Duration _idleTimeout;
  final Duration _totalTimeout;

  TranslationStreamExecutor({
    required ChatService service,
    required TranslationRequestProfile profile,
    Future<void> Function(TranslationRequestProfile profile)? onProfileChanged,
    Duration firstEventTimeout = const Duration(seconds: 45),
    Duration idleTimeout = const Duration(seconds: 60),
    Duration totalTimeout = const Duration(minutes: 5),
  })  : _service = service,
        _profile = profile,
        _onProfileChanged = onProfileChanged,
        _firstEventTimeout = firstEventTimeout,
        _idleTimeout = idleTimeout,
        _totalTimeout = totalTimeout;

  Future<String> complete(
    String prompt, {
    required TranslationCancellationToken cancellation,
    void Function(TranslationStreamPhase phase)? onPhase,
  }) async {
    if (cancellation.isCancelled) throw _cancelledFailure;

    var negotiatedReasoningControl = false;
    while (true) {
      final attemptProfile = _profile;
      try {
        return await _runAttempt(
          prompt,
          profile: attemptProfile,
          cancellation: cancellation,
          onPhase: onPhase,
        );
      } on TranslationRequestFailure catch (failure) {
        final canSuppressReasoning = failure.kind ==
                TranslationFailureKind.unsupportedReasoningControl &&
            attemptProfile.reasoningPolicy ==
                ChatReasoningPolicy.offIfSupported &&
            !attemptProfile.reasoningControlSuppressed &&
            !negotiatedReasoningControl;
        if (!canSuppressReasoning) rethrow;

        negotiatedReasoningControl = true;
        final suppressed = attemptProfile.suppressReasoningControl();
        _profile = suppressed;
        try {
          await _onProfileChanged?.call(suppressed);
        } catch (_) {
          throw const TranslationRequestFailure(
            kind: TranslationFailureKind.network,
            safeCode: 'request_failed',
          );
        }
        if (cancellation.isCancelled) throw _cancelledFailure;
      }
    }
  }

  Future<String> _runAttempt(
    String prompt, {
    required TranslationRequestProfile profile,
    required TranslationCancellationToken cancellation,
    void Function(TranslationStreamPhase phase)? onPhase,
  }) {
    if (cancellation.isCancelled) {
      return Future<String>.error(_cancelledFailure);
    }

    final result = Completer<String>();
    final abort = Completer<void>();
    final output = StringBuffer();
    StreamSubscription<StreamEvent>? subscription;
    Timer? firstTimer;
    Timer? idleTimer;
    Timer? totalTimer;
    var terminal = false;
    var sawEvent = false;
    var phase = TranslationStreamPhase.waiting;

    void notifyPhase(TranslationStreamPhase next) {
      if (phase == next && next != TranslationStreamPhase.waiting) return;
      phase = next;
      try {
        onPhase?.call(next);
      } catch (_) {
        // UI progress callbacks must not take ownership of the network request.
      }
    }

    Future<void> finish({String? value, Object? error}) async {
      if (terminal) return;
      terminal = true;
      firstTimer?.cancel();
      idleTimer?.cancel();
      totalTimer?.cancel();
      if (!abort.isCompleted) abort.complete();
      // Let AbortableRequest observers run before exposing the terminal result.
      await Future<void>.value();
      final activeSubscription = subscription;
      if (activeSubscription != null) {
        try {
          // Calling cancel detaches delivery synchronously. Its cleanup Future
          // belongs to the stream implementation and may fail or never settle;
          // observe it only to consume late errors, never to gate our result.
          unawaited(activeSubscription.cancel().then<void>(
                (_) {},
                onError: (Object _, StackTrace __) {},
              ));
        } catch (_) {
          // The abort was already signalled and cancellation requested. A
          // broken stream cleanup must not replace or strand the real result.
        }
      }
      if (result.isCompleted) return;
      if (error != null) {
        result.completeError(error);
      } else {
        result.complete(value ?? '');
      }
    }

    void fail(TranslationRequestFailure failure) {
      unawaited(finish(error: failure));
    }

    void resetIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(
        _idleTimeout,
        () => fail(const TranslationRequestFailure(
          kind: TranslationFailureKind.idleTimeout,
          safeCode: 'idle_timeout',
        )),
      );
    }

    notifyPhase(TranslationStreamPhase.waiting);
    firstTimer = Timer(
      _firstEventTimeout,
      () => fail(const TranslationRequestFailure(
        kind: TranslationFailureKind.firstEventTimeout,
        safeCode: 'first_event_timeout',
      )),
    );
    totalTimer = Timer(
      _totalTimeout,
      () => fail(const TranslationRequestFailure(
        kind: TranslationFailureKind.totalTimeout,
        safeCode: 'total_timeout',
      )),
    );
    cancellation.whenCancelled.then((_) {
      if (!terminal) fail(_cancelledFailure);
    });

    try {
      final stream = _service.chatStreamEventsWithOptions(
        prompt: prompt,
        history: const [],
        options: ChatRequestOptions(
          profile: ChatRequestProfile.translation,
          reasoningPolicy: profile.reasoningPolicy,
          abortTrigger: abort.future,
          connectTimeout: _firstEventTimeout,
          minOutputTokens: 2048,
          suppressReasoningControl: profile.reasoningControlSuppressed,
        ),
      );
      subscription = stream.listen(
        (event) {
          if (terminal) return;
          sawEvent = true;
          firstTimer?.cancel();
          resetIdleTimer();
          switch (event.type) {
            case StreamEventType.text:
              if (event.delta.isNotEmpty) {
                output.write(event.delta);
                if (phase != TranslationStreamPhase.receiving) {
                  notifyPhase(TranslationStreamPhase.receiving);
                }
              }
            case StreamEventType.reasoning:
              if (phase == TranslationStreamPhase.waiting) {
                notifyPhase(TranslationStreamPhase.thinking);
              }
            case StreamEventType.toolCall:
            case StreamEventType.toolResult:
            case StreamEventType.image:
            case StreamEventType.citation:
            case StreamEventType.usage:
              break;
          }
        },
        onError: (Object error) {
          if (terminal) return;
          fail(_mapFailure(
            error,
            profile: profile,
            sawEvent: sawEvent,
          ));
        },
        onDone: () {
          if (terminal) return;
          if (output.toString().trim().isEmpty) {
            fail(const TranslationRequestFailure(
              kind: TranslationFailureKind.invalidOutput,
              safeCode: 'invalid_output',
            ));
          } else {
            unawaited(finish(value: output.toString()));
          }
        },
      );
    } catch (error) {
      fail(_mapFailure(error, profile: profile, sawEvent: sawEvent));
    }

    return result.future;
  }
}

const _cancelledFailure = TranslationRequestFailure(
  kind: TranslationFailureKind.cancelled,
  safeCode: 'cancelled',
);

const _knownTransportCodes = {
  'cancelled',
  'timeout',
  'network_error',
  'unknown_parameter',
  'unsupported_parameter',
  'invalid_request',
  'authentication_error',
  'rate_limited',
  'server_error',
  'request_failed',
};

TranslationRequestFailure _mapFailure(
  Object error, {
  required TranslationRequestProfile profile,
  required bool sawEvent,
}) {
  if (error is TranslationRequestFailure) {
    return TranslationRequestFailure(
      kind: error.kind,
      statusCode: _safeStatusCode(error.statusCode),
      retryAfter: _safeRetryAfter(error.retryAfter),
      safeCode: _safeTransportCode(error.safeCode),
    );
  }
  if (error is! ChatTransportException) {
    return const TranslationRequestFailure(
      kind: TranslationFailureKind.network,
      safeCode: 'request_failed',
    );
  }

  final statusCode = _safeStatusCode(error.statusCode);
  final retryAfter = _safeRetryAfter(error.retryAfter);
  final safeCode = _safeTransportCode(error.safeCode);
  final reasoningControlWasSent =
      profile.reasoningPolicy == ChatReasoningPolicy.offIfSupported &&
          !profile.reasoningControlSuppressed;

  if (safeCode == 'cancelled') {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.cancelled,
      statusCode: statusCode,
      safeCode: safeCode,
    );
  }
  if (statusCode == 401 ||
      statusCode == 403 ||
      safeCode == 'authentication_error') {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.authentication,
      statusCode: statusCode,
      safeCode: 'authentication_error',
    );
  }
  if ((safeCode == 'unknown_parameter' ||
          safeCode == 'unsupported_parameter') &&
      reasoningControlWasSent) {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.unsupportedReasoningControl,
      statusCode: statusCode,
      safeCode: safeCode,
    );
  }
  if (statusCode == 429 || safeCode == 'rate_limited') {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.rateLimited,
      statusCode: statusCode,
      retryAfter: retryAfter,
      safeCode: 'rate_limited',
    );
  }
  if ((statusCode != null && statusCode >= 500) || safeCode == 'server_error') {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.server,
      statusCode: statusCode,
      safeCode: 'server_error',
    );
  }
  if (statusCode == 400 ||
      safeCode == 'invalid_request' ||
      safeCode == 'unknown_parameter' ||
      safeCode == 'unsupported_parameter') {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.invalidRequest,
      statusCode: statusCode,
      safeCode: safeCode == 'request_failed' ? 'invalid_request' : safeCode,
    );
  }
  if (safeCode == 'timeout' && !sawEvent) {
    return TranslationRequestFailure(
      kind: TranslationFailureKind.firstEventTimeout,
      statusCode: statusCode,
      safeCode: 'first_event_timeout',
    );
  }
  return TranslationRequestFailure(
    kind: TranslationFailureKind.network,
    statusCode: statusCode,
    safeCode: safeCode,
  );
}

int? _safeStatusCode(int? value) =>
    value != null && value >= 100 && value <= 599 ? value : null;

Duration? _safeRetryAfter(Duration? value) =>
    value != null && !value.isNegative ? value : null;

String _safeTransportCode(String value) =>
    _knownTransportCodes.contains(value) ? value : 'request_failed';
