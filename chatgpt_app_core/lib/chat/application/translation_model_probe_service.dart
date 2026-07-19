import 'dart:async';

import 'package:chatgpt_app_core/ai_readiness/ai_health_state_guard.dart';
import 'package:chatgpt_app_core/chat/application/assistant_role_card_translation_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_fingerprint.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_resolver.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';

const translationProbePrompt = '''你是翻译接口兼容性测试器。
把 JSON 中的英文短语翻译为简体中文。
只返回一个 JSON 对象，不要 Markdown，不要解释：
{"translation":"Good morning"}''';

typedef TranslationProbeExecutorFactory = TranslationStreamExecutor Function({
  required AISettings settings,
  required TranslationRequestProfile profile,
  required Future<void> Function(TranslationRequestProfile) onProfileChanged,
});

final class TranslationModelProbeResult {
  final TranslationModelProbeRecord record;

  const TranslationModelProbeResult({required this.record});
}

final class TranslationModelProbeIdentity {
  final String accountHash;
  final String fingerprint;
  final TranslationModelProbeCacheToken cacheToken;
  final AIProviderHealthConfiguration? _localProviderConfiguration;

  TranslationModelProbeIdentity({
    required this.accountHash,
    required this.fingerprint,
    required this.cacheToken,
    AIProviderHealthConfiguration? localProviderConfiguration,
  }) : _localProviderConfiguration = localProviderConfiguration;
}

abstract interface class TranslationModelProbeHandle {
  Future<TranslationModelProbeResult> get result;

  void cancel();
}

abstract interface class TranslationModelProbeGateway {
  TranslationModelProbeIdentity identify({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });

  bool isIdentityCurrent(
    TranslationModelProbeIdentity identity, {
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });

  TranslationModelProbeRecord? lookup({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });

  TranslationModelProbeHandle start({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
    required bool Function() isConfigurationCurrent,
  });

  TranslationRequestProfile applyCachedEvidence({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  });
}

