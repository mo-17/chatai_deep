import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/reasoning_control_adapter.dart';
import 'package:chatgpt_app_core/chat/application/tool_loop_runner.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/deepseek_reasoning_effort.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('旧设置与非法等级保持默认，四档 JSON 与 clone 保留', () {
    for (final invalid in <Object?>[null, true, 1, [], {}, 'medium', 'HIGH']) {
      final restored = AISettings.fromJson(AISettings.defaults().toJson()
        ..['deepSeekReasoningEffort'] = invalid);
      expect(restored.deepSeekReasoningEffort, isNull, reason: '$invalid');
      expect(restored.toJson().containsKey('deepSeekReasoningEffort'), isFalse);
    }
    for (final effort in DeepSeekReasoningEffort.values) {
      final settings = AISettings.defaults()..deepSeekReasoningEffort = effort;
      expect(settings.toJson()['deepSeekReasoningEffort'], effort.wireValue);
      expect(settings.clone().deepSeekReasoningEffort, effort);
      expect(DeepSeekReasoningEffort.parse(effort.wireValue), effort);
      expect(effort.label, isNotEmpty);
    }
    final legacy = AISettings.fromJson({
      'localProvider': 'deepseek',
      'deepseek': {'model': 'deepseek-chat'},
    });
    expect(legacy.deepSeekReasoningEffort, isNull);
  });

  test('等级仅允许 DeepSeek 官方双模式模型，翻译关闭与抑制优先', () {
    ReasoningControlDecision resolve(
      DeepSeekReasoningEffort effort, {
      String providerId = 'deepseek',
      String modelId = 'deepseek-flash',
      ChatReasoningPolicy policy = ChatReasoningPolicy.providerDefault,
      bool suppressed = false,
    }) =>
        ReasoningControlAdapter.resolve(
          providerId: providerId,
          providerCode: 'deepseek',
          modelId: modelId,
          policy: policy,
          suppressed: suppressed,
          deepSeekReasoningEffort: effort,
        );
    for (final effort in DeepSeekReasoningEffort.values) {
      _expectDirectFields(resolve(effort).requestFields, effort);
      expect(resolve(effort, providerId: 'openrouter').requestFields, isEmpty);
      expect(resolve(effort, providerId: 'custom_1').requestFields, isEmpty);
      expect(
          resolve(effort, modelId: 'deepseek-reasoner').requestFields, isEmpty);
      expect(resolve(effort, suppressed: true).requestFields, isEmpty);
      _expectDirectFields(
          resolve(effort, policy: ChatReasoningPolicy.offIfSupported)
              .requestFields,
          DeepSeekReasoningEffort.off);
    }
  });

  for (final effort in [null, ...DeepSeekReasoningEffort.values]) {
    test('所有直连入口从 AISettings 获取默认等级 $effort', () async {
      final bodies = <Map<String, dynamic>>[];
      final server = await _server(bodies);
      addTearDown(() => server.close(force: true));
      final service = ChatService.from(_settings(server, effort));
      await service.chat(prompt: 'plain', history: const []);
      await service.chatWithUsage(prompt: 'usage', history: const []);
      await service
          .chatStream(prompt: 'stream', history: const []).drain<void>();
      await service
          .chatStreamEvents(prompt: 'typed', history: const []).drain<void>();
      await service.chatWithUsageWithOptions(
          prompt: 'usage options',
          history: const [],
          options: const ChatRequestOptions());
      await service
          .chatStreamEventsWithOptions(
            prompt: 'typed options',
            history: const [],
            options: const ChatRequestOptions(),
          )
          .drain<void>();
      expect(bodies, hasLength(6));
      for (final body in bodies) {
        _expectDirectFields(body, effort);
      }
    });
  }

  test('单请求等级覆盖、翻译关闭、抑制在流式和非流式保持一致', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies);
    addTearDown(() => server.close(force: true));
    final service =
        ChatService.from(_settings(server, DeepSeekReasoningEffort.max));
    for (final options in [
      const ChatRequestOptions(
          deepSeekReasoningEffort: DeepSeekReasoningEffort.low),
      const ChatRequestOptions(
          profile: ChatRequestProfile.translation,
          reasoningPolicy: ChatReasoningPolicy.offIfSupported),
      const ChatRequestOptions(suppressReasoningControl: true),
    ]) {
      await service.chatWithUsageWithOptions(
          prompt: 'usage', history: const [], options: options);
      await service
          .chatStreamEventsWithOptions(
              prompt: 'stream', history: const [], options: options)
          .drain<void>();
    }
    expect(bodies, hasLength(6));
    _expectDirectFields(bodies[0], DeepSeekReasoningEffort.low);
    _expectDirectFields(bodies[1], DeepSeekReasoningEffort.low);
    _expectDirectFields(bodies[2], DeepSeekReasoningEffort.off);
    _expectDirectFields(bodies[3], DeepSeekReasoningEffort.off);
    _expectDirectFields(bodies[4], null);
    _expectDirectFields(bodies[5], null);
  });

  test('非 DeepSeek 模型与第三方服务商实际请求不携带默认等级', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies);
    addTearDown(() => server.close(force: true));
    for (final providerId in ['openai', 'openrouter', 'custom_1', 'deepseek']) {
      final settings = _settings(server, DeepSeekReasoningEffort.max);
      if (providerId == 'deepseek') {
        settings.activeProvider.selectedModelId = 'deepseek-reasoner';
      } else {
        settings.providers = [
          AiProvider.fromJson(
              settings.activeProvider.toJson()..['id'] = providerId),
        ];
        settings.activeProviderId = providerId;
      }
      final service = ChatService.from(settings);
      await service.chatWithUsage(prompt: 'usage', history: const []);
      await service
          .chatStreamEvents(prompt: 'stream', history: const []).drain<void>();
    }
    expect(bodies, hasLength(8));
    for (final body in bodies) {
      _expectDirectFields(body, null);
    }
  });

  test('工具回路每轮传送等级并原样回传思考内容', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies, toolLoop: true);
    addTearDown(() => server.close(force: true));
    await ToolLoopRunner(
      chatService:
          ChatService.from(_settings(server, DeepSeekReasoningEffort.max)),
      registry: ToolRegistry([
        ChatTool(
          name: 'echo',
          description: 'echo',
          parameters: const {'type': 'object'},
          execute: (_) async => const ToolOutcome(content: 'ok'),
        ),
      ]),
    )
        .run(prompt: 'tool test', history: const [], onProgress: (_) {})
        .drain<void>();
    expect(bodies, hasLength(2));
    for (final body in bodies) {
      _expectDirectFields(body, DeepSeekReasoningEffort.max);
    }
    final replay = (bodies.last['messages'] as List)
        .where((m) => m['role'] == 'assistant');
    expect(replay.single['reasoning_content'], 'thought');
    expect(replay.single['tool_calls'], isNotEmpty);
  });

  test('旧工具历史缺思考内容时安全降级并移除所选等级', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies);
    addTearDown(() => server.close(force: true));
    final service =
        ChatService.from(_settings(server, DeepSeekReasoningEffort.max));
    const history = [
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
      {'role': 'tool', 'tool_call_id': 'old_call', 'content': 'old'},
    ];
    await service.chatWithUsage(prompt: 'usage', history: history);
    await service
        .chatStreamEvents(prompt: 'stream', history: history)
        .drain<void>();
    for (final body in bodies) {
      _expectDirectFields(body, DeepSeekReasoningEffort.off);
    }
    expect(history.first.containsKey('reasoning_content'), isFalse);
  });

  for (final effort in [
    DeepSeekReasoningEffort.low,
    DeepSeekReasoningEffort.high,
    DeepSeekReasoningEffort.max,
  ]) {
    test('旧普通对话显式 $effort 为请求副本补空思考字段，所有入口均保持等级', () async {
      final bodies = <Map<String, dynamic>>[];
      final server = await _server(bodies);
      addTearDown(() => server.close(force: true));
      final service = ChatService.from(_settings(server, effort));
      const history = [
        {'role': 'assistant', 'content': '旧普通回答'},
        {'role': 'assistant', 'content': '已有思考的回答', 'reasoning_content': '原文'},
      ];
      final original = jsonEncode(history);
      await service.chat(prompt: 'plain', history: history);
      await service.chatWithUsage(prompt: 'usage', history: history);
      await service
          .chatStream(prompt: 'plain stream', history: history)
          .drain<void>();
      await service.chatWithUsageWithOptions(
          prompt: 'usage options',
          history: history,
          options: const ChatRequestOptions());
      await service
          .chatStreamEvents(
              prompt: 'stream with tools', history: history, tools: _tools)
          .drain<void>();
      await service
          .chatStreamEventsWithOptions(
              prompt: 'stream options with tools',
              history: history,
              tools: _tools,
              options: const ChatRequestOptions())
          .drain<void>();
      expect(bodies, hasLength(6));
      for (final body in bodies) {
        _expectDirectFields(body, effort);
        final messages = body['messages'] as List;
        expect(messages.first['reasoning_content'], '');
        expect(messages[1]['reasoning_content'], '原文');
      }
      expect(jsonEncode(history), original);
    });
  }

  test('同一普通历史 off 切回 low 后可带工具思考，原历史保持不变', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies);
    addTearDown(() => server.close(force: true));
    final service =
        ChatService.from(_settings(server, DeepSeekReasoningEffort.off));
    const history = [
      {'role': 'assistant', 'content': '关闭思考的回答'},
    ];
    await service
        .chatStreamEvents(prompt: 'off', history: history, tools: _tools)
        .drain<void>();
    await service
        .chatStreamEventsWithOptions(
            prompt: 'low',
            history: history,
            tools: _tools,
            options: const ChatRequestOptions(
                deepSeekReasoningEffort: DeepSeekReasoningEffort.low))
        .drain<void>();
    _expectDirectFields(bodies.first, DeepSeekReasoningEffort.off);
    expect(
        (bodies.first['messages'] as List)
            .first
            .containsKey('reasoning_content'),
        isFalse);
    _expectDirectFields(bodies.last, DeepSeekReasoningEffort.low);
    expect((bodies.last['messages'] as List).first['reasoning_content'], '');
    expect(history.first.containsKey('reasoning_content'), isFalse);
  });

  test('默认、off、抑制与翻译关闭不会补普通历史思考字段', () async {
    final bodies = <Map<String, dynamic>>[];
    final server = await _server(bodies);
    addTearDown(() => server.close(force: true));
    const history = [
      {'role': 'assistant', 'content': '普通回答'},
    ];
    final scenarios = [
      (null, const ChatRequestOptions()),
      (DeepSeekReasoningEffort.off, const ChatRequestOptions()),
      (
        DeepSeekReasoningEffort.low,
        const ChatRequestOptions(suppressReasoningControl: true)
      ),
      (
        DeepSeekReasoningEffort.max,
        const ChatRequestOptions(
            profile: ChatRequestProfile.translation,
            reasoningPolicy: ChatReasoningPolicy.offIfSupported)
      ),
    ];
    for (final (effort, options) in scenarios) {
      final service = ChatService.from(_settings(server, effort));
      await service.chatWithUsageWithOptions(
          prompt: 'usage', history: history, options: options);
      await service
          .chatStreamEventsWithOptions(
              prompt: 'stream',
              history: history,
              tools: _tools,
              options: options)
          .drain<void>();
    }
    expect(bodies, hasLength(8));
    for (final body in bodies) {
      expect((body['messages'] as List).first.containsKey('reasoning_content'),
          isFalse);
    }
  });
}

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

