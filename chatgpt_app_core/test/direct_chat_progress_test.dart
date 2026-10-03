import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/chat_send_progress.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String image() => 'data:image/png;base64,${base64Encode([
            0x89,
            0x50,
            0x4e,
            0x47,
            0x0d,
            0x0a,
            0x1a,
            0x0a
          ])}';

  DirectChatService serviceFor(HttpServer server) {
    final url = 'http://${server.address.host}:${server.port}/chat/completions';
    return DirectChatService(
      ProviderConfig(apiKey: 'key', baseUrl: url, model: 'deepseek-flash'),
      providerId: 'deepseek',
      providerCode: 'deepseek',
      attachmentAdapter:
          DeepSeekAttachmentAdapter(chatCompletionsUrl: url, apiKey: 'key'),
    );
  }

  for (final stream in [false, true]) {
    test('${stream ? '流式' : '非流式'}先上传图片确认，再等待回答，重试不重复上传', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final uploadConsumed = Completer<void>();
      final uploadAck = Completer<void>();
      var uploads = 0;
      var chats = 0;
      server.listen((request) async {
        if (request.uri.path == '/files') {
          uploads++;
          await request.drain<void>();
          uploadConsumed.complete();
          await uploadAck.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"object":"file","id":"file-api-progress"}');
        } else {
          chats++;
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body['max_tokens'], 321);
          if (stream) {
            request.response.headers.contentType =
                ContentType('text', 'event-stream');
            request.response.write(
                'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n');
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response
                .write('{"choices":[{"message":{"content":"ok"}}]}');
          }
        }
        await request.response.close();
      });
      final service = serviceFor(server);
      final progress = <ChatSendProgress>[];
      final attachment = ChatAttachments(images: [image()]);
      Future<void> send() async {
        final options = ChatRequestOptions(
            onProgress: progress.add, maxOutputTokensOverride: 321);
        if (stream) {
          await service
              .chatStreamEventsWithOptions(
                  prompt: 'question',
                  history: const [],
                  attachments: attachment,
                  options: options)
              .drain<void>();
        } else {
          final result = await service.chatWithUsageWithOptions(
              prompt: 'question',
              history: const [],
              attachments: attachment,
              options: options);
          expect(result.content, 'ok');
        }
      }

      final pending = send();
      await uploadConsumed.future;
      expect(progress.last.label, '等待图片上传确认');
      expect(chats, 0);
      uploadAck.complete();
      await pending;
      expect(progress.last.label, '等待回答');
      expect(uploads, 1);
      progress.clear();
      await send();
      expect(uploads, 1);
      expect(chats, 2);
      expect(progress.map((p) => p.label), ['等待回答']);
    });
  }

  test('非流式在图片上传时取消，不继续发送聊天请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final started = Completer<void>();
    var chats = 0;
    server.listen((request) async {
      if (request.uri.path == '/files') {
        await request.drain<void>();
        started.complete();
      } else {
        chats++;
        await request.response.close();
      }
    });
    final abort = Completer<void>();
    final pending = serviceFor(server).chatWithUsageWithOptions(
        prompt: 'cancel',
        history: const [],
        attachments: ChatAttachments(images: [image()]),
        options: ChatRequestOptions(abortTrigger: abort.future));
    final checked = expectLater(
        pending,
        throwsA(isA<ChatTransportException>()
            .having((e) => e.safeCode, 'code', 'cancelled')));
    await started.future;
    abort.complete();
    await checked;
    expect(chats, 0);
  });

  test('非流式停止后忽略迟到回答，保留原 SDK 超时收尾行为', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final started = Completer<void>();
    final release = Completer<void>();
    final finished = Completer<void>();
    server.listen((request) async {
      await request.drain<void>();
      started.complete();
      await release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"choices":[{"message":{"content":"late"}}]}');
      await request.response.close();
      finished.complete();
    });
    final abort = Completer<void>();
    final pending = serviceFor(server).chatWithUsageWithOptions(
        prompt: 'cancel',
        history: const [],
        options: ChatRequestOptions(abortTrigger: abort.future));
    final checked = expectLater(
        pending,
        throwsA(isA<ChatTransportException>()
            .having((e) => e.safeCode, 'code', 'cancelled')));
    await started.future;
    abort.complete();
    await checked;
    release.complete();
    await finished.future;
  });
}
