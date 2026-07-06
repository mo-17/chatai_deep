import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';
import 'package:openai_flutter/model/ai_stream_chunk.dart';

void main() {
  test('createChatStreamEvents parses final usage chunk from SSE', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      expect(request.method, 'POST');
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(
        'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'hi'}
                }
              ]
            })}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({
              'choices': [],
              'usage': {
                'prompt_tokens': 11,
                'completion_tokens': 7,
                'total_tokens': 18,
              }
            })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    final config = AIConfigBuilder(
      apiKey: 'test-key',
      chatUrl: 'http://${server.address.host}:${server.port}/chat',
    );

    final events = await AICompletion(config)
        .createChatStreamEvents(prompt: 'hello')
        .toList();

    expect(
        events.map((e) => e.kind), [AIStreamKind.content, AIStreamKind.usage]);
    expect(events.first.text, 'hi');
    expect(events.last.promptTokens, 11);
    expect(events.last.completionTokens, 7);
  });

  test('createChat posts OpenAI-compatible JSON and parses response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer test-key');
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      expect(body['model'], 'gpt-3.5-turbo');
      expect(body['max_tokens'], 1000);
      expect(body['messages'], [
        {'role': 'user', 'content': '讲个笑话'}
      ]);

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'id': 'chatcmpl_test',
        'object': 'chat.completion',
        'created': 1710000000,
        'model': 'gpt-3.5-turbo',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': '这是一个本地 mock 笑话。'},
            'finish_reason': 'stop',
          }
        ],
        'usage': {
          'prompt_tokens': 5,
          'completion_tokens': 9,
          'total_tokens': 14,
        },
      }));
      await request.response.close();
    });

    final config = AIConfigBuilder(
      apiKey: 'test-key',
      chatUrl: 'http://${server.address.host}:${server.port}/chat',
    );

    final response =
        await AICompletion(config).createChat(prompt: '讲个笑话', maxTokens: 1000);
    final choices = response.choices?.first;
    expect(choices?.message?.content, '这是一个本地 mock 笑话。');
    expect(response.usage?.totalTokens, 14);
  });
}
