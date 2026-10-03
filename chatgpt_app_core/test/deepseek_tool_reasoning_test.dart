import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

const _tools = [
  {
    'type': 'function',
    'function': {
      'name': 'echo',
      'description': 'echo',
      'parameters': {'type': 'object', 'properties': {}},
    },
  },
];

void main() {
  test(
      'thinking tool loop replays exact reasoning and checkpoints final answer',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies, (round) {
      if (round == 0) {
        return [
          {'reasoning_content': '先确认'},
          {'reasoning_content': '输入。'},
          {
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'echo', 'arguments': '{"value":'},
              },
            ],
          },
          {
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': '"ok"}'},
              },
            ],
          },
        ];
      }
      return [
        {'reasoning_content': '工具结果可靠。'},
        {'content': '完成'},
      ];
    });
    addTearDown(() => server.close(force: true));
    final snapshots = <List<Map<String, dynamic>>>[];
    final events = await ToolLoopRunner(
      chatService: _service(server),
      registry: ToolRegistry([
        ChatTool(
          name: 'echo',
          description: 'echo',
          parameters: const {'type': 'object'},
          execute: (arguments) async => ToolOutcome(
            content: arguments['value'] as String,
          ),
        ),
      ]),
    )
        .run(
          prompt: '检查输入',
          history: const [],
          onProtocolMessages: (messages) async {
            // 回调为异步落库留出等待点。
            await Future<void>.value();
            snapshots.add(messages);
          },
        )
        .toList();

    expect(bodies, hasLength(2));
    expect(bodies.every((body) => !body.containsKey('thinking')), isTrue);
    final replay = (bodies[1]['messages'] as List).skip(1).toList();
    expect(replay[0]['role'], 'assistant');
    expect(replay[0]['content'], '');
    expect(replay[0]['reasoning_content'], '先确认输入。');
    expect(
        replay[0]['tool_calls'][0]['function']['arguments'], '{"value":"ok"}');
    expect(
        replay[1], {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'ok'});
    expect(
        events
            .where((event) => event.type == StreamEventType.reasoning)
            .map((event) => event.delta),
        ['先确认', '输入。', '工具结果可靠。']);
    expect(snapshots, hasLength(2));
    expect(snapshots.first, hasLength(2));
    expect(snapshots.last, hasLength(3));
    expect(snapshots.last.last, {
      'role': 'assistant',
      'content': '完成',
      'reasoning_content': '工具结果可靠。',
    });
    // 之前的 checkpoint 不会因后续轮次追加而改变。
    expect(snapshots.first.last['role'], 'tool');
  });

  test(
      'complete reasoning on ordinary and tool history keeps provider thinking',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies, (_) => []);
    addTearDown(() => server.close(force: true));
    final history = <Map<String, dynamic>>[
      {'role': 'assistant', 'content': '原回答', 'reasoning_content': '原思考'},
      {
        'role': 'assistant',
        'content': '',
        'reasoning_content': '需要查资料',
        'tool_calls': [
          {
            'id': 'old_call',
            'type': 'function',
            'function': {'name': 'echo', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'old_call', 'content': '结果'},
      {'role': 'assistant', 'content': '旧结果', 'reasoning_content': ''},
    ];
    for (final model in ['deepseek-flash', 'deepseek-v4-pro']) {
      await _service(server, model: model)
          .chatStreamEvents(prompt: '继续', history: history, tools: _tools)
          .drain<void>();
    }
    expect(bodies, hasLength(2));
    for (final body in bodies) {
      expect(body.containsKey('thinking'), isFalse);
      expect((body['messages'] as List).take(history.length).toList(), history);
    }
  });

  test('legacy assistant without reasoning safely disables thinking with tools',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies, (_) => []);
    addTearDown(() => server.close(force: true));
    await _service(server)
        .chatStreamEvents(
          prompt: '继续',
          history: const [
            {'role': 'assistant', 'content': '旧回答'},
          ],
          tools: _tools,
        )
        .drain<void>();
    // 旧工具历史即使当前是无 tools 的收尾轮，也保留兼容路径。
    await _service(server).chatStreamEvents(
      prompt: '继续',
      history: const [
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'old_call',
              'type': 'function',
              'function': {'name': 'echo', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'old_call', 'content': '旧结果'},
      ],
    ).drain<void>();
    expect(bodies, hasLength(2));
    expect(bodies.map((body) => body['thinking']),
        everyElement({'type': 'disabled'}));
  });

  test(
      'ordinary legacy chats without tools and custom providers stay unchanged',
      () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies, (_) => []);
    addTearDown(() => server.close(force: true));
    const history = [
      {'role': 'assistant', 'content': '旧回答'},
    ];
    await _service(server)
        .chatStreamEvents(prompt: '继续', history: history)
        .drain<void>();
    await _service(server, providerId: 'openrouter')
        .chatStreamEvents(prompt: '继续', history: history, tools: _tools)
        .drain<void>();
    expect(bodies.map((body) => body.containsKey('thinking')),
        everyElement(isFalse));
  });
}

DirectChatService _service(
  HttpServer server, {
  String model = 'deepseek-flash',
  String providerId = 'deepseek',
}) =>
    DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: model,
      ),
      providerId: providerId,
      providerCode: 'deepseek',
    );

Future<HttpServer> _server(
  List<Map<String, dynamic>> bodies,
  List<Map<String, dynamic>> Function(int round) deltas,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    final round = bodies.length;
    bodies.add(body);
    request.response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    for (final delta in deltas(round)) {
      request.response.write('data: ${jsonEncode({
            'choices': [
              {'delta': delta},
            ],
          })}\n\n');
    }
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  });
  return server;
}