void _expectDirectFields(
    Map<String, dynamic> body, DeepSeekReasoningEffort? effort) {
  if (effort == null) {
    expect(body.containsKey('thinking'), isFalse);
    expect(body.containsKey('reasoning_effort'), isFalse);
  } else if (effort == DeepSeekReasoningEffort.off) {
    expect(body['thinking'], {'type': 'disabled'});
    expect(body.containsKey('reasoning_effort'), isFalse);
  } else {
    expect(body['thinking'], {'type': 'enabled'});
    expect(body['reasoning_effort'], effort.wireValue);
  }
}

AISettings _settings(HttpServer server, DeepSeekReasoningEffort? effort) {
  final settings = AISettings.defaults()
    ..activeProviderId = 'deepseek'
    ..deepSeekReasoningEffort = effort;
  settings.activeProvider
    ..apiKey = 'test-key'
    ..apiHost = 'http://${server.address.host}:${server.port}/chat/completions'
    ..selectedModelId = 'deepseek-flash';
  return settings;
}

Future<HttpServer> _server(List<Map<String, dynamic>> bodies,
    {bool toolLoop = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    final round = bodies.length;
    bodies.add(body);
    if (body['stream'] == true) {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      final delta = toolLoop && round == 0
          ? {
              'reasoning_content': 'thought',
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_1',
                  'type': 'function',
                  'function': {'name': 'echo', 'arguments': '{}'},
                },
              ],
            }
          : {'reasoning_content': 'done thinking', 'content': 'ok'};
      request.response.write('data: ${jsonEncode({
            'choices': [
              {'delta': delta}
            ]
          })}\n\n'
          'data: [DONE]\n\n');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'}
          },
        ],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
      }));
    }
    await request.response.close();
  });
  return server;
}
