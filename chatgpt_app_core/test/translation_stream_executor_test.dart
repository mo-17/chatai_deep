import 'dart:async';

import 'package:chatgpt_app_core/chat/application/translation_stream_executor.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/chat/domain/translation_request_profile.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    test('collects only text and treats every typed event as activity',
        () async {
      final service = _FakeChatService([
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
      final service = _FakeChatService([]);
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

    test('first-event timeout aborts and cancels before completing', () async {
      final service = _FakeChatService([(request) {}]);

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
      final service = _FakeChatService([
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
      final service = _FakeChatService([
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
      final service = _FakeChatService([(request) {}]);
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

    test('reasoning-only completion is invalid output', () async {
      final service = _FakeChatService([
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
      final service = _FakeChatService([
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
      final service = _FakeChatService(
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
      final service = _FakeChatService(
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
          safeCode: 'network_error',
          safeMessage: 'must not escape',
        ): TranslationFailureKind.network,
      };

      for (final entry in cases.entries) {
        final service = _FakeChatService([
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
      final service = _FakeChatService([
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
      final service = _FakeChatService(
        [
          (request) => request.errorAfter(
                const Duration(milliseconds: 1),
                const ChatTransportException(
                  statusCode: 400,
                  safeCode: 'unknown_parameter',
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
        onProfileChanged: (profile) async {
          order.add('profile:start');
          expect(profile.reasoningControlSuppressed, isTrue);
          expect(service.requests.first.abortObserved, isTrue);
          expect(service.activeSubscriptions, 0);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          order.add('profile:end');
        },
        firstEventTimeout: const Duration(milliseconds: 40),
        idleTimeout: const Duration(milliseconds: 40),
        totalTimeout: const Duration(milliseconds: 120),
      );

      final result = await executor.complete(
        'prompt',
        cancellation: TranslationCancellationController(),
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

    test('a failed suppressed retry never negotiates a third request',
        () async {
      final service = _FakeChatService([
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unsupported_parameter',
                safeMessage: 'unsupported',
              ),
            ),
        (request) => request.errorAfter(
              const Duration(milliseconds: 1),
              const ChatTransportException(
                statusCode: 400,
                safeCode: 'unknown_parameter',
                safeMessage: 'still unsupported',
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

      expect(service.requests, hasLength(2));
      expect(
          service.requests.every((request) => request.abortObserved), isTrue);
      expect(service.activeSubscriptions, 0);
    });

    test('provider-default policy does not treat unknown parameter as Thinking',
        () async {
      final service = _FakeChatService([
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
}) =>
    TranslationStreamExecutor(
      service: service,
      profile: _profile(),
      firstEventTimeout: first,
      idleTimeout: idle,
      totalTimeout: total,
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

typedef _StreamScript = void Function(_FakeRequest request);

final class _FakeChatService implements ChatService, OptionsAwareChatService {
  final List<_StreamScript> scripts;
  final void Function(int index)? onRequest;
  final Future<void> Function()? cancelCleanup;
  final List<_FakeRequest> requests = [];
  int activeSubscriptions = 0;

  _FakeChatService(
    this.scripts, {
    this.onRequest,
    this.cancelCleanup,
  });

  @override
  ModelCapabilities get capabilities => const ModelCapabilities.none();

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) =>
      throw UnsupportedError('translation must not use non-streaming chat');

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      throw UnsupportedError('translation must not use non-streaming chat');

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      throw UnsupportedError('translation must use typed stream events');

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) =>
      throw UnsupportedError('translation must pass request options');

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) {
    final index = requests.length;
    if (index >= scripts.length) {
      throw StateError('unexpected request $index');
    }
    onRequest?.call(index);
    late final _FakeRequest request;
    late final StreamController<StreamEvent> controller;
    controller = StreamController<StreamEvent>(
      onListen: () {
        activeSubscriptions += 1;
        request._markActive();
        scripts[index](request);
      },
      onCancel: () async {
        request._dispose();
        if (request._wasActive) activeSubscriptions -= 1;
        await cancelCleanup?.call();
      },
    );
    request = _FakeRequest(
      prompt: prompt,
      history: history,
      options: options,
      controller: controller,
    );
    requests.add(request);
    options.abortTrigger?.then((_) => request.abortObserved = true);
    return controller.stream;
  }
}

final class _FakeRequest {
  final String prompt;
  final List<Map<String, dynamic>> history;
  final ChatRequestOptions options;
  final StreamController<StreamEvent> _controller;
  final List<Timer> _timers = [];
  bool abortObserved = false;
  bool _active = false;
  bool _disposed = false;

  _FakeRequest({
    required this.prompt,
    required this.history,
    required this.options,
    required StreamController<StreamEvent> controller,
  }) : _controller = controller;

  bool get _wasActive {
    final wasActive = _active;
    _active = false;
    return wasActive;
  }

  void _markActive() => _active = true;

  void addAfter(Duration delay, StreamEvent event) {
    _schedule(delay, () => _controller.add(event));
  }

  void errorAfter(Duration delay, Object error) {
    _schedule(delay, () => _controller.addError(error));
  }

  void closeAfter(Duration delay) {
    _schedule(delay, _controller.close);
  }

  void _schedule(Duration delay, void Function() action) {
    _timers.add(Timer(delay, () {
      if (!_disposed) action();
    }));
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
  }
}
