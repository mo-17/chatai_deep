import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DirectChatService forwards top_p through all request variants',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      bodies.add(body);
      if (body['stream'] == true) {
        request.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
          'data: [DONE]\n\n',
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {'content': 'ok'}
            }
          ],
        }));
      }
      await request.response.close();
    });

    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'test-model',
      ),
      topP: 0.45,
    );

    await service.chat(prompt: 'one', history: const []);
    await service.chatWithUsage(prompt: 'two', history: const []);
    await service.chatStream(prompt: 'three', history: const []).toList();
    await service.chatStreamEvents(prompt: 'four', history: const []).toList();

    expect(bodies, hasLength(4));
    expect(bodies.map((body) => body['top_p']), everyElement(0.45));
  });

  test('DirectChatService omits top_p when unset', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    late Map<String, dynamic> captured;
    server.listen((request) async {
      captured = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': 'ok'}
          }
        ],
      }));
      await request.response.close();
    });

    final service = DirectChatService(
      ProviderConfig(
        apiKey: 'test-key',
        baseUrl: 'http://${server.address.host}:${server.port}/chat',
        model: 'test-model',
      ),
    );
    await service.chat(prompt: 'one', history: const []);

    expect(captured.containsKey('top_p'), isFalse);
  });
}
