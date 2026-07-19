import 'dart:async';

import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translation_chat_service.dart';

void main() {
  test('ChatRequestOptions asserts positive max output token overrides', () {
    var assertionsEnabled = false;
    assert(assertionsEnabled = true);
    if (!assertionsEnabled) return;

    for (final invalid in [0, -1]) {
      expect(
        () => ChatRequestOptions(maxOutputTokensOverride: invalid),
        throwsA(isA<AssertionError>()),
      );
    }
  });

  group('TranslationCancellationController', () {
    test('cancel is idempotent and completes whenCancelled once', () async {
      final controller = TranslationCancellationController();

      expect(controller.isCancelled, isFalse);
      controller.cancel();
      controller.cancel();

      await controller.whenCancelled;
      expect(controller.isCancelled, isTrue);
    });
  });

  group('TranslationStreamExecutor', () {
    test('forwards an exact output token override while retaining the floor',
        () async {
      final service = FakeTranslationChatService([
        (request) {
          request.addNow(StreamEvent.text('ok'));
          request.closeNow();
        },
      ]);

      final result = await _executor(
        service,
        maxOutputTokensOverride: 128,
      ).complete(
        'translate me',
        cancellation: TranslationCancellationController(),
      );

      expect(result, 'ok');
      expect(service.requests.single.options.minOutputTokens, 2048);
      expect(service.requests.single.options.maxOutputTokensOverride, 128);
    });

    test('rejects non-positive runtime output token overrides', () {
      for (final invalid in [0, -1]) {
        expect(
          () => TranslationStreamExecutor(
            service: FakeTranslationChatService(const []),
            profile: _profile(),
            maxOutputTokensOverride: invalid,
          ),
          throwsA(
            isA<ArgumentError>()
                .having(
                    (error) => error.name, 'name', 'maxOutputTokensOverride')
                .having((error) => error.invalidValue, 'invalidValue', invalid),
          ),
        );
      }
    });

    test('fires first-event telemetry once on usage without changing output',
        () async {
      final trace = <String>[];
      var firstEventCalls = 0;
      final service = FakeTranslationChatService([
        (request) {
          request.addAfter(
            const Duration(milliseconds: 1),
            StreamEvent.usage(promptTokens: 3),
          );
          request.addAfter(
            const Duration(milliseconds: 2),
            StreamEvent.reasoning('private'),
          );
          request.addAfter(
            const Duration(milliseconds: 3),
            StreamEvent.text('translated'),
          );
          request.closeAfter(const Duration(milliseconds: 4));
        },
      ]);

      final result = await _executor(service).complete(
        'translate me',
        cancellation: TranslationCancellationController(),
        onPhase: (phase) => trace.add(phase.name),
        onFirstEvent: () {
          firstEventCalls += 1;
          trace.add('firstEvent');
          throw StateError('telemetry must not own the request');
        },
      );

      expect(result, 'translated');
      expect(firstEventCalls, 1);
      expect(trace, ['waiting', 'firstEvent', 'thinking', 'receiving']);
    });

    test('collects only text and treats every typed event as activity',
        () async {
      final service = FakeTranslationChatService([
        (request) {
          request.addAfter(
            const Duration(milliseconds: 2),
            StreamEvent.reasoning('private-reasoning'),
          );
          request.addAfter(
            const Duration(milliseconds: 22),
            StreamEvent.usage(promptTokens: 12, completionTokens: 3),
          );
          request.addAfter(
            const Duration(milliseconds: 42),
            StreamEvent.text('你'),
          );
          request.addAfter(
            const Duration(milliseconds: 62),
            StreamEvent.reasoning('more-private-reasoning'),
          );
          request.addAfter(
            const Duration(milliseconds: 82),
            StreamEvent.text('好'),
          );
          request.closeAfter(const Duration(milliseconds: 88));
        },
      ]);
      final phases = <TranslationStreamPhase>[];
      final executor = _executor(
        service,
        first: const Duration(milliseconds: 50),
        idle: const Duration(milliseconds: 35),
        total: const Duration(milliseconds: 250),
      );

      final result = await executor.complete(
        'translate me',
        cancellation: TranslationCancellationController(),
        onPhase: phases.add,
      );

      expect(result, '你好');
      expect(
        phases,
        [
          TranslationStreamPhase.waiting,
          TranslationStreamPhase.thinking,
          TranslationStreamPhase.receiving,
        ],
      );
      expect(service.activeSubscriptions, 0);
      expect(service.requests.single.abortObserved, isTrue);
      expect(service.requests.single.prompt, 'translate me');
      expect(service.requests.single.history, isEmpty);
      expect(service.requests.single.options.profile,
          ChatRequestProfile.translation);
      expect(service.requests.single.options.reasoningPolicy,
          ChatReasoningPolicy.offIfSupported);
      expect(service.requests.single.options.suppressReasoningControl, isFalse);
      expect(service.requests.single.options.minOutputTokens, 2048);
      expect(service.requests.single.options.connectTimeout,
          const Duration(milliseconds: 50));
    });

    test('does not send a request when already cancelled', () async {
      final service = FakeTranslationChatService([]);
      final cancellation = TranslationCancellationController()..cancel();

      await expectLater(
        _executor(service).complete(
          'secret prompt',
          cancellation: cancellation,
        ),
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );

      expect(service.requests, isEmpty);
    });

    test('cancellation from waiting phase is installed before any request',
        () async {
      final service = FakeTranslationChatService([]);
      final cancellation = TranslationCancellationController();

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: cancellation,
          onPhase: (phase) {
            if (phase == TranslationStreamPhase.waiting) {
              cancellation.cancel();
            }
          },
        ),
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );

      expect(service.requestAttempts, 0);
      expect(service.requests, isEmpty);
    });

    test('first-event timeout aborts and cancels before completing', () async {
      final service = FakeTranslationChatService([(request) {}]);

      await expectLater(
        _executor(
          service,
          first: const Duration(milliseconds: 20),
          idle: const Duration(milliseconds: 80),
          total: const Duration(milliseconds: 120),
        ).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.firstEventTimeout)),
      );

      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('idle timeout starts after first activity and cleans up first',
        () async {
      final service = FakeTranslationChatService([
        (request) {
          request.addAfter(
            const Duration(milliseconds: 3),
            StreamEvent.usage(promptTokens: 1),
          );
        },
      ]);

      await expectLater(
        _executor(
          service,
          first: const Duration(milliseconds: 30),
          idle: const Duration(milliseconds: 20),
          total: const Duration(milliseconds: 120),
        ).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.idleTimeout)),
      );

      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('total timeout wins while regular activity keeps idle alive',
        () async {
      final service = FakeTranslationChatService([
        (request) {
          for (var millis = 2; millis <= 72; millis += 10) {
            request.addAfter(
              Duration(milliseconds: millis),
              StreamEvent.usage(promptTokens: millis),
            );
          }
        },
      ]);

      await expectLater(
        _executor(
          service,
          first: const Duration(milliseconds: 20),
          idle: const Duration(milliseconds: 25),
          total: const Duration(milliseconds: 55),
        ).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.totalTimeout)),
      );

      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('cancellation aborts the transport and completes as cancelled',
        () async {
      final service = FakeTranslationChatService([(request) {}]);
      final cancellation = TranslationCancellationController();
      final future = _executor(
        service,
        first: const Duration(milliseconds: 100),
        idle: const Duration(milliseconds: 100),
        total: const Duration(milliseconds: 200),
      ).complete('prompt', cancellation: cancellation);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancellation.cancel();

      await expectLater(
        future,
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );
      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('a cancelled flag wins over a late text event', () async {
      final cancellation = _FlagCancellationToken();
      final service = FakeTranslationChatService([
        (request) {
          request.runAfter(const Duration(milliseconds: 2), () {
            cancellation.markCancelledWithoutSignal();
            request.addNow(StreamEvent.text('late success'));
            request.closeNow();
          });
        },
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: cancellation,
        ),
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );
      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('a cancelled flag wins over a late stream error', () async {
      final cancellation = _FlagCancellationToken();
      final service = FakeTranslationChatService([
        (request) {
          request.runAfter(const Duration(milliseconds: 2), () {
            cancellation.markCancelledWithoutSignal();
            request.errorNow(const ChatTransportException(
              statusCode: 503,
              safeCode: 'server_error',
              safeMessage: 'late failure',
            ));
          });
        },
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: cancellation,
        ),
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );
      expect(service.requests.single.abortObserved, isTrue);
    });

    test('a cancelled flag wins over onDone after collected text', () async {
      final cancellation = _FlagCancellationToken();
      final service = FakeTranslationChatService([
        (request) {
          request.addAfter(
            const Duration(milliseconds: 1),
            StreamEvent.text('would otherwise succeed'),
          );
          request.runAfter(const Duration(milliseconds: 3), () {
            cancellation.markCancelledWithoutSignal();
            request.closeNow();
          });
        },
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: cancellation,
        ),
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );
      expect(service.requests.single.abortObserved, isTrue);
    });

    test('an arbitrary cancellation Future error is consumed as cancellation',
        () async {
      final cancellation = _ErrorCancellationToken(
        StateError('https://secret.example/cancellation'),
      );
      final service = FakeTranslationChatService([(request) {}]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: cancellation,
        ),
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );

      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('reasoning-only completion is invalid output', () async {
      final service = FakeTranslationChatService([
        (request) {
          request.addAfter(
            const Duration(milliseconds: 2),
            StreamEvent.reasoning('not translation'),
          );
          request.closeAfter(const Duration(milliseconds: 4));
        },
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.invalidOutput)),
      );
      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('whitespace-only text completion is invalid output', () async {
      final service = FakeTranslationChatService([
        (request) {
          request.addAfter(
            const Duration(milliseconds: 2),
            StreamEvent.text('  \n\t'),
          );
          request.closeAfter(const Duration(milliseconds: 4));
        },
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.invalidOutput)),
      );
      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('subscription cleanup errors cannot replace a terminal failure',
        () async {
      final service = FakeTranslationChatService(
        [(request) {}],
        cancelCleanup: () => Future<void>.error(
          StateError('https://secret.example/cleanup'),
        ),
      );

      await expectLater(
        _executor(
          service,
          first: const Duration(milliseconds: 20),
          idle: const Duration(milliseconds: 80),
          total: const Duration(milliseconds: 120),
        ).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.firstEventTimeout)),
      );

      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('subscription cleanup that never completes cannot strand the result',
        () async {
      final cleanup = Completer<void>();
      final service = FakeTranslationChatService(
        [(request) {}],
        cancelCleanup: () => cleanup.future,
      );

      await expectLater(
        _executor(
          service,
          first: const Duration(milliseconds: 20),
          idle: const Duration(milliseconds: 80),
          total: const Duration(milliseconds: 120),
        )
            .complete(
              'prompt',
              cancellation: TranslationCancellationController(),
            )
            .timeout(const Duration(milliseconds: 80)),
        throwsA(_failure(TranslationFailureKind.firstEventTimeout)),
      );

      expect(cleanup.isCompleted, isFalse);
      expect(service.requests.single.abortObserved, isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('maps transport failures to typed safe failures', () async {
      final cases = <ChatTransportException, TranslationFailureKind>{
        const ChatTransportException(
          statusCode: 401,
          safeCode: 'authentication_error',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.authentication,
        const ChatTransportException(
          statusCode: 400,
          safeCode: 'invalid_request',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.invalidRequest,
        const ChatTransportException(
          statusCode: 429,
          retryAfter: Duration(seconds: 9),
          safeCode: 'rate_limited',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.rateLimited,
        const ChatTransportException(
          statusCode: 503,
          safeCode: 'server_error',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.server,
        const ChatTransportException(
          statusCode: 504,
          safeCode: 'first_event_timeout',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.firstEventTimeout,
        const ChatTransportException(
          statusCode: 504,
          safeCode: 'idle_timeout',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.idleTimeout,
        const ChatTransportException(
          statusCode: 504,
          safeCode: 'total_timeout',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.totalTimeout,
        const ChatTransportException(
          safeCode: 'network_error',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.network,
      };

      for (final entry in cases.entries) {
        final service = FakeTranslationChatService([
          (request) => request.errorAfter(
                const Duration(milliseconds: 1),
                entry.key,
              ),
        ]);

        try {
          await _executor(service).complete(
            'private prompt',
            cancellation: TranslationCancellationController(),
          );
          fail('expected ${entry.value}');
        } on TranslationRequestFailure catch (failure) {
          expect(failure.kind, entry.value);
          expect(failure.statusCode, entry.key.statusCode);
          expect(failure.retryAfter, entry.key.retryAfter);
          expect(failure.toString(), isNot(contains('must not escape')));
          expect(failure.toString(), isNot(contains('private prompt')));
        }
      }
    });

    test('sanitizes unknown transport metadata and never retains its cause',
        () async {
      const secret = 'https://secret.example/key=top-secret';
      final service = FakeTranslationChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                safeCode: secret,
                safeMessage: secret,
              ),
            ),
      ]);

      try {
        await _executor(service).complete(
          'prompt contains secret',
          cancellation: TranslationCancellationController(),
        );
        fail('expected failure');
      } on TranslationRequestFailure catch (failure) {
        expect(failure.kind, TranslationFailureKind.network);
        expect(failure.safeCode, 'request_failed');
        expect(failure.toString(), isNot(contains(secret)));
        expect(failure.toString(), isNot(contains('prompt contains secret')));
      }
    });

    test('unsupported Thinking control is persisted before one clean retry',
        () async {
      final order = <String>[];
      final service = FakeTranslationChatService(
        [
          (request) => request.errorAfter(
                const Duration(milliseconds: 1),
                const ChatTransportException(
                  statusCode: 400,
                  safeCode: 'unsupported_reasoning_control',
                  safeMessage: 'unsupported',
                ),
              ),
          (request) {
            request.addAfter(
              const Duration(milliseconds: 1),
              StreamEvent.text('已翻译'),
            );
            request.closeAfter(const Duration(milliseconds: 2));
          },
        ],
        onRequest: (index) => order.add('request:$index'),
      );
      final executor = TranslationStreamExecutor(
        service: service,
        profile: _profile(),
        firstEventTimeout: const Duration(milliseconds: 40),
        idleTimeout: const Duration(milliseconds: 40),
        totalTimeout: const Duration(milliseconds: 120),
      );

      final result = await executor.complete(
        'prompt',
        cancellation: TranslationCancellationController(),
        onProfileChanged: (profile) async {
          order.add('profile:start');
          expect(profile.reasoningControlSuppressed, isTrue);
          expect(service.requests.first.abortObserved, isTrue);
          expect(service.activeSubscriptions, 0);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          order.add('profile:end');
        },
      );

      expect(result, '已翻译');
      expect(order, [
        'request:0',
        'profile:start',
        'profile:end',
        'request:1',
      ]);
      expect(service.requests, hasLength(2));
      expect(service.requests[0].options.suppressReasoningControl, isFalse);
      expect(service.requests[1].options.suppressReasoningControl, isTrue);
      expect(
        identical(
          service.requests[0].options.abortTrigger,
          service.requests[1].options.abortTrigger,
        ),
        isFalse,
      );
      expect(
          service.requests.every((request) => request.abortObserved), isTrue);
    });

    test('failed profile persistence does not commit suppression in memory',
        () async {
      final service = FakeTranslationChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unsupported_reasoning_control',
                safeMessage: 'unsupported',
              ),
            ),
        (request) {
          request.addAfter(
            const Duration(milliseconds: 1),
            StreamEvent.text('second call'),
          );
          request.closeAfter(const Duration(milliseconds: 2));
        },
      ]);
      final executor = TranslationStreamExecutor(
        service: service,
        profile: _profile(),
        onProfileChanged: (_) => Future<void>.error(
          StateError('SECRET persistence failure'),
        ),
        firstEventTimeout: const Duration(milliseconds: 40),
        idleTimeout: const Duration(milliseconds: 40),
        totalTimeout: const Duration(milliseconds: 120),
      );

      await expectLater(
        executor.complete(
          'first',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.network)),
      );
      final second = await executor.complete(
        'second',
        cancellation: TranslationCancellationController(),
      );

      expect(second, 'second call');
      expect(service.requests, hasLength(2));
      expect(service.requests[0].options.suppressReasoningControl, isFalse);
      expect(service.requests[1].options.suppressReasoningControl, isFalse);
    });

    test('rejects concurrent complete calls without sending a second request',
        () async {
      final service = FakeTranslationChatService([(request) {}]);
      final firstCancellation = TranslationCancellationController();
      final executor = _executor(
        service,
        first: const Duration(milliseconds: 200),
        idle: const Duration(milliseconds: 200),
        total: const Duration(milliseconds: 400),
      );
      final first = executor.complete(
        'first',
        cancellation: firstCancellation,
      );
      final firstExpectation = expectLater(
        first,
        throwsA(_failure(TranslationFailureKind.cancelled)),
      );
      await _waitFor(() => service.requests.isNotEmpty);

      await expectLater(
        executor.complete(
          'second',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.invalidRequest)),
      );
      expect(service.requestAttempts, 1);
      expect(service.requests, hasLength(1));

      firstCancellation.cancel();
      await firstExpectation;
    });

    test('a failed suppressed retry never negotiates a third request',
        () async {
      final service = FakeTranslationChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unsupported_reasoning_control',
                safeMessage: 'unsupported',
              ),
            ),
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unsupported_reasoning_control',
                safeMessage: 'still unsupported',
              ),
            ),
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(
          _failure(TranslationFailureKind.unsupportedReasoningControl),
        ),
      );

      expect(service.requests, hasLength(2));
      expect(
          service.requests.every((request) => request.abortObserved), isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('raw unknown parameter never triggers Thinking negotiation', () async {
      final service = FakeTranslationChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unknown_parameter',
                safeMessage: 'unsupported',
              ),
            ),
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.invalidRequest)),
      );

      expect(service.requests, hasLength(1));
      expect(service.requests.single.abortObserved, isTrue);
    });

    test('reasoning-control code without exact 400 never negotiates', () async {
      final service = FakeTranslationChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 422,
                safeCode: 'unsupported_reasoning_control',
                safeMessage: 'unsupported',
              ),
            ),
      ]);

      await expectLater(
        _executor(service).complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.invalidRequest)),
      );

      expect(service.requests, hasLength(1));
    });

    test('provider-default policy does not treat unknown parameter as Thinking',
        () async {
      final service = FakeTranslationChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unknown_parameter',
                safeMessage: 'unsupported',
              ),
            ),
      ]);
      final executor = TranslationStreamExecutor(
        service: service,
        profile: _profile(
          reasoningPolicy: ChatReasoningPolicy.providerDefault,
        ),
        firstEventTimeout: const Duration(milliseconds: 40),
        idleTimeout: const Duration(milliseconds: 40),
        totalTimeout: const Duration(milliseconds: 120),
      );

      await expectLater(
        executor.complete(
          'prompt',
          cancellation: TranslationCancellationController(),
        ),
        throwsA(_failure(TranslationFailureKind.invalidRequest)),
      );
      expect(service.requests, hasLength(1));
    });
  });
}

