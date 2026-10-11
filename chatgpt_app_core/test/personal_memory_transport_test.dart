import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/dao/completion_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

void main() {
  late HiDBManager storage;
  late PersonalMemoryDao memory;
  late AssistantMemoryDao assistant;
  late PersonalMemoryTestAccount auth;
  late HttpServer server;
  late String previousHost;
  late bool previousHttps;
  late List<Map<String, dynamic>> bodies;
  final evidence = <String, dynamic>{};
  Future<void> enabled(bool value) async {
    final prefs = await memory.preferences();
    await memory.setPreferences(
        revision: prefs.revision, enabled: value, suggestionsEnabled: false);
  }

  String getEndpoint() =>
      'http://${server.address.host}:${server.port}/chat/completions';
  DirectChatService direct({DeepSeekAttachmentAdapter? adapter}) =>
      DirectChatService(
          ProviderConfig(
              apiKey: 'synthetic-test-key',
              baseUrl: getEndpoint(),
              model: adapter == null ? 'test-model' : 'deepseek-flash'),
          providerId: adapter == null ? 'fixture' : 'deepseek',
          attachmentAdapter: adapter);
  CompletionDao completion(ChatService service) => CompletionDao(
      settings: AISettings.defaults(),
      chatService: service,
      manageContext: true,
      memoryContextResolver: ConversationMemoryContext(
              storage: storage,
              accountHash: 'a',
              cid: 1,
              assistantId: null,
              taskMode: false,
              personal: memory,
              assistant: assistant)
          .resolve);
  Future<void> success(HttpRequest request, {required bool stream}) async {
    if (stream) {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response
          .write('data: {"choices":[{"delta":{"content":"合成回复"}}]}\n\n'
              'data: [DONE]\n\n');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(request.uri.path.startsWith('/uapi/')
          ? '{"code":0,"data":{"content":"合成回复"}}'
          : '{"choices":[{"message":{"content":"合成回复"}}]}');
    }
    await request.response.close();
  }

  setUp(() async {
    sqfliteFfiInit();
    auth = PersonalMemoryTestAccount('a')..install();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 1, title: '合成', icon: ''));
    await MessageDao.create(storage, cid: 1);
    memory = await PersonalMemoryDao.create(storage, accountHash: 'a');
    assistant = await AssistantMemoryDao.create(storage);
    await memory.save('合成偏好：回答请简短');
    await enabled(true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    previousHost = BackendConfig.host;
    previousHttps = BackendConfig.useHttps;
    BackendConfig.host = '${server.address.host}:${server.port}';
    BackendConfig.useHttps = false;
    bodies = [];
  });
  tearDown(() async {
    await server.close(force: true);
    BackendConfig.host = previousHost;
    BackendConfig.useHttps = previousHttps;
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  tearDownAll(() => File('/tmp/chatai-personal-memory-transport-payloads.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence)));
  for (final backend in [false, true]) {
    for (final stream in [false, true]) {
      final label =
          '${backend ? 'backend' : 'direct'}-${stream ? 'stream' : 'nonstream'}';
      test('$label 503退避期间关闭：真正第二次HTTP不含记忆', () async {
        final retry = Completer<void>();
        server.listen((request) async {
          bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          if (bodies.length == 1) {
            request.response.statusCode = 503;
            request.response
                .write('{"error":{"message":"synthetic unavailable"}}');
            await request.response.close();
          } else {
            await success(request, stream: stream);
          }
        });
        final ChatService service;
        if (backend) {
          service = BackendChatService(AISettings.defaults());
        } else {
          service = direct();
        }
        final dao = completion(service);
        void progress(dynamic p) {
          if (p.label.startsWith('等待重试') && !retry.isCompleted) {
            retry.complete();
          }
        }

        final Future<dynamic> result = stream
            ? dao
                .streamCompletionEvents(prompt: '重试合成', onProgress: progress)
                .toList()
            : dao.createCompletionsWithSearch(
                prompt: '重试合成', onProgress: progress);
        await retry.future.timeout(const Duration(seconds: 5));
        await enabled(false);
        await result.timeout(const Duration(seconds: 5));
        expect(bodies, hasLength(2));
        expect(jsonEncode(bodies.first), contains('合成偏好'));
        expect(jsonEncode(bodies.last), isNot(contains('合成偏好')));
        expect((bodies.last['messages'] as List).last['content'], '重试合成');
        evidence[label] = bodies;
      });
    }
  }
  for (final stream in [false, true]) {
    test(
        'deepseek-${stream ? 'stream' : 'nonstream'} 上传等待中删除：首次chat HTTP即无记忆，file_id保留',
        () async {
      final upload = Completer<void>();
      final release = Completer<void>();
      var uploads = 0;
      server.listen((request) async {
        if (request.uri.path == '/files') {
          uploads++;
          await request.drain<void>();
          upload.complete();
          await release.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"id":"file-api-synthetic","object":"file"}');
          await request.response.close();
        } else {
          bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          await success(request, stream: stream);
        }
      });
      final adapter = DeepSeekAttachmentAdapter(
          chatCompletionsUrl: getEndpoint(), apiKey: 'synthetic-test-key');
      final dao = completion(direct(adapter: adapter));
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
      final attachments = ChatAttachments(images: [image], extraText: '原附件文字');
      final Future<dynamic> result = stream
          ? dao
              .streamCompletionEvents(prompt: '图片合成', attachments: attachments)
              .toList()
          : dao.createCompletionsWithSearch(
              prompt: '图片合成', attachments: attachments);
      await upload.future.timeout(const Duration(seconds: 5));
      expect(bodies, isEmpty);
      await memory.delete((await memory.list()).single);
      release.complete();
      await result.timeout(const Duration(seconds: 5));
      expect(uploads, 1);
      expect(bodies, hasLength(1));
      expect(jsonEncode(bodies.single), isNot(contains('合成偏好')));
      expect(jsonEncode(bodies.single), contains('file-api-synthetic'));
      expect(jsonEncode(bodies.single), contains('原附件文字'));
      evidence['upload-${stream ? 'stream' : 'nonstream'}'] = bodies;
    });
  }
  test('503后切账号：旧实例不会发送第二次HTTP', () async {
    final retry = Completer<void>();
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.statusCode = 503;
      request.response.write('{}');
      await request.response.close();
    });
    final pending = completion(direct()).createCompletionsWithSearch(
        prompt: '账号合成',
        onProgress: (p) {
          if (p.label.startsWith('等待重试') && !retry.isCompleted) {
            retry.complete();
          }
        });
    final assertion = expectLater(pending, throwsA(anything));
    await retry.future.timeout(const Duration(seconds: 5));
    auth.account = 'b';
    await assertion;
    expect(bodies, hasLength(1));
    evidence['account-switch'] = {'requests': bodies.length};
  });
}
