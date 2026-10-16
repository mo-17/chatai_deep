import 'dart:math';

import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';

enum TranslationRetryAction { retry, split, repair, schedule, pause, cancel }

final class TranslationRetryDecision {
  final TranslationRetryAction action;
  final DateTime? nextRunAt;
  final bool suppressReasoningControl;

  const TranslationRetryDecision({
    required this.action,
    this.nextRunAt,
    this.suppressReasoningControl = false,
  });
}

final class TranslationRetryPolicy {
  final Random? _random;
  final bool allowAutomaticRecovery;

  const TranslationRetryPolicy(
      {Random? random, this.allowAutomaticRecovery = true})
      : _random = random;

  TranslationRetryDecision decide({
    required TranslationRequestFailure failure,
    required int categoryAttempt,
    required int chunkRunes,
    required int minimumSplitRunes,
    required DateTime now,
  }) {
    final attempt = categoryAttempt < 0 ? 0 : categoryAttempt;
    if ((!allowAutomaticRecovery || failure.requiresUserConfirmation) &&
        failure.kind != TranslationFailureKind.cancelled) {
      return const TranslationRetryDecision(
          action: TranslationRetryAction.pause);
    }
    switch (failure.kind) {
      case TranslationFailureKind.cancelled:
        return const TranslationRetryDecision(
          action: TranslationRetryAction.cancel,
        );
      case TranslationFailureKind.authentication:
      case TranslationFailureKind.invalidRequest:
        return const TranslationRetryDecision(
          action: TranslationRetryAction.pause,
        );
      case TranslationFailureKind.unsupportedReasoningControl:
        if (attempt == 0) {
          return const TranslationRetryDecision(
            action: TranslationRetryAction.retry,
            suppressReasoningControl: true,
          );
        }
        return const TranslationRetryDecision(
          action: TranslationRetryAction.pause,
        );
      case TranslationFailureKind.rateLimited:
        if (attempt >= 2) {
          return const TranslationRetryDecision(
            action: TranslationRetryAction.pause,
          );
        }
        final delay = failure.retryAfter == null
            ? _fullJitter(
                attempt: attempt,
                base: const Duration(seconds: 2),
                cap: const Duration(seconds: 30),
              )
            : _clampRetryAfter(failure.retryAfter!);
        return TranslationRetryDecision(
          action: TranslationRetryAction.schedule,
          nextRunAt: now.add(delay),
        );
      case TranslationFailureKind.server:
      case TranslationFailureKind.network:
        if (attempt >= 1) {
          return const TranslationRetryDecision(
            action: TranslationRetryAction.pause,
          );
        }
        return TranslationRetryDecision(
          action: TranslationRetryAction.schedule,
          nextRunAt: now.add(_fullJitter(
            attempt: attempt,
            base: const Duration(seconds: 1),
            cap: const Duration(seconds: 5),
          )),
        );
      case TranslationFailureKind.firstEventTimeout:
      case TranslationFailureKind.idleTimeout:
      case TranslationFailureKind.totalTimeout:
        final minimum = minimumSplitRunes < 0 ? 0 : minimumSplitRunes;
        return TranslationRetryDecision(
          action: chunkRunes > minimum
              ? TranslationRetryAction.split
              : TranslationRetryAction.pause,
        );
      case TranslationFailureKind.invalidOutput:
        return TranslationRetryDecision(
          action: attempt == 0
              ? TranslationRetryAction.repair
              : TranslationRetryAction.pause,
        );
    }
  }

  Duration _fullJitter({
    required int attempt,
    required Duration base,
    required Duration cap,
  }) {
    var ceilingMicros = base.inMicroseconds;
    for (var index = 0;
        index < attempt && ceilingMicros < cap.inMicroseconds;
        index += 1) {
      ceilingMicros *= 2;
      if (ceilingMicros > cap.inMicroseconds) {
        ceilingMicros = cap.inMicroseconds;
      }
    }
    final fraction = (_random ?? Random()).nextDouble();
    return Duration(microseconds: (ceilingMicros * fraction).floor());
  }
}

Duration _clampRetryAfter(Duration value) {
  const minimum = Duration(seconds: 1);
  const maximum = Duration(seconds: 120);
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}

final class TranslationWorkDeferred implements Exception {
  final DateTime nextRunAt;
  final TranslationRequestFailure failure;

  const TranslationWorkDeferred({
    required this.nextRunAt,
    required this.failure,
  });

  @override
  String toString() => 'TranslationWorkDeferred(${failure.kind.name})';
}

final class TranslationWorkPaused implements Exception {
  final TranslationRequestFailure failure;

  const TranslationWorkPaused({required this.failure});

  @override
  String toString() => 'TranslationWorkPaused(${failure.kind.name})';
}
