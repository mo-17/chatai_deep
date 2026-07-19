import 'package:chatgpt_app_core/chat/application/translation_model_probe_cache.dart';
import 'package:chatgpt_app_core/chat/application/translation_model_probe_service.dart';
import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_translation_chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 7, 20, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    await HiCache.getInstance().prefs?.clear();
  });

  test(
      'construction, identity, current check, lookup and evidence make no request',
      () {
    final fake = FakeTranslationChatService(const []);
    var factoryCalls = 0;
    final service = TranslationModelProbeService(
      cache: TranslationModelProbeCache(now: () => now),
      executorFactory: ({
        required settings,
        required profile,
        required onProfileChanged,
      }) {
        factoryCalls += 1;
        return _executor(
          fake,
          profile: profile,
          onProfileChanged: onProfileChanged,
        );
      },
      now: () => now,
    );
    final settings = _settings();
    final profile = _profile();

    final identity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );

    expect(
      service.isIdentityCurrent(
        identity,
        accountHash: 'guest',
        settings: settings,
        profile: profile,
      ),
      isTrue,
    );
    expect(
      service.lookup(
        accountHash: 'guest',
        settings: settings,
        profile: profile,
      ),
      isNull,
    );
    expect(
      service
          .applyCachedEvidence(
            accountHash: 'guest',
            settings: settings,
            profile: profile,
          )
          .reasoningControlSuppressed,
      isFalse,
    );
    expect(factoryCalls, 0);
    expect(fake.requestAttempts, 0);
  });

  test('identity detects Key changes and fails closed on invalid settings', () {
    final service = TranslationModelProbeService(
      cache: TranslationModelProbeCache(now: () => now),
      now: () => now,
    );
    final settings = _settings();
    final profile = _profile();
    final identity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );

    settings.activeProvider.apiKey = 'sk-replaced';
    expect(
      service.isIdentityCurrent(
        identity,
        accountHash: 'guest',
        settings: settings,
        profile: profile,
      ),
      isFalse,
    );

    settings.activeProvider.enabled = false;
    expect(
      service.isIdentityCurrent(
        identity,
        accountHash: 'guest',
        settings: settings,
        profile: profile,
      ),
      isFalse,
    );
  });

  test('a false initial guard fails as cancelled before creating a request',
      () async {
    final fake = FakeTranslationChatService(const []);
    var factoryCalls = 0;
    var guardCalls = 0;
    final service = TranslationModelProbeService(
      cache: TranslationModelProbeCache(now: () => now),
      executorFactory: ({
        required settings,
        required profile,
        required onProfileChanged,
      }) {
        factoryCalls += 1;
        return _executor(fake, profile: profile);
      },
      now: () => now,
    );

    final handle = service.start(
      accountHash: 'guest',
      settings: _settings(),
      profile: _profile(),
      isConfigurationCurrent: () {
        guardCalls += 1;
        return false;
      },
    );

    await expectLater(handle.result, throwsA(_failure('cancelled')));
    expect(guardCalls, 1);
    expect(factoryCalls, 0);
    expect(fake.requestAttempts, 0);
  });

  test('uses the fixed private prompt, formal profile and strict JSON output',
      () async {
    final fake = FakeTranslationChatService([
      (request) {
        request.addNow(StreamEvent.text('{"translation":"早上好"}'));
        request.closeNow();
      },
    ]);
    AISettings? observedSettings;
    TranslationRequestProfile? observedProfile;
    final service = TranslationModelProbeService(
      cache: TranslationModelProbeCache(now: () => now),
      executorFactory: ({
        required settings,
        required profile,
        required onProfileChanged,
      }) {
        observedSettings = settings;
        observedProfile = profile;
        return _executor(
          fake,
          profile: profile,
          onProfileChanged: onProfileChanged,
        );
      },
      now: () => now,
    );
    final selected = _settings();
    final profile = _profile();

    final result = await service
        .start(
          accountHash: 'guest',
          settings: selected,
          profile: profile,
          isConfigurationCurrent: () => true,
        )
        .result;

    expect(result.record.status, TranslationModelProbeStatus.verified);
    expect(result.record.safeErrorCode, isNull);
    expect(fake.requests.single.prompt, translationProbePrompt);
    expect(fake.requests.single.prompt, isNot(contains('sk-secret')));
    expect(fake.requests.single.prompt,
        isNot(contains('https://private.example/v1')));
    expect(fake.requests.single.history, isEmpty);
    expect(
        fake.requests.single.options.profile, ChatRequestProfile.translation);
    expect(fake.requests.single.options.maxOutputTokensOverride, 128);
    expect(observedSettings!.mode, AIMode.local);
    expect(observedSettings!.activeProviderId, 'deepseek');
    expect(observedSettings!.effectiveModel, profile.modelId);
    expect(observedProfile, same(profile));

    final raw = HiCache.getInstance().get(
      TranslationModelProbeCache.keyFor('guest'),
    ) as String;
    for (final sensitive in [
      translationProbePrompt,
      '早上好',
      'sk-secret',
      'https://private.example/v1',
    ]) {
      expect(raw, isNot(contains(sensitive)));
    }
  });

  test('rejects missing, empty and untranslated probe output', () async {
    final fake = FakeTranslationChatService([
      for (final output in [
        '{}',
        '{"translation":"   "}',
        '{"translation":"good MORNING"}',
      ])
        (request) {
          request.addNow(StreamEvent.text(output));
          request.closeNow();
        },
    ]);
    final cache = TranslationModelProbeCache(now: () => now);
    final service = _service(fake, cache: cache, now: now);

    for (var index = 0; index < 3; index += 1) {
      final result = await service
          .start(
            accountHash: 'guest',
            settings: _settings(),
            profile: _profile(),
            isConfigurationCurrent: () => true,
          )
          .result;
      expect(result.record.status, TranslationModelProbeStatus.failed);
      expect(result.record.safeErrorCode, 'invalid_output');
    }

    expect(fake.requestAttempts, 3);
  });

  test('reasoning-first and usage-first both set first-event latency once',
      () async {
    final reasoningClock = _ManualStopwatch();
    final usageClock = _ManualStopwatch();
    final clocks = <_ManualStopwatch>[reasoningClock, usageClock];
    final fake = FakeTranslationChatService([
      (request) {
        request.runAfter(Duration.zero, () {
          reasoningClock.advance(11);
          request.addNow(StreamEvent.reasoning('private'));
        });
        request.runAfter(const Duration(milliseconds: 1), () {
          reasoningClock.advance(18);
          request.addNow(StreamEvent.text('{"translation":"早上好"}'));
          request.closeNow();
        });
      },
      (request) {
        request.runAfter(Duration.zero, () {
          usageClock.advance(7);
          request.addNow(StreamEvent.usage(promptTokens: 1));
        });
        request.runAfter(const Duration(milliseconds: 1), () {
          usageClock.advance(13);
          request.addNow(StreamEvent.text('{"translation":"早安"}'));
          request.closeNow();
        });
      },
    ]);
    final service = TranslationModelProbeService(
      cache: TranslationModelProbeCache(now: () => now),
      executorFactory: ({
        required settings,
        required profile,
        required onProfileChanged,
      }) =>
          _executor(
        fake,
        profile: profile,
        onProfileChanged: onProfileChanged,
      ),
      now: () => now,
      stopwatchFactory: () => clocks.removeAt(0),
    );

    final reasoning = await service
        .start(
          accountHash: 'guest',
          settings: _settings(),
          profile: _profile(),
          isConfigurationCurrent: () => true,
        )
        .result;
    final usage = await service
        .start(
          accountHash: 'guest',
          settings: _settings(),
          profile: _profile(),
          isConfigurationCurrent: () => true,
        )
        .result;

    expect(reasoning.record.firstEventMs, 11);
    expect(reasoning.record.totalMs, 29);
    expect(usage.record.firstEventMs, 7);
    expect(usage.record.totalMs, 20);
  });

  test('latency stopwatch starts immediately before executor complete',
      () async {
    final clock = _ManualStopwatch();
    final fake = FakeTranslationChatService([
      (request) {
        request.runAfter(Duration.zero, () {
          clock.advance(9);
          request.addNow(StreamEvent.usage(promptTokens: 1));
          request.addNow(StreamEvent.text('{"translation":"早上好"}'));
          request.closeNow();
        });
      },
    ]);
    final service = TranslationModelProbeService(
      cache: TranslationModelProbeCache(now: () => now),
      executorFactory: ({
        required settings,
        required profile,
        required onProfileChanged,
      }) {
        clock.advance(40);
        return _executor(
          fake,
          profile: profile,
          onProfileChanged: onProfileChanged,
        );
      },
      now: () => now,
      stopwatchFactory: () => clock,
    );

    final result = await service
        .start(
          accountHash: 'guest',
          settings: _settings(),
          profile: _profile(),
          isConfigurationCurrent: () => true,
        )
        .result;

    expect(result.record.firstEventMs, 9);
    expect(result.record.totalMs, 9);
  });

  test('maps every executor failure kind only to approved safe codes',
      () async {
    final cases = <(TranslationFailureKind, String)>[
      (TranslationFailureKind.authentication, 'auth_failed'),
      (TranslationFailureKind.invalidRequest, 'unsupported_api'),
      (TranslationFailureKind.unsupportedReasoningControl, 'unsupported_api'),
      (TranslationFailureKind.rateLimited, 'rate_limited'),
      (TranslationFailureKind.firstEventTimeout, 'first_event_timeout'),
      (TranslationFailureKind.idleTimeout, 'idle_timeout'),
      (TranslationFailureKind.network, 'network_unreachable'),
      (TranslationFailureKind.invalidOutput, 'invalid_output'),
      (TranslationFailureKind.server, 'unknown'),
      (TranslationFailureKind.totalTimeout, 'unknown'),
    ];
    const rawSecret =
        'Authorization: Bearer sk-provider https://private.example/error';
    final fake = FakeTranslationChatService([
      for (final entry in cases)
        (request) => request.errorNow(TranslationRequestFailure(
              kind: entry.$1,
              safeCode: rawSecret,
            )),
    ]);
    final cache = TranslationModelProbeCache(now: () => now);
    final service = _service(fake, cache: cache, now: now);
    final profile = _profile(
      reasoningPolicy: ChatReasoningPolicy.providerDefault,
    );

    for (final entry in cases) {
      final result = await service
          .start(
            accountHash: 'guest',
            settings: _settings(),
            profile: profile,
            isConfigurationCurrent: () => true,
          )
          .result;
      expect(result.record.status, TranslationModelProbeStatus.failed);
      expect(result.record.safeErrorCode, entry.$2);
      expect(result.record.toJson().toString(), isNot(contains(rawSecret)));
    }

    expect(fake.requestAttempts, cases.length);
  });

  test('confirmed start ignores historical cache and performs a fresh request',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final settings = _settings();
    final profile = _profile();
    final seedService = TranslationModelProbeService(cache: cache);
    final identity = seedService.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    await cache.put(
      TranslationModelProbeRecord(
        fingerprint: identity.fingerprint,
        status: TranslationModelProbeStatus.failed,
        checkedAt: now.subtract(const Duration(hours: 1)),
        safeErrorCode: 'auth_failed',
        reasoningControlSuppressed: false,
      ),
      expectedAccountHash: 'guest',
      providerId: 'deepseek',
      expectedToken: identity.cacheToken,
    );
    final fake = FakeTranslationChatService([
      (request) {
        request.addNow(StreamEvent.text('{"translation":"早上好"}'));
        request.closeNow();
      },
    ]);
    final service = _service(fake, cache: cache, now: now);

    final result = await service
        .start(
          accountHash: 'guest',
          settings: settings,
          profile: profile,
          isConfigurationCurrent: () => true,
        )
        .result;

    expect(fake.requestAttempts, 1);
    expect(result.record.status, TranslationModelProbeStatus.verified);
    expect(result.record.checkedAt, now);
  });

  test('identical starts share one request and fan out the same result',
      () async {
    final fake = FakeTranslationChatService([(request) {}]);
    final service = _service(
      fake,
      cache: TranslationModelProbeCache(now: () => now),
      now: now,
    );
    final settings = _settings();
    final profile = _profile();

    final first = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => true,
    );
    final second = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => true,
    );
    await _flush();

    expect(fake.requestAttempts, 1);
    fake.requests.single
      ..addNow(StreamEvent.text('{"translation":"早上好"}'))
      ..closeNow();
    final results = await Future.wait([first.result, second.result]);

    expect(identical(results[0], results[1]), isTrue);
    expect(results[0].record.status, TranslationModelProbeStatus.verified);
  });

  test('one subscriber cancels independently while the other stays attached',
      () async {
    final fake = FakeTranslationChatService([(request) {}]);
    final service = _service(
      fake,
      cache: TranslationModelProbeCache(now: () => now),
      now: now,
    );

    final first = service.start(
      accountHash: 'guest',
      settings: _settings(),
      profile: _profile(),
      isConfigurationCurrent: () => true,
    );
    final second = service.start(
      accountHash: 'guest',
      settings: _settings(),
      profile: _profile(),
      isConfigurationCurrent: () => true,
    );
    first.cancel();

    await expectLater(first.result, throwsA(_failure('cancelled')));
    expect(fake.requests.single.abortObserved, isFalse);
    fake.requests.single
      ..addNow(StreamEvent.text('{"translation":"早上好"}'))
      ..closeNow();
    expect(
      (await second.result).record.status,
      TranslationModelProbeStatus.verified,
    );
    expect(fake.requestAttempts, 1);
  });

  test('last subscriber cancel aborts transport and is never cached', () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final fake = FakeTranslationChatService([(request) {}]);
    final service = _service(fake, cache: cache, now: now);
    final settings = _settings();
    final profile = _profile();
    final identity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    final handle = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => true,
    );

    handle.cancel();

    await expectLater(handle.result, throwsA(_failure('cancelled')));
    await _flush();
    expect(fake.requests.single.abortObserved, isTrue);
    expect(fake.activeSubscriptions, 0);
    expect(
      cache.lookup(
        accountHash: 'guest',
        fingerprint: identity.fingerprint,
      ),
      isNull,
    );
  });

  test('cancel after executor terminal cannot replace the committed result',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final fake = FakeTranslationChatService([
      (request) {
        request.addNow(StreamEvent.text('{"translation":"早上好"}'));
        request.closeNow();
      },
    ]);
    final service = _service(fake, cache: cache, now: now);
    final settings = _settings();
    final profile = _profile();
    final identity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    late final TranslationModelProbeHandle handle;
    var guardCalls = 0;
    handle = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () {
        guardCalls += 1;
        if (guardCalls == 2) handle.cancel();
        return true;
      },
    );

    final result = await handle.result;

    expect(guardCalls, 2);
    expect(result.record.status, TranslationModelProbeStatus.verified);
    expect(
      cache.lookup(
        accountHash: 'guest',
        fingerprint: identity.fingerprint,
      ),
      isNotNull,
    );
  });

  test('a completed flight is never reused by a later identical start',
      () async {
    final fake = FakeTranslationChatService([
      (request) {
        request.addNow(StreamEvent.text('{"translation":"第一次"}'));
        request.closeNow();
      },
      (request) {
        request.addNow(StreamEvent.text('{"translation":"第二次"}'));
        request.closeNow();
      },
    ]);
    final service = _service(
      fake,
      cache: TranslationModelProbeCache(now: () => now),
      now: now,
    );

    await service
        .start(
          accountHash: 'guest',
          settings: _settings(),
          profile: _profile(),
          isConfigurationCurrent: () => true,
        )
        .result;
    await service
        .start(
          accountHash: 'guest',
          settings: _settings(),
          profile: _profile(),
          isConfigurationCurrent: () => true,
        )
        .result;

    expect(fake.requestAttempts, 2);
  });

  test('a Key change starts a new flight and blocks the old cache write',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final fake = FakeTranslationChatService([
      (request) {},
      (request) {},
    ]);
    final service = _service(fake, cache: cache, now: now);
    final settings = _settings();
    final profile = _profile();
    final oldIdentity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    final old = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => service.isIdentityCurrent(
        oldIdentity,
        accountHash: 'guest',
        settings: settings,
        profile: profile,
      ),
    );
    settings.activeProvider.apiKey = 'sk-replaced';
    final newIdentity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    final fresh = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => service.isIdentityCurrent(
        newIdentity,
        accountHash: 'guest',
        settings: settings,
        profile: profile,
      ),
    );
    await _flush();

    expect(oldIdentity.fingerprint, newIdentity.fingerprint);
    expect(fake.requestAttempts, 2);
    fake.requests.first
      ..addNow(StreamEvent.text('{"translation":"旧结果"}'))
      ..closeNow();
    await old.result;
    expect(
      cache.lookup(
        accountHash: 'guest',
        fingerprint: oldIdentity.fingerprint,
      ),
      isNull,
    );

    fake.requests.last
      ..addNow(StreamEvent.text('{"translation":"新结果"}'))
      ..closeNow();
    await fresh.result;
    expect(
      cache.lookup(
        accountHash: 'guest',
        fingerprint: newIdentity.fingerprint,
      ),
      isNotNull,
    );
  });

  test('cache invalidation separates flights and CAS rejects old completion',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final fake = FakeTranslationChatService([
      (request) {},
      (request) {},
    ]);
    final service = _service(fake, cache: cache, now: now);
    final settings = _settings();
    final profile = _profile();
    final identity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    final old = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => true,
    );
    await cache.invalidateProviders(
      accountHash: 'guest',
      providerIds: {'deepseek'},
    );
    final fresh = service.start(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
      isConfigurationCurrent: () => true,
    );
    await _flush();

    expect(fake.requestAttempts, 2);
    fake.requests.first
      ..addNow(StreamEvent.text('{"translation":"旧结果"}'))
      ..closeNow();
    await old.result;
    expect(
      cache.lookup(
        accountHash: 'guest',
        fingerprint: identity.fingerprint,
      ),
      isNull,
    );

    fake.requests.last
      ..addNow(StreamEvent.text('{"translation":"新结果"}'))
      ..closeNow();
    await fresh.result;
    expect(
      cache.lookup(
        accountHash: 'guest',
        fingerprint: identity.fingerprint,
      ),
      isNotNull,
    );
  });

  test('suppression evidence is cached when the no-parameter retry fails',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final fake = FakeTranslationChatService([
      (request) => request.errorNow(const ChatTransportException(
            statusCode: 400,
            safeCode: 'unsupported_reasoning_control',
            safeMessage: 'provider rejected parameter',
          )),
      (request) => request.errorNow(const ChatTransportException(
            safeCode: 'network_error',
            safeMessage: 'https://private.example/raw-error',
          )),
    ]);
    final service = _service(fake, cache: cache, now: now);
    final settings = _settings();
    final profile = _profile();

    final result = await service
        .start(
          accountHash: 'guest',
          settings: settings,
          profile: profile,
          isConfigurationCurrent: () => true,
        )
        .result;

    expect(fake.requestAttempts, 2);
    expect(fake.requests.first.options.suppressReasoningControl, isFalse);
    expect(fake.requests.last.options.suppressReasoningControl, isTrue);
    expect(result.record.status, TranslationModelProbeStatus.failed);
    expect(result.record.safeErrorCode, 'network_unreachable');
    expect(result.record.reasoningControlSuppressed, isTrue);
    final cached = service.lookup(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    expect(cached?.reasoningControlSuppressed, isTrue);
    final applied = service.applyCachedEvidence(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    expect(applied.reasoningControlSuppressed, isTrue);

    final raw = HiCache.getInstance().get(
      TranslationModelProbeCache.keyFor('guest'),
    ) as String;
    expect(raw, isNot(contains('provider rejected parameter')));
    expect(raw, isNot(contains('https://private.example/raw-error')));
  });

  test('expired or other-fingerprint evidence does not suppress the profile',
      () async {
    final cache = TranslationModelProbeCache(now: () => now);
    final service = TranslationModelProbeService(cache: cache, now: () => now);
    final settings = _settings();
    final profile = _profile();
    final identity = service.identify(
      accountHash: 'guest',
      settings: settings,
      profile: profile,
    );
    await cache.put(
      TranslationModelProbeRecord(
        fingerprint: identity.fingerprint,
        status: TranslationModelProbeStatus.failed,
        checkedAt: now,
        safeErrorCode: 'network_unreachable',
        reasoningControlSuppressed: true,
      ),
      expectedAccountHash: 'guest',
      providerId: 'deepseek',
      expectedToken: identity.cacheToken,
    );

    expect(
      service
          .applyCachedEvidence(
            accountHash: 'guest',
            settings: settings,
            profile: profile,
          )
          .reasoningControlSuppressed,
      isTrue,
    );
    final otherProfile = _profile(modelId: 'model-b');
    expect(
      service
          .applyCachedEvidence(
            accountHash: 'guest',
            settings: settings,
            profile: otherProfile,
          )
          .reasoningControlSuppressed,
      isFalse,
    );

    await cache.put(
      TranslationModelProbeRecord(
        fingerprint: identity.fingerprint,
        status: TranslationModelProbeStatus.failed,
        checkedAt: now.subtract(TranslationModelProbeCache.ttl),
        safeErrorCode: 'network_unreachable',
        reasoningControlSuppressed: true,
      ),
      expectedAccountHash: 'guest',
      providerId: 'deepseek',
      expectedToken: identity.cacheToken,
    );
    expect(
      service
          .applyCachedEvidence(
            accountHash: 'guest',
            settings: settings,
            profile: profile,
          )
          .reasoningControlSuppressed,
      isFalse,
    );
  });
}