final class TranslationModelProbeService
    implements TranslationModelProbeGateway {
  static final shared = TranslationModelProbeService();

  final TranslationModelProbeCache _cache;
  final TranslationProbeExecutorFactory _executorFactory;
  final DateTime Function() _now;
  final Stopwatch Function() _stopwatchFactory;
  final Map<String, List<_ProbeFlight>> _flights = {};

  TranslationModelProbeService({
    TranslationModelProbeCache? cache,
    TranslationProbeExecutorFactory? executorFactory,
    DateTime Function()? now,
    Stopwatch Function()? stopwatchFactory,
  })  : _cache = cache ?? TranslationModelProbeCache.shared,
        _executorFactory = executorFactory ?? _defaultExecutorFactory,
        _now = now ?? DateTime.now,
        _stopwatchFactory = stopwatchFactory ?? Stopwatch.new;

  @override
  TranslationModelProbeIdentity identify({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    final applied = TranslationModelResolver.apply(settings, profile);
    final isLocal = profile.mode == TranslationExecutionMode.local;
    final localProvider = isLocal ? applied.activeProvider : null;
    return TranslationModelProbeIdentity(
      accountHash: accountHash,
      fingerprint: TranslationModelProbeFingerprint.build(
        settings: settings,
        profile: profile,
      ),
      cacheToken: _cache.tokenFor(
        accountHash: accountHash,
        providerId: localProvider?.id,
      ),
      localProviderConfiguration: localProvider == null
          ? null
          : AIProviderHealthConfiguration.capture(localProvider),
    );
  }

  @override
  bool isIdentityCurrent(
    TranslationModelProbeIdentity identity, {
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    try {
      final current = identify(
        accountHash: accountHash,
        settings: settings,
        profile: profile,
      );
      if (identity.accountHash != current.accountHash ||
          identity.fingerprint != current.fingerprint ||
          !identity.cacheToken.sameAs(current.cacheToken)) {
        return false;
      }
      final expectedLocal = identity._localProviderConfiguration;
      final currentLocal = current._localProviderConfiguration;
      if (expectedLocal == null || currentLocal == null) {
        return expectedLocal == null && currentLocal == null;
      }
      final applied = TranslationModelResolver.apply(settings, profile);
      return expectedLocal.matches(applied.activeProvider);
    } catch (_) {
      return false;
    }
  }

  @override
  TranslationModelProbeRecord? lookup({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    final fingerprint = TranslationModelProbeFingerprint.build(
      settings: settings,
      profile: profile,
    );
    return _cache.lookup(
      accountHash: accountHash,
      fingerprint: fingerprint,
    );
  }

  @override
  TranslationModelProbeHandle start({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
    required bool Function() isConfigurationCurrent,
  }) {
    final identity = identify(
      accountHash: accountHash,
      settings: settings,
      profile: profile,
    );
    if (!_guardIsCurrent(isConfigurationCurrent)) {
      return _CancelledProbeHandle();
    }

    final bucket = '${identity.accountHash}:${identity.fingerprint}';
    final candidates = _flights[bucket];
    _ProbeFlight? flight;
    if (candidates != null) {
      for (final candidate in candidates) {
        if (candidate.accepting &&
            _canJoin(
              candidate.identity,
              identity,
              settings: settings,
              profile: profile,
            )) {
          flight = candidate;
          break;
        }
      }
    }

    final subscriber = _ProbeSubscriber(
      service: this,
      guard: isConfigurationCurrent,
    );
    if (flight != null) {
      flight.subscribers.add(subscriber);
      subscriber.flight = flight;
      return subscriber;
    }

    final created = _ProbeFlight(
      bucket: bucket,
      identity: identity,
      cancellation: TranslationCancellationController(),
    );
    created.subscribers.add(subscriber);
    subscriber.flight = created;
    _flights.putIfAbsent(bucket, () => []).add(created);
    unawaited(_runFlight(
      created,
      settings: settings,
      initialProfile: profile,
    ));
    return subscriber;
  }

  @override
  TranslationRequestProfile applyCachedEvidence({
    required String accountHash,
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    final record = lookup(
      accountHash: accountHash,
      settings: settings,
      profile: profile,
    );
    return record?.reasoningControlSuppressed == true
        ? profile.suppressReasoningControl()
        : profile;
  }

  bool _canJoin(
    TranslationModelProbeIdentity existing,
    TranslationModelProbeIdentity current, {
    required AISettings settings,
    required TranslationRequestProfile profile,
  }) {
    if (existing.accountHash != current.accountHash ||
        existing.fingerprint != current.fingerprint ||
        !existing.cacheToken.sameAs(current.cacheToken)) {
      return false;
    }
    final expectedLocal = existing._localProviderConfiguration;
    final currentLocal = current._localProviderConfiguration;
    if (expectedLocal == null || currentLocal == null) {
      return expectedLocal == null && currentLocal == null;
    }
    try {
      final applied = TranslationModelResolver.apply(settings, profile);
      return expectedLocal.matches(applied.activeProvider);
    } catch (_) {
      return false;
    }
  }

  Future<void> _runFlight(
    _ProbeFlight flight, {
    required AISettings settings,
    required TranslationRequestProfile initialProfile,
  }) async {
    var effectiveProfile = initialProfile;
    final stopwatch = _stopwatchFactory();
    int? firstEventMs;
    TranslationModelProbeRecord? record;
    TranslationRequestFailure? terminalError;

    try {
      final executor = _executorFactory(
        settings: settings,
        profile: initialProfile,
        onProfileChanged: (profile) async {
          effectiveProfile = profile;
        },
      );
      stopwatch.start();
      final output = await executor.complete(
        translationProbePrompt,
        cancellation: flight.cancellation,
        onFirstEvent: () {
          firstEventMs ??= stopwatch.elapsedMilliseconds;
        },
      );
      stopwatch.stop();
      _requireTranslatedOutput(output);
      record = TranslationModelProbeRecord(
        fingerprint: flight.identity.fingerprint,
        status: TranslationModelProbeStatus.verified,
        checkedAt: _now(),
        firstEventMs: firstEventMs,
        totalMs: stopwatch.elapsedMilliseconds,
        reasoningControlSuppressed: effectiveProfile.reasoningControlSuppressed,
      );
    } on TranslationRequestFailure catch (failure) {
      stopwatch.stop();
      if (failure.kind == TranslationFailureKind.cancelled) {
        terminalError = _cancelledProbeFailure;
      } else {
        record = TranslationModelProbeRecord(
          fingerprint: flight.identity.fingerprint,
          status: TranslationModelProbeStatus.failed,
          checkedAt: _now(),
          firstEventMs: firstEventMs,
          totalMs: stopwatch.elapsedMilliseconds,
          safeErrorCode: probeSafeCode(failure.kind),
          reasoningControlSuppressed:
              effectiveProfile.reasoningControlSuppressed,
        );
      }
    } on FormatException {
      stopwatch.stop();
      record = TranslationModelProbeRecord(
        fingerprint: flight.identity.fingerprint,
        status: TranslationModelProbeStatus.failed,
        checkedAt: _now(),
        firstEventMs: firstEventMs,
        totalMs: stopwatch.elapsedMilliseconds,
        safeErrorCode: 'invalid_output',
        reasoningControlSuppressed: effectiveProfile.reasoningControlSuppressed,
      );
    } catch (_) {
      stopwatch.stop();
      record = TranslationModelProbeRecord(
        fingerprint: flight.identity.fingerprint,
        status: TranslationModelProbeStatus.failed,
        checkedAt: _now(),
        firstEventMs: firstEventMs,
        totalMs: stopwatch.elapsedMilliseconds,
        safeErrorCode: 'unknown',
        reasoningControlSuppressed: effectiveProfile.reasoningControlSuppressed,
      );
    }

    _detachFlight(flight);
    if (terminalError != null) {
      _completeFlightError(flight, terminalError);
      return;
    }
    final completedRecord = record;
    if (completedRecord == null || flight.subscribers.isEmpty) return;

    final canPersist = flight.subscribers.any(
      (subscriber) => _guardIsCurrent(subscriber.guard),
    );
    if (canPersist) {
      try {
        await _cache.put(
          completedRecord,
          expectedAccountHash: flight.identity.accountHash,
          providerId: flight.identity._localProviderConfiguration?.providerId,
          expectedToken: flight.identity.cacheToken,
        );
      } catch (_) {
        // 缓存不可用不能把已脱敏的 provider 探测结果改写成另一种失败。
      }
    }

    if (flight.subscribers.isEmpty) return;
    final result = TranslationModelProbeResult(record: completedRecord);
    for (final subscriber in flight.subscribers.toList()) {
      subscriber.complete(result);
    }
    flight.subscribers.clear();
  }

  void _cancelSubscriber(_ProbeSubscriber subscriber) {
    if (subscriber.isCompleted) return;
    final flight = subscriber.flight;
    // executor 已终态后，flight 会先从 single-flight 表移除。此时 provider
    // 结果已经确定，不能再让 cache 写入窗口中的晚到取消改写该结果。
    if (flight != null && !flight.accepting) return;
    subscriber.completeError(_cancelledProbeFailure);
    if (flight == null) return;
    flight.subscribers.remove(subscriber);
    subscriber.flight = null;
    if (flight.subscribers.isEmpty) {
      _detachFlight(flight);
      flight.cancellation.cancel();
    }
  }

  void _completeFlightError(
    _ProbeFlight flight,
    TranslationRequestFailure failure,
  ) {
    for (final subscriber in flight.subscribers.toList()) {
      subscriber.completeError(failure);
    }
    flight.subscribers.clear();
  }

  void _detachFlight(_ProbeFlight flight) {
    if (!flight.accepting) return;
    flight.accepting = false;
    final candidates = _flights[flight.bucket];
    candidates?.remove(flight);
    if (candidates?.isEmpty == true) _flights.remove(flight.bucket);
  }
}

String probeSafeCode(TranslationFailureKind kind) => switch (kind) {
      TranslationFailureKind.authentication => 'auth_failed',
      TranslationFailureKind.invalidRequest ||
      TranslationFailureKind.unsupportedReasoningControl =>
        'unsupported_api',
      TranslationFailureKind.rateLimited => 'rate_limited',
      TranslationFailureKind.firstEventTimeout => 'first_event_timeout',
      TranslationFailureKind.idleTimeout => 'idle_timeout',
      TranslationFailureKind.network => 'network_unreachable',
      TranslationFailureKind.invalidOutput => 'invalid_output',
      TranslationFailureKind.cancelled => 'cancelled',
      TranslationFailureKind.server ||
      TranslationFailureKind.totalTimeout =>
        'unknown',
    };

TranslationStreamExecutor _defaultExecutorFactory({
  required AISettings settings,
  required TranslationRequestProfile profile,
  required Future<void> Function(TranslationRequestProfile) onProfileChanged,
}) {
  return TranslationStreamExecutor(
    service:
        ChatService.from(TranslationModelResolver.apply(settings, profile)),
    profile: profile,
    onProfileChanged: onProfileChanged,
    maxOutputTokensOverride: 128,
  );
}

void _requireTranslatedOutput(String output) {
  final decoded = AssistantRoleCardTranslationService.decodeTranslation(output);
  final translation = decoded['translation'];
  if (translation is! String ||
      translation.trim().isEmpty ||
      translation.trim().toLowerCase() == 'good morning') {
    throw const FormatException('翻译模型预检输出无效');
  }
}

bool _guardIsCurrent(bool Function() guard) {
  try {
    return guard();
  } catch (_) {
    return false;
  }
}

const _cancelledProbeFailure = TranslationRequestFailure(
  kind: TranslationFailureKind.cancelled,
  safeCode: 'cancelled',
);

final class _ProbeFlight {
  final String bucket;
  final TranslationModelProbeIdentity identity;
  final TranslationCancellationController cancellation;
  final Set<_ProbeSubscriber> subscribers = {};
  bool accepting = true;

  _ProbeFlight({
    required this.bucket,
    required this.identity,
    required this.cancellation,
  });
}

final class _ProbeSubscriber implements TranslationModelProbeHandle {
  final TranslationModelProbeService service;
  final bool Function() guard;
  final Completer<TranslationModelProbeResult> _result = Completer();
  _ProbeFlight? flight;

  _ProbeSubscriber({required this.service, required this.guard});

  bool get isCompleted => _result.isCompleted;

  @override
  Future<TranslationModelProbeResult> get result => _result.future;

  @override
  void cancel() => service._cancelSubscriber(this);

  void complete(TranslationModelProbeResult value) {
    if (_result.isCompleted) return;
    flight = null;
    _result.complete(value);
  }

  void completeError(TranslationRequestFailure failure) {
    if (_result.isCompleted) return;
    flight = null;
    _result.completeError(failure);
  }
}

final class _CancelledProbeHandle implements TranslationModelProbeHandle {
  late final Future<TranslationModelProbeResult> _result =
      Future.error(_cancelledProbeFailure);

  @override
  Future<TranslationModelProbeResult> get result => _result;

  @override
  void cancel() {}
}
