import 'dart:async';

import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';

typedef FakeTranslationStreamScript = void Function(
  FakeTranslationRequest request,
);

final class FakeTranslationChatService
    implements ChatService, OptionsAwareChatService {
  final List<FakeTranslationStreamScript> scripts;
  final void Function(int index)? onRequest;
  final Future<void> Function()? cancelCleanup;
  final List<FakeTranslationRequest> requests = [];
  int requestAttempts = 0;
  int activeSubscriptions = 0;

  FakeTranslationChatService(
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
    requestAttempts += 1;
    final index = requests.length;
    if (index >= scripts.length) {
      throw StateError('unexpected request $index');
    }
    onRequest?.call(index);
    late final FakeTranslationRequest request;
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
    request = FakeTranslationRequest(
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

final class FakeTranslationRequest {
  final String prompt;
  final List<Map<String, dynamic>> history;
  final ChatRequestOptions options;
  final StreamController<StreamEvent> _controller;
  final List<Timer> _timers = [];
  bool abortObserved = false;
  bool _active = false;
  bool _disposed = false;

  FakeTranslationRequest({
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

  void addNow(StreamEvent event) => _controller.add(event);

  void errorAfter(Duration delay, Object error) {
    _schedule(delay, () => _controller.addError(error));
  }

  void errorNow(Object error) => _controller.addError(error);

  void closeAfter(Duration delay) {
    _schedule(delay, _controller.close);
  }

  void closeNow() => _controller.close();

  void runAfter(Duration delay, void Function() action) {
    _schedule(delay, action);
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
