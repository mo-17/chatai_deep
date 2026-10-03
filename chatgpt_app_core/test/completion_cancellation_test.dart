import 'dart:async';

import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('普通对话把取消信号与图片附件传入 options transport', () async {
    final abort = Completer<void>();
    const attachments = ChatAttachments(images: ['data:image/png;base64,eA==']);
    final service = _CapturingService([
      [StreamEvent.text('answer')],
    ]);
    final dao =
        CompletionDao(settings: AISettings.defaults(), chatService: service);

    final events = await dao
        .streamCompletionEvents(
          prompt: '分析图片',
          attachments: attachments,
          abortTrigger: abort.future,
        )
        .toList();

    expect(events.single.delta, 'answer');
    expect(service.legacyCalls, 0);
    expect(service.options.single.abortTrigger, same(abort.future));
    expect(service.options.single.profile, ChatRequestProfile.standard);
    expect(service.attachments.single, same(attachments));
    expect(service.histories.single.first['role'], 'system');
  });

  test('未传取消信号的普通对话保留旧 transport 入口', () async {
    final service = _CapturingService([
      [StreamEvent.text('answer')],
    ]);
    await CompletionDao(settings: AISettings.defaults(), chatService: service)
        .streamCompletionEvents(prompt: 'q')
        .toList();

    expect(service.legacyCalls, 1);
    expect(service.options, isEmpty);
  });

  test('CompletionDao 工具回路的每轮共用同一个取消信号', () async {
    final abort = Completer<void>();
    final service = _CapturingService([
      [_call('first')],
      [StreamEvent.text('done')],
    ]);
    final events = await CompletionDao(
            settings: AISettings.defaults(), chatService: service)
        .streamCompletionEvents(
          prompt: 'q',
          tools: ToolRegistry([_tool()]),
          abortTrigger: abort.future,
        )
        .toList();

    expect(events.last.delta, 'done');
    expect(service.legacyCalls, 0);
    expect(service.options, hasLength(2));
    for (final options in service.options) {
      expect(options.abortTrigger, same(abort.future));
    }
    expect(service.extraMessages.last.last['role'], 'tool');
  });

  test('未传取消信号的工具回路保留每轮旧 transport 入口', () async {
    final service = _CapturingService([
      [_call('first')],
      [StreamEvent.text('done')],
    ]);
    await ToolLoopRunner(
            chatService: service, registry: ToolRegistry([_tool()]))
        .run(prompt: 'q', history: const []).toList();

    expect(service.legacyCalls, 2);
    expect(service.options, isEmpty);
  });

  test('首轮结束时取消，不执行尚未开始的工具或后续请求', () async {
    final abort = Completer<void>();
    var executions = 0;
    final service = _CapturingService(
      [
        [_call('first')]
      ],
      afterRound: (_) => abort.complete(),
    );
    final result = ToolLoopRunner(
      chatService: service,
      registry: ToolRegistry([
        _tool(execute: (_) async {
          executions++;
          return const ToolOutcome(content: 'unused');
        }),
      ]),
    ).run(prompt: 'q', history: const [], abortTrigger: abort.future).toList();

    await expectLater(result, throwsA(_cancelled));
    expect(service.options, hasLength(1));
    expect(executions, 0);
  });

  test('工具等待期间取消，停止余下工具与下一轮请求', () async {
    final abort = Completer<void>();
    final started = Completer<void>();
    final release = Completer<ToolOutcome>();
    var executions = 0;
    final service = _CapturingService([
      [_call('first'), _call('second')],
      [StreamEvent.text('must not request')],
    ]);
    final result = ToolLoopRunner(
      chatService: service,
      registry: ToolRegistry([
        _tool(execute: (_) {
          executions++;
          started.complete();
          return release.future;
        }),
      ]),
    ).run(prompt: 'q', history: const [], abortTrigger: abort.future).toList();
    final expectation = expectLater(result, throwsA(_cancelled));

    await started.future;
    abort.complete();
    release
        .complete(const ToolOutcome(content: 'completed after cancellation'));
    await expectation;

    expect(executions, 1);
    expect(service.options, hasLength(1));
  });

  test('开始前已取消，工具回路不发出首轮请求', () async {
    final abort = Completer<void>()..complete();
    final service = _CapturingService([
      [StreamEvent.text('must not request')],
    ]);
    final result =
        ToolLoopRunner(chatService: service, registry: ToolRegistry([_tool()]))
            .run(prompt: 'q', history: const [], abortTrigger: abort.future)
            .toList();

    await expectLater(result, throwsA(_cancelled));
    expect(service.options, isEmpty);
    expect(service.legacyCalls, 0);
  });
}

final _cancelled = isA<ChatTransportException>()
    .having((error) => error.safeCode, 'safeCode', 'cancelled');

StreamEvent _call(String id) =>
    StreamEvent.toolCall(toolId: id, name: 'echo', arguments: const {});

ChatTool _tool({Future<ToolOutcome> Function(Map<String, dynamic>)? execute}) =>
    ChatTool(
      name: 'echo',
      description: '',
      parameters: const {'type': 'object'},
      execute: execute ?? (_) async => const ToolOutcome(content: 'echo'),
    );

class _CapturingService implements ChatService, OptionsAwareChatService {
  final List<List<StreamEvent>> rounds;
  final void Function(int)? afterRound;
  final options = <ChatRequestOptions>[];
  final attachments = <ChatAttachments?>[];
  final histories = <List<Map<String, dynamic>>>[];
  final extraMessages = <List<Map<String, dynamic>>>[];
  int legacyCalls = 0;

  _CapturingService(this.rounds, {this.afterRound});

  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
    required ChatRequestOptions options,
  }) {
    this.options.add(options);
    return _respond(history, attachments, extraMessages);
  }

  @override
  Stream<StreamEvent> chatStreamEvents({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>> extraMessages = const [],
  }) {
    legacyCalls++;
    return _respond(history, attachments, extraMessages);
  }

  Stream<StreamEvent> _respond(List<Map<String, dynamic>> history,
      ChatAttachments? attachments, List<Map<String, dynamic>> extra) async* {
    final round = histories.length;
    histories.add(List.of(history));
    this.attachments.add(attachments);
    extraMessages.add(List.of(extra));
    yield* Stream.fromIterable(rounds[round]);
    afterRound?.call(round);
    await Future<void>.value();
  }

  @override
  Future<String?> chat({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
    Duration? timeout,
  }) async =>
      null;

  @override
  Future<ChatCompletionResult> chatWithUsage({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) async =>
      const ChatCompletionResult(content: null);

  @override
  Stream<String> chatStream({
    required String prompt,
    required List<Map<String, dynamic>> history,
    ChatAttachments? attachments,
  }) =>
      const Stream.empty();
}
