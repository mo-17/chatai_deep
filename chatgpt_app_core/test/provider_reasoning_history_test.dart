import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final config in [
    (provider: 'deepseek', model: 'deepseek-flash', replay: true),
    (provider: 'deepseek', model: 'deepseek-v4-pro', replay: true),
    (provider: 'openai', model: 'gpt-4o', replay: false),
    (provider: 'openrouter', model: 'deepseek-v4-pro', replay: false),
    (provider: 'custom', model: 'deepseek-flash', replay: false),
    (provider: 'deepseek', model: 'deepseek-reasoner', replay: false),
  ]) {
    test(
        '${config.provider}/${config.model} filters reasoning in every direct request variant',
        () async {
      final bodies = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        bodies.add(body);
        if (body['stream'] == true) {
          request.response.headers.contentType =
              ContentType('text', 'event-stream');
          request.response
              .write('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
                  'data: [DONE]\n\n');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"choices":[{"message":{"content":"ok"}}]}');
        }
        await request.response.close();
      });
      final service = DirectChatService(
        ProviderConfig(
            apiKey: 'mock-key',
            baseUrl: 'http://${server.address.host}:${server.port}/chat',
            model: config.model),
        providerId: config.provider,
        // 自定义路由可有 deepseek 派生 code，不能把它误判成 first-party。
        providerCode: 'deepseek',
      );
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'original'},
        {
          'role': 'assistant',
          'content': '',
          'reasoning_content': 'tool reasoning',
          'tool_calls': [
            {
              'id': 'c',
              'type': 'function',
              'function': {'name': 'calc', 'arguments': '{}'}
            }
          ]
        },
        {'role': 'tool', 'tool_call_id': 'c', 'content': '42'},
        {'role': 'assistant', 'content': '42', 'reasoning_content': ''},
      ];
      final before = jsonEncode(history);
      await service.chat(prompt: 'next', history: history);
      await service.chatWithUsage(prompt: 'next', history: history);
      await service.chatStream(prompt: 'next', history: history).drain<void>();
      await service
          .chatStreamEvents(prompt: 'next', history: history)
          .drain<void>();
      expect(bodies, hasLength(4));
      for (final body in bodies) {
        final transmitted =
            (body['messages'] as List).take(history.length).toList();
        if (config.replay) {
          expect(transmitted, history);
          expect(body.containsKey('thinking'), isFalse);
        } else {
          final expected = history.map((message) {
            final copy = Map<String, dynamic>.from(message);
            copy.remove('reasoning_content');
            return copy;
          }).toList();
          expect(transmitted, expected);
        }
      }
      expect(jsonEncode(history), before);
      // 单轮工具回灌的副本也应用同样过滤。
      final extra = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '',
          'reasoning_content': 'new thought',
          'tool_calls': [
            {
              'id': 'd',
              'type': 'function',
              'function': {'name': 'calc', 'arguments': '{}'}
            }
          ]
        },
        {'role': 'tool', 'tool_call_id': 'd', 'content': '43'},
      ];
      final extraBefore = jsonEncode(extra);
      await service
          .chatStreamEvents(
              prompt: 'next', history: const [], extraMessages: extra)
          .drain<void>();
      final replay = (bodies.last['messages'] as List)[1] as Map;
      expect(replay.containsKey('reasoning_content'), config.replay);
      expect(replay['tool_calls'], extra.first['tool_calls']);
      expect(jsonEncode(extra), extraBefore);
    });
  }
}
