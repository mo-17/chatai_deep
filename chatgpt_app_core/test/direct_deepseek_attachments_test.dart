import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openai_flutter/core/ai_completions.dart';
import 'package:openai_flutter/http/ai_config.dart';

void main() {
  test('直连各发送入口使用 Files API，跨轮复用图片且保留本地历史', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var uploadCount = 0;
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      if (request.uri.path == '/files') {
        uploadCount++;
        expect(request.headers.value('authorization'), 'Bearer test-key');
        expect(request.headers.contentType?.mimeType, 'multipart/form-data');
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'id': 'file-api-test-image',
          'object': 'file',
        }));
      } else {
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
      }
      await request.response.close();
    });

    final endpoint =
        'http://${server.address.host}:${server.port}/chat/completions';
    final config = ProviderConfig(
        apiKey: 'test-key', baseUrl: endpoint, model: 'deepseek-flash');
    final service = DirectChatService(
      config,
      providerId: 'deepseek',
      providerCode: 'deepseek',
      attachmentAdapter: DeepSeekAttachmentAdapter(
        chatCompletionsUrl: endpoint,
        apiKey: 'test-key',
      ),
    );
    config.apiKey = 'changed-key';
    config.baseUrl = 'http://127.0.0.1:1/chat/completions';
    config.model = 'changed-model';
    final image = 'data:image/png;base64,${base64Encode([
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ])}';
    final attachments = ChatAttachments(images: [image], extraText: '报告文字');
    final history = <Map<String, dynamic>>[
      {'role': 'system', 'content': '系统提示'},
      {
        'role': 'user',
        'content': ChatAttachments(images: [image]).buildUserContent('旧提问')
      },
      {'role': 'assistant', 'content': '旧回答'},
    ];
    final originalHistory = jsonEncode(history);
    await service.chat(
        prompt: 'one', history: history, attachments: attachments);
    await service.chatWithUsage(
        prompt: 'two', history: history, attachments: attachments);
    await service
        .chatStream(prompt: 'three', history: history, attachments: attachments)
        .drain<void>();
    await service
        .chatStreamEvents(
            prompt: 'four', history: history, attachments: attachments)
        .drain<void>();
    await service
        .chatStreamEventsWithOptions(
          prompt: 'five',
          history: history,
          attachments: attachments,
          extraMessages: const [
            {'role': 'tool', 'tool_call_id': 'call-1', 'content': '工具结果'}
          ],
          options: const ChatRequestOptions(),
        )
        .drain<void>();

    expect(uploadCount, 1);
    expect(bodies, hasLength(5));
    expect(jsonEncode(history), originalHistory);
    for (final body in bodies) {
      expect(body['model'], 'deepseek-flash');
      final messages = body['messages'] as List;
      expect(messages.first['content'], '系统提示');
      final oldImage = (messages[1]['content'] as List).last;
      expect(oldImage, {'type': 'file', 'file_id': 'file-api-test-image'});
      final currentParts = messages[3]['content'] as List;
      expect(currentParts.first['text'], contains('报告文字'));
      expect(currentParts.last,
          {'type': 'file', 'file_id': 'file-api-test-image'});
    }
    expect((bodies.last['messages'] as List).last['content'], '工具结果');
    expect(bodies.map((body) => body.containsKey('thinking')),
        everyElement(isFalse));

    final toolHistory = <Map<String, dynamic>>[
      ...history,
      {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'call-1',
            'type': 'function',
            'function': {'name': 'calculator', 'arguments': '{}'}
          }
        ],
      },
      {'role': 'tool', 'tool_call_id': 'call-1', 'content': '2'},
    ];
    await service.chat(
        prompt: 'six', history: toolHistory, attachments: attachments);
    await service.chatWithUsage(
        prompt: 'seven', history: toolHistory, attachments: attachments);
    await service
        .chatStream(
            prompt: 'eight', history: toolHistory, attachments: attachments)
        .drain<void>();
    await service
        .chatStreamEvents(
            prompt: 'nine', history: toolHistory, attachments: attachments)
        .drain<void>();
    await service
        .chatStreamEventsWithOptions(
          prompt: 'ten',
          history: history,
          attachments: attachments,
          tools: const [
            {
              'type': 'function',
              'function': {
                'name': 'calculator',
                'parameters': {'type': 'object', 'properties': {}}
              }
            }
          ],
          options: const ChatRequestOptions(),
        )
        .drain<void>();
    expect(uploadCount, 1);
    expect(bodies, hasLength(10));
    expect(bodies.skip(5).map((body) => body['thinking']),
        everyElement({'type': 'disabled'}));
  });

  test('上传途中取消会返回 cancelled，且不继续发对话请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final uploadStarted = Completer<void>();
    final abort = Completer<void>();
    var chatRequests = 0;
    server.listen((request) async {
      if (request.uri.path == '/files') {
        await request.drain<void>();
        uploadStarted.complete();
        // 不返回响应，模拟仍在等待上传确认的请求。
      } else {
        chatRequests++;
        await request.response.close();
      }
    });
    final endpoint =
        'http://${server.address.host}:${server.port}/chat/completions';
    final service = DirectChatService(
      ProviderConfig(
          apiKey: 'test-key', baseUrl: endpoint, model: 'deepseek-flash'),
      providerId: 'deepseek',
      attachmentAdapter: DeepSeekAttachmentAdapter(
          chatCompletionsUrl: endpoint, apiKey: 'test-key'),
    );
    final image = 'data:image/png;base64,${base64Encode([
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a
        ])}';
    final request = service
        .chatStreamEventsWithOptions(
          prompt: '取消图片',
          history: const [],
          attachments: ChatAttachments(images: [image]),
          options: ChatRequestOptions(abortTrigger: abort.future),
        )
        .drain<void>();
    final checked = expectLater(
        request,
        throwsA(isA<ChatTransportException>()
            .having((e) => e.safeCode, 'safeCode', 'cancelled')));
    await uploadStarted.future.timeout(const Duration(seconds: 5));
    abort.complete();
    await checked;
    expect(chatRequests, 0);
  });

  test('其他 OpenAI 兼容服务继续按原协议发送内联图片', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late Map<String, dynamic> body;
    server.listen((request) async {
      expect(request.uri.path, '/chat/completions');
      body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"choices":[{"message":{"content":"ok"}}]}');
      await request.response.close();
    });
    final service = DirectChatService(ProviderConfig(
      apiKey: 'test-key',
      baseUrl: 'http://${server.address.host}:${server.port}/chat/completions',
      model: 'gpt-4o',
    ));
    await service.chat(
        prompt: '图片',
        history: const [],
        attachments:
            const ChatAttachments(images: ['data:image/png;base64,AAA']));
    final parts = (body['messages'] as List).single['content'] as List;
    expect(parts.last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,AAA'}
    });
  });

  test('SDK 扩展参数不能覆盖 messages、model 等标准请求字段', () async {
    final completion = AICompletion(AIConfigBuilder(
        apiKey: 'test-key', chatUrl: 'http://127.0.0.1:1/chat/completions'));
    await expectLater(completion.createChat(extraBody: const {'messages': []}),
        throwsArgumentError);
    await expectLater(
        completion.createChatStream(
            extraBody: const {'model': 'override'}).drain<void>(),
        throwsArgumentError);
    await expectLater(
        completion.createChatStreamEvents(
            extraBody: const {'tools': []}).drain<void>(),
        throwsArgumentError);
  });
}
