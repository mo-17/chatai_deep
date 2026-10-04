import 'dart:async';
import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/agent_task_session.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<AgentTaskSession> task() async {
    final task = AgentTaskSession(cid: 7, store: _Store());
    addTearDown(task.dispose);
    await task.setEnabled(true);
    await task.begin(userAt: 101, input: '任务');
    return task;
  }

  ChatTool write(Future<ToolOutcome> Function(Map<String, dynamic>) execute) =>
      ChatTool(
          name: 'write_file',
          description: 'write',
          parameters: const {'type': 'object'},
          execute: execute);

  test(
      'checkpoint keeps final reasoning before verification and corrective tools execute once',
      () async {
    final session = await task();
    final service = _Service([
      [StreamEvent.reasoning('原始思考'), StreamEvent.text('原始回答')],
      [StreamEvent.reasoning('修正文件'), _call('w')],
      [StreamEvent.reasoning('核对完成'), StreamEvent.text('修正后回答')],
    ]);
    var writes = 0, verifications = 0;
    final phases = <String>[];
    await ToolLoopRunner(
            chatService: service,
            registry: ToolRegistry([
              write((_) async {
                writes++;
                return const ToolOutcome(content: '已写入');
              }),
            ]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            onProgress: (progress) => phases.add(progress.label),
            verifyFinal: (answer) async {
              verifications++;
              expect(session.messages.last['content'], answer);
              expect(session.messages.last['reasoning_content'],
                  verifications == 1 ? '原始思考' : '核对完成');
              return verifications == 1 ? '请创建文件' : null;
            })
        .toList();
    expect(writes, 1);
    expect(service.extra, hasLength(3));
    expect(service.extra[1][0]['reasoning_content'], '原始思考');
    expect(service.extra[1][1]['role'], 'user');
    expect(
        service.extra[2]
            .where((message) => message['role'] == 'tool')
            .single['tool_call_id'],
        'w');
    expect(phases, contains('验收未通过，正在纠错'));
  });

  test('persistent failures stop at two extra model requests and pause task',
      () async {
    final session = await task();
    final service = _Service([
      [StreamEvent.text('第一次')],
      [StreamEvent.text('第二次')],
      [StreamEvent.text('第三次')],
    ]);
    var verifications = 0;
    await ToolLoopRunner(chatService: service, registry: const ToolRegistry([]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (_) async {
              verifications++;
              return '未满足文件条件';
            })
        .toList();
    expect(service.extra, hasLength(3));
    expect(verifications, 3);
    expect(service.declarations.every((tools) => tools != null), isTrue);
    expect(session.status, 'paused');
  });

  test(
      'last corrective tool round gets local verification without a third model request',
      () async {
    final session = await task();
    final service = _Service([
      [StreamEvent.text('缺少文件')],
      [_call('a')],
      [_call('b')]
    ]);
    var writes = 0;
    final answers = <String>[];
    await ToolLoopRunner(
            chatService: service,
            registry: ToolRegistry([
              write((_) async {
                writes++;
                return const ToolOutcome(content: '写入结果');
              }),
            ]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (answer) async {
              answers.add(answer);
              return '仍未满足';
            })
        .toList();
    expect(writes, 2);
    expect(service.extra, hasLength(3));
    expect(answers, ['缺少文件', '']);
    expect(session.messages.where((message) => message['role'] == 'tool'),
        hasLength(2));
    expect(session.status, 'paused');
  });

  test(
      'exhausted tool budget verifies final but never starts no-tools correction',
      () async {
    final session = await task();
    await session.checkpoint(const [], ToolLoopRunner.maxRounds - 1);
    final service = _Service([
      [StreamEvent.text('仍失败')]
    ]);
    await ToolLoopRunner(chatService: service, registry: const ToolRegistry([]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (_) async => '失败')
        .toList();
    expect(service.extra, hasLength(1));
    expect(session.status, 'paused');
  });

  test('no-tools final request explicitly asks for a plain incomplete report',
      () async {
    final session = await task();
    await session.checkpoint(const [], ToolLoopRunner.maxRounds);
    final service = _Service([
      [StreamEvent.text('工具预算已用尽，请继续任务')]
    ]);
    await ToolLoopRunner(chatService: service, registry: const ToolRegistry([]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (_) async => '缺文件')
        .toList();
    expect(service.declarations.single, isNull);
    final note = service.extra.single.single;
    expect(note['role'], 'user');
    expect(note['content'], contains('禁止输出工具调用协议'));
    expect(note['content'], contains('尚未验收通过不可声称任务完成'));
    expect(session.status, 'paused');
    await session.finish(complete: false, requiresCorrection: true);
    await session.begin(userAt: 101, input: '任务', resume: true);
    final resumed = _Service([
      [StreamEvent.text('现在完成')]
    ]);
    await ToolLoopRunner(chatService: resumed, registry: const ToolRegistry([]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (_) async => null)
        .toList();
    expect(resumed.declarations.single, isNotNull);
    expect(
        resumed.extra.single.any((message) =>
            (message['content'] as String? ?? '').startsWith('[任务工具预算已用尽]')),
        isFalse);
  });

  test(
      'restored saved final is verified and replayed without requesting if passed',
      () async {
    final session = await task();
    await session.checkpoint([
      {'role': 'assistant', 'content': '完成', 'reasoning_content': '思考'}
    ], 2);
    final service = _Service([]);
    var verifications = 0;
    final events = await ToolLoopRunner(
            chatService: service, registry: const ToolRegistry([]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (answer) async {
              verifications++;
              expect(answer, '完成');
              return null;
            })
        .toList();
    expect(service.extra, isEmpty);
    expect(verifications, 1);
    expect(
        events
            .where((event) => event.type == StreamEventType.reasoning)
            .single
            .delta,
        '思考');
  });

  test('restored final failure reuses completed writes and requests repair',
      () async {
    final session = await task();
    await session.checkpoint([
      {
        'role': 'assistant',
        'content': '',
        'reasoning_content': '写入',
        'tool_calls': [
          {
            'id': 'w',
            'type': 'function',
            'function': {'name': 'write_file', 'arguments': '{}'}
          }
        ]
      },
      {'role': 'tool', 'tool_call_id': 'w', 'content': '已写入'},
      {'role': 'assistant', 'content': '旧最终回答', 'reasoning_content': '旧思考'},
    ], 2);
    final service = _Service([
      [StreamEvent.text('修复后回答')]
    ]);
    var writes = 0, verifications = 0;
    await ToolLoopRunner(
            chatService: service,
            registry: ToolRegistry([
              write((_) async {
                writes++;
                return const ToolOutcome(content: '不可重播');
              }),
            ]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (_) async {
              verifications++;
              return verifications == 1 ? '请核对' : null;
            })
        .toList();
    expect(writes, 0);
    expect(service.extra, hasLength(1));
    expect(
        service.extra.single
            .where((message) => message['role'] == 'tool')
            .single['content'],
        '已写入');
  });

  test(
      'cancel during final verification keeps saved final and starts no correction',
      () async {
    final session = await task();
    final abort = Completer<void>(), started = Completer<void>();
    final verdict = Completer<String?>();
    final service = _Service([
      [StreamEvent.reasoning('思考'), StreamEvent.text('答案')]
    ]);
    final run =
        ToolLoopRunner(chatService: service, registry: const ToolRegistry([]))
            .run(
                prompt: '任务',
                history: const [],
                task: session,
                abortTrigger: abort.future,
                verifyFinal: (_) {
                  started.complete();
                  return verdict.future;
                })
            .toList();
    final cancelled = expectLater(
        run,
        throwsA(isA<ChatTransportException>()
            .having((error) => error.safeCode, 'safeCode', 'cancelled')));
    await started.future;
    abort.complete();
    verdict.complete('需要修正');
    await cancelled;
    expect(service.extra, hasLength(1));
    expect(session.messages.last['reasoning_content'], '思考');
    expect(session.messages.last['role'], 'assistant');
  });

  test(
      'explicit user continuation refreshes correction budget but preserves old results',
      () async {
    final session = await task();
    await session.checkpoint([
      {'role': 'user', 'content': '[任务验收纠错]\n起始轮：4\n旧纠错'},
      {'role': 'assistant', 'content': '失败', 'reasoning_content': ''},
    ], 5);
    await session.finish(complete: false, requiresCorrection: true);
    await session.begin(userAt: 101, input: '任务', resume: true);
    expect(session.needsContinuation, isTrue);
    expect(session.nextRound, 0);
    final service = _Service([
      [StreamEvent.text('继续')],
      [StreamEvent.text('新纠错')]
    ]);
    var verifications = 0;
    await ToolLoopRunner(chatService: service, registry: const ToolRegistry([]))
        .run(
            prompt: '任务',
            history: const [],
            task: session,
            verifyFinal: (_) async {
              verifications++;
              return verifications == 1 ? '请修复' : null;
            })
        .toList();
    expect(service.extra, hasLength(2));
    expect(service.extra.first.first['content'], contains('旧纠错'));
  });
}

StreamEvent _call(String id) =>
    StreamEvent.toolCall(toolId: id, name: 'write_file', arguments: {'id': id});

class _Store implements IAgentTaskStore {
  Map<String, dynamic>? value;
  @override
  Future<Map<String, dynamic>?> read(int cid) async => value;
  @override
  Future<void> write(int cid, Map<String, dynamic> next) async {
    value = Map<String, dynamic>.from(jsonDecode(jsonEncode(next)) as Map);
  }
}

class _Service implements ChatService, OptionsAwareChatService {
  final List<List<StreamEvent>> rounds;
  final extra = <List<Map<String, dynamic>>>[];
  final declarations = <List<Map<String, dynamic>>?>[];
  _Service(this.rounds);
  @override
  ModelCapabilities get capabilities =>
      const ModelCapabilities(tool: true, reasoning: true);
  @override
  Stream<StreamEvent> chatStreamEvents(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const []}) async* {
    final index = extra.length;
    declarations.add(tools);
    extra.add([
      for (final message in jsonDecode(jsonEncode(extraMessages)) as List)
        Map<String, dynamic>.from(message as Map)
    ]);
    yield* Stream.fromIterable(rounds[index]);
  }

  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          List<Map<String, dynamic>>? tools,
          List<Map<String, dynamic>> extraMessages = const [],
          required ChatRequestOptions options}) =>
      chatStreamEvents(
          prompt: prompt,
          history: history,
          attachments: attachments,
          tools: tools,
          extraMessages: extraMessages);
  @override
  Future<String?> chat(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments,
          Duration? timeout}) async =>
      null;
  @override
  Future<ChatCompletionResult> chatWithUsage(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) async =>
      const ChatCompletionResult(content: null);
  @override
  Stream<String> chatStream(
          {required String prompt,
          required List<Map<String, dynamic>> history,
          ChatAttachments? attachments}) =>
      const Stream.empty();
}