TranslationStreamExecutor _executor(
  ChatService service, {
  Duration first = const Duration(milliseconds: 40),
  Duration idle = const Duration(milliseconds: 40),
  Duration total = const Duration(milliseconds: 120),
  int? maxOutputTokensOverride,
}) =>
    TranslationStreamExecutor(
      service: service,
      profile: _profile(),
      firstEventTimeout: first,
      idleTimeout: idle,
      totalTimeout: total,
      maxOutputTokensOverride: maxOutputTokensOverride,
    );

TranslationRequestProfile _profile({
  ChatReasoningPolicy reasoningPolicy = ChatReasoningPolicy.offIfSupported,
  bool suppressed = false,
}) =>
    TranslationRequestProfile(
      mode: TranslationExecutionMode.local,
      providerId: 'deepseek',
      modelId: 'deepseek-chat',
      reasoningPolicy: reasoningPolicy,
      reasoningControlSuppressed: suppressed,
    );

Matcher _failure(TranslationFailureKind kind) =>
    isA<TranslationRequestFailure>()
        .having((failure) => failure.kind, 'kind', kind);

final class _FlagCancellationToken implements TranslationCancellationToken {
  final Completer<void> _signal = Completer<void>();
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancelled => _signal.future;

  void markCancelledWithoutSignal() => _cancelled = true;
}

final class _ErrorCancellationToken implements TranslationCancellationToken {
  final Object error;

  const _ErrorCancellationToken(this.error);

  @override
  bool get isCancelled => false;

  @override
  Future<void> get whenCancelled => Future<void>.error(error);
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('test condition was not reached');
}
