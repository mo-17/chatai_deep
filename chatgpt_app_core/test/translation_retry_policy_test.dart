import 'dart:math';

import 'package:chatgpt_app_core/chat/application/translation_retry_policy.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 17, 12);

  group('TranslationRetryPolicy', () {
    test('authentication and ordinary invalid requests pause immediately', () {
      const policy = TranslationRetryPolicy();

      for (final kind in [
        TranslationFailureKind.authentication,
        TranslationFailureKind.invalidRequest,
      ]) {
        final decision = policy.decide(
          failure: _failure(kind),
          categoryAttempt: 0,
          chunkRunes: 1200,
          minimumSplitRunes: 400,
          now: now,
        );

        expect(decision.action, TranslationRetryAction.pause);
        expect(decision.nextRunAt, isNull);
        expect(decision.suppressReasoningControl, isFalse);
      }
    });

    test('unsupported reasoning control retries once with suppression', () {
      const policy = TranslationRetryPolicy();
      final first = policy.decide(
        failure: _failure(
          TranslationFailureKind.unsupportedReasoningControl,
        ),
        categoryAttempt: 0,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );
      final exhausted = policy.decide(
        failure: _failure(
          TranslationFailureKind.unsupportedReasoningControl,
        ),
        categoryAttempt: 1,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );

      expect(first.action, TranslationRetryAction.retry);
      expect(first.suppressReasoningControl, isTrue);
      expect(first.nextRunAt, isNull);
      expect(exhausted.action, TranslationRetryAction.pause);
      expect(exhausted.suppressReasoningControl, isFalse);
    });

    test('429 clamps Retry-After and allows exactly two schedules', () {
      const policy = TranslationRetryPolicy();

      final minimum = policy.decide(
        failure: _failure(
          TranslationFailureKind.rateLimited,
          retryAfter: Duration.zero,
        ),
        categoryAttempt: 0,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );
      final maximum = policy.decide(
        failure: _failure(
          TranslationFailureKind.rateLimited,
          retryAfter: const Duration(seconds: 999),
        ),
        categoryAttempt: 1,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );
      final exhausted = policy.decide(
        failure: _failure(
          TranslationFailureKind.rateLimited,
          retryAfter: const Duration(seconds: 10),
        ),
        categoryAttempt: 2,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );

      expect(minimum.action, TranslationRetryAction.schedule);
      expect(minimum.nextRunAt, now.add(const Duration(seconds: 1)));
      expect(maximum.action, TranslationRetryAction.schedule);
      expect(maximum.nextRunAt, now.add(const Duration(seconds: 120)));
      expect(exhausted.action, TranslationRetryAction.pause);
      expect(exhausted.nextRunAt, isNull);
    });

    test('429 without Retry-After uses full jitter under 2 then 4 seconds', () {
      const policy = TranslationRetryPolicy(random: _FixedRandom(0.5));

      final first = policy.decide(
        failure: _failure(TranslationFailureKind.rateLimited),
        categoryAttempt: 0,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );
      final second = policy.decide(
        failure: _failure(TranslationFailureKind.rateLimited),
        categoryAttempt: 1,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );

      expect(first.nextRunAt, now.add(const Duration(seconds: 1)));
      expect(second.nextRunAt, now.add(const Duration(seconds: 2)));
    });

    test('negative category attempt is handled as the first 429 attempt', () {
      const policy = TranslationRetryPolicy(random: _FixedRandom(0.5));

      final decision = policy.decide(
        failure: _failure(TranslationFailureKind.rateLimited),
        categoryAttempt: -7,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );

      expect(decision.action, TranslationRetryAction.schedule);
      expect(decision.nextRunAt, now.add(const Duration(seconds: 1)));
    });

    test('server and network failures schedule only one jittered retry', () {
      for (final kind in [
        TranslationFailureKind.server,
        TranslationFailureKind.network,
      ]) {
        const policy = TranslationRetryPolicy(random: _FixedRandom(0.5));
        final first = policy.decide(
          failure: _failure(kind),
          categoryAttempt: 0,
          chunkRunes: 1200,
          minimumSplitRunes: 400,
          now: now,
        );
        final exhausted = policy.decide(
          failure: _failure(kind),
          categoryAttempt: 1,
          chunkRunes: 1200,
          minimumSplitRunes: 400,
          now: now,
        );

        expect(first.action, TranslationRetryAction.schedule);
        expect(
          first.nextRunAt,
          now.add(const Duration(milliseconds: 500)),
        );
        expect(exhausted.action, TranslationRetryAction.pause);
        expect(exhausted.nextRunAt, isNull);
      }
    });

    test('each timeout splits above the minimum and pauses at the minimum', () {
      const policy = TranslationRetryPolicy();

      for (final kind in [
        TranslationFailureKind.firstEventTimeout,
        TranslationFailureKind.idleTimeout,
        TranslationFailureKind.totalTimeout,
      ]) {
        final splittable = policy.decide(
          failure: _failure(kind),
          categoryAttempt: 99,
          chunkRunes: 401,
          minimumSplitRunes: 400,
          now: now,
        );
        final atMinimum = policy.decide(
          failure: _failure(kind),
          categoryAttempt: 0,
          chunkRunes: 400,
          minimumSplitRunes: 400,
          now: now,
        );
        final belowMinimum = policy.decide(
          failure: _failure(kind),
          categoryAttempt: 0,
          chunkRunes: 399,
          minimumSplitRunes: 400,
          now: now,
        );

        expect(splittable.action, TranslationRetryAction.split);
        expect(atMinimum.action, TranslationRetryAction.pause);
        expect(belowMinimum.action, TranslationRetryAction.pause);
      }
    });

    test('invalid output repairs once and then pauses', () {
      const policy = TranslationRetryPolicy();

      final first = policy.decide(
        failure: _failure(TranslationFailureKind.invalidOutput),
        categoryAttempt: 0,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );
      final exhausted = policy.decide(
        failure: _failure(TranslationFailureKind.invalidOutput),
        categoryAttempt: 1,
        chunkRunes: 1200,
        minimumSplitRunes: 400,
        now: now,
      );

      expect(first.action, TranslationRetryAction.repair);
      expect(exhausted.action, TranslationRetryAction.pause);
    });

    test('cancel never retries regardless of attempt or chunk size', () {
      const policy = TranslationRetryPolicy();

      final decision = policy.decide(
        failure: _failure(TranslationFailureKind.cancelled),
        categoryAttempt: 0,
        chunkRunes: 5000,
        minimumSplitRunes: 400,
        now: now,
      );

      expect(decision.action, TranslationRetryAction.cancel);
      expect(decision.nextRunAt, isNull);
      expect(decision.suppressReasoningControl, isFalse);
    });
  });

  test('deferred and paused wrappers retain only typed scheduling data', () {
    final failure = _failure(TranslationFailureKind.rateLimited);
    final deferred = TranslationWorkDeferred(
      nextRunAt: now,
      failure: failure,
    );
    final paused = TranslationWorkPaused(failure: failure);

    expect(deferred.nextRunAt, now);
    expect(deferred.failure, same(failure));
    expect(paused.failure, same(failure));
    expect(deferred.toString(), isNot(contains('prompt')));
    expect(paused.toString(), isNot(contains('prompt')));
  });
}

TranslationRequestFailure _failure(
  TranslationFailureKind kind, {
  Duration? retryAfter,
}) =>
    TranslationRequestFailure(
      kind: kind,
      retryAfter: retryAfter,
      safeCode: kind.name,
    );

final class _FixedRandom implements Random {
  final double value;

  const _FixedRandom(this.value);

  @override
  bool nextBool() => value >= 0.5;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor().clamp(0, max - 1);
}