TranslationModelProbeService _service(
  FakeTranslationChatService fake, {
  required TranslationModelProbeCache cache,
  required DateTime now,
}) {
  return TranslationModelProbeService(
    cache: cache,
    executorFactory: ({
      required settings,
      required profile,
      required onProfileChanged,
    }) =>
        _executor(
      fake,
      profile: profile,
      onProfileChanged: onProfileChanged,
    ),
    now: () => now,
  );
}

TranslationStreamExecutor _executor(
  FakeTranslationChatService fake, {
  required TranslationRequestProfile profile,
  Future<void> Function(TranslationRequestProfile)? onProfileChanged,
}) {
  return TranslationStreamExecutor(
    service: fake,
    profile: profile,
    onProfileChanged: onProfileChanged,
    firstEventTimeout: const Duration(seconds: 1),
    idleTimeout: const Duration(seconds: 1),
    totalTimeout: const Duration(seconds: 2),
    maxOutputTokensOverride: 128,
  );
}

Matcher _failure(String safeCode) => isA<TranslationRequestFailure>()
    .having((failure) => failure.kind, 'kind', TranslationFailureKind.cancelled)
    .having((failure) => failure.safeCode, 'safeCode', safeCode);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

AISettings _settings() {
  return AISettings(
    mode: AIMode.local,
    providers: [
      AiProvider(
        id: 'deepseek',
        type: 'openai',
        name: 'DeepSeek',
        apiKey: 'sk-secret',
        apiHost: 'https://private.example/v1',
        models: [AiModel(id: 'model-a'), AiModel(id: 'model-b')],
        selectedModelId: 'model-a',
        enabled: true,
      ),
    ],
    activeProviderId: 'deepseek',
    backendModel: 'backend-model',
    streamEnabled: true,
    resetOnLogout: true,
  );
}

TranslationRequestProfile _profile({
  String modelId = 'model-a',
  ChatReasoningPolicy reasoningPolicy = ChatReasoningPolicy.offIfSupported,
}) {
  return TranslationRequestProfile(
    mode: TranslationExecutionMode.local,
    providerId: 'deepseek',
    modelId: modelId,
    reasoningPolicy: reasoningPolicy,
    reasoningControlSuppressed: false,
  );
}

final class _ManualStopwatch extends Stopwatch {
  var _elapsedMilliseconds = 0;
  var _running = false;

  void advance(int milliseconds) {
    if (_running) _elapsedMilliseconds += milliseconds;
  }

  @override
  int get elapsedMilliseconds => _elapsedMilliseconds;

  @override
  int get elapsedMicroseconds => _elapsedMilliseconds * 1000;

  @override
  int get elapsedTicks => elapsedMicroseconds;

  @override
  Duration get elapsed => Duration(milliseconds: _elapsedMilliseconds);

  @override
  int get frequency => Duration.microsecondsPerSecond;

  @override
  bool get isRunning => _running;

  @override
  void reset() => _elapsedMilliseconds = 0;

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;
}
