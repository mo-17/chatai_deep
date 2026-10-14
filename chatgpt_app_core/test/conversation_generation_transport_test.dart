import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_memory_context.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/chat/application/deepseek_attachment_adapter.dart';
import 'package:chatgpt_app_core/chat/application/search_orchestrator.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/application/web_search_provider.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/message_block.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conversation_generation_test.dart'
    show GenerationTestAuth, generationSettings;

class _LocalSearch extends WebSearchProvider {
  final Uri endpoint;
  int calls = 0;
  _LocalSearch(this.endpoint) : super(apiKey: 'synthetic');
  @override
  Future<List<WebSearchResult>> search(String query) async {
    calls++;
    await postJson(endpoint, {}, {'query': query}, providerName: 'loopback');
    return [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 此文件是纯回环传输，不使用 widget binding 的默认 HTTP 400 stub。
  final originalOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  final evidence = <Object>[];
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late AISettings settings;
  late HttpServer server;
  late ConversationGenerationService service;
  late int conversationId;
  late String oldHost;
  late bool oldHttps;
  final requests = <Map<String, dynamic>>[];
  final held = Completer<void>();
  late Map<String, dynamic> catalogData;
  late Future<void> Function(HttpRequest) requestHandler;
  void listenServer(Future<void> Function(HttpRequest) handler) {
    requestHandler = handler;
  }

  void respond(HttpRequest request, {bool tool = false}) {
    if (request.response.headers.contentType?.mimeType == 'text/event-stream') {
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': tool
                    ? {
                        'tool_calls': [
                          {
                            'index': 0,
                            'id': 'call_one',
                            'type': 'function',
                            'function': {'name': 'test_read', 'arguments': '{}'}
                          }
                        ]
                      }
                    : {'content': 'LOOPBACK_REPLY'}
              }
            ]
          })}\n\n');
      request.response.write('data: ${jsonEncode({
            'choices': [],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          })}\n\n');
      request.response.write('data: [DONE]\n\n');
    } else if (request.uri.path.startsWith('/uapi/')) {
      request.response.write(jsonEncode({
        'code': 0,
        'data': {
          'content': 'LOOPBACK_REPLY',
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
        }
      }));
    } else {
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'LOOPBACK_REPLY'}
          }
        ],
        'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
      }));
    }
    unawaited(request.response.close());
  }

  ConversationGenerationRun start(
      {bool stream = true,
      bool personalMemory = false,
      ToolRegistry? tools,
      ChatAttachments attachments = const ChatAttachments(),
      ChatService Function(AISettings)? createChat}) {
    service = ConversationGenerationService(
        observeApplication: false,
        createMemory: (_) async => personalMemory
            ? ConversationMemoryContext(
                storage: storage,
                accountHash: 'a',
                cid: 1,
                assistantId: null,
                taskMode: false,
                personal:
                    await PersonalMemoryDao.create(storage, accountHash: 'a'),
                assistant: await AssistantMemoryDao.create(storage))
            : null,
        createChat: createChat);
    final scope = ConversationGenerationScope(account: 'a');
    return service.start(
        scope: scope,
        dao: dao,
        profile: ConversationGenerationProfile(settings, 'a',
            loadSettings: () async => settings,
            visibleSettings: () =>
                settings.mode == AIMode.backend ? null : settings),
        input: ConversationGenerationInput(
            cid: 1,
            conversationRowId: conversationId,
            user: MessageModel(
                ownerType: OwnerType.sender,
                content: 'SYNTHETIC_INPUT',
                createdAt: 10),
            stream: stream),
        preparation: ReadyConversationTurn(PreparedConversationTurn(
            prompt: 'SYNTHETIC_INPUT',
            attachments: attachments,
            tools: tools)));
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    GenerationTestAuth().install();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    conversationId = (await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 1, title: '合成', icon: '')))!;
    dao = await ConversationGenerationDao.create(storage);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = '${server.address.host}:${server.port}';
    BackendConfig.useHttps = false;
    settings = generationSettings();
    settings.activeProvider.apiHost =
        'http://${server.address.host}:${server.port}/v1';
    ModelCatalog.resetExecutionForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    catalogData = {
      'models': [
        {'modelId': 'gpt-4o-a', 'providerCode': 'openai', 'supportsTool': true}
      ]
    };
    server.listen((request) async {
      if (request.uri.path == '/uapi/ai/catalog') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'code': 0, 'data': catalogData}));
        await request.response.close();
      } else {
        await requestHandler(request);
      }
    });
    await ModelCatalog.refreshFromBackend();
    requests.clear();
  });
  tearDown(() async {
    for (final run in service.runs.where((r) => r.busy)) {
      await run.stop('cleanup');
    }
    await server.close(force: true);
    service.dispose();
    await storage.db.close();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
  });
  for (final backend in [false, true]) {
    for (final stream in [false, true]) {
      test(
          '${backend ? 'Backend' : 'Direct'} actual boundary continues with captured model and single publication stream=$stream',
          () async {
        if (backend) {
          settings.mode = AIMode.backend;
          settings.backendModel = 'gpt-4o-a';
        }
        final arrived = Completer<void>(), release = Completer<void>();
        listenServer((request) async {
          requests.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          arrived.complete();
          await release.future;
          request.response.headers.contentType = ContentType(
              stream ? 'text' : 'application',
              stream ? 'event-stream' : 'json');
          respond(request);
        });
        final run = start(stream: stream);
        await arrived.future.timeout(const Duration(seconds: 3));
        final host = Object();
        run.attachVisibleHost(host);
        run.detachVisibleHost(host);
        settings.setActiveModel('gpt-4o-b');
        release.complete();
        await run.finished.timeout(const Duration(seconds: 3));
        expect(run.stage, ConversationGenerationStage.complete);
        expect(requests, hasLength(1));
        expect(requests.single['model'], 'gpt-4o-a');
        expect(
            await storage.db
                .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
            hasLength(1));
        expect(await storage.db.query('tb_usage'), hasLength(1));
        evidence.add({
          'case': '${backend ? 'backend' : 'direct'}-$stream-capture',
          'posts': requests.toList(),
          'journal': (await dao.read(run.runId))!.state
        });
      });
      test(
          '${backend ? 'Backend' : 'Direct'} 503 retry blocked by original profile revocation stream=$stream',
          () async {
        if (backend) {
          settings.mode = AIMode.backend;
          settings.backendModel = 'gpt-4o-a';
        }
        final arrived = Completer<void>();
        listenServer((request) async {
          requests.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          request.response.statusCode = 503;
          request.response.write('{}');
          await request.response.close();
          if (!arrived.isCompleted) arrived.complete();
        });
        final run = start(stream: stream);
        await arrived.future.timeout(const Duration(seconds: 3));
        if (backend) {
          catalogData = {
            'models': [
              {
                'modelId': 'gpt-4o-removed-replacement',
                'providerCode': 'openai'
              }
            ]
          };
          await ModelCatalog.refreshFromBackend();
        } else {
          settings.activeProvider.enabled = false;
        }
        await run.finished.timeout(const Duration(seconds: 3));
        expect(requests, hasLength(1));
        // 目录通知会主动停止在途运行；直连的读取校验则报告配置失败。
        expect(
            run.stage,
            backend
                ? ConversationGenerationStage.interrupted
                : ConversationGenerationStage.failed);
        expect(run.record!.attempts, 1);
        evidence.add({
          'case': '${backend ? 'backend' : 'direct'}-$stream-revoked',
          'posts': requests.toList(),
          'attempts': run.record!.attempts
        });
      });
    }
  }
  for (final backend in [false, true]) {
    for (final stream in [false, true]) {
      test(
          '${backend ? 'Backend' : 'Direct'} lifecycle options retain fresh memory on 503 retry stream=$stream',
          () async {
        if (backend) {
          settings.mode = AIMode.backend;
          settings.backendModel = 'gpt-4o-a';
        }
        final memory =
            await PersonalMemoryDao.create(storage, accountHash: 'a');
        await memory.save('SYNTHETIC_MEMORY_SENTINEL');
        var prefs = await memory.preferences();
        await memory.setPreferences(
            revision: prefs.revision, enabled: true, suggestionsEnabled: false);
        listenServer((request) async {
          requests.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          if (requests.length == 1) {
            // 已真正收到第一 POST，再撤销记忆；重试必须重新取快照。
            prefs = await memory.preferences();
            await memory.setPreferences(
                revision: prefs.revision,
                enabled: false,
                suggestionsEnabled: false);
            request.response.statusCode = 503;
            request.response.write('{}');
            await request.response.close();
          } else {
            request.response.headers.contentType =
                stream ? ContentType('text', 'event-stream') : ContentType.json;
            respond(request);
          }
        });
        final run = start(stream: stream, personalMemory: true);
        await run.finished.timeout(const Duration(seconds: 5));
        expect(run.stage, ConversationGenerationStage.complete);
        expect(requests, hasLength(2));
        expect(
            jsonEncode(requests.first), contains('SYNTHETIC_MEMORY_SENTINEL'));
        expect(jsonEncode(requests.last),
            isNot(contains('SYNTHETIC_MEMORY_SENTINEL')));
        expect(jsonEncode(requests.last), contains('SYNTHETIC_INPUT'));
        expect(run.record!.attempts, 2);
        expect(await storage.db.query('tb_usage'), hasLength(1));
        evidence.add({
          'case': '${backend ? 'backend' : 'direct'}-$stream-memory-retry',
          'posts': requests.toList(),
          'attempts': run.record!.attempts
        });
      });
    }
    test(
        '${backend ? 'Backend' : 'Direct'} stop during tool wait does not send next round',
        () async {
      if (backend) {
        settings.mode = AIMode.backend;
        settings.backendModel = 'gpt-4o-a';
      }
      final entered = Completer<void>(), release = Completer<void>();
      listenServer((request) async {
        requests.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        respond(request, tool: true);
      });
      final run = start(
          tools: ToolRegistry([
        ChatTool(
            name: 'test_read',
            description: '合成等待中的只读工具',
            parameters: {'type': 'object'},
            execute: (_) async {
              entered.complete();
              await release.future;
              return const ToolOutcome(content: 'LATE_TOOL_RESULT');
            })
      ]));
      await entered.future.timeout(const Duration(seconds: 3));
      await run.stop('工具等待中停止').timeout(const Duration(seconds: 3));
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, hasLength(1));
      expect(run.record!.attempts, 1);
      expect(run.stage, ConversationGenerationStage.interrupted);
      final replies = await storage.db
          .query('tb_messages', where: "ownerType='OwnerType.receiver'");
      expect(replies, hasLength(1));
      expect(jsonEncode(replies), isNot(contains('LATE_TOOL_RESULT')));
      evidence.add({
        'case': '${backend ? 'backend' : 'direct'}-tool-stop',
        'posts': requests.toList(),
        'attempts': run.record!.attempts
      });
    });
  }
  for (final stream in [false, true]) {
    test('Backend explicit empty catalog revokes held HTTP stream=$stream',
        () async {
      settings.mode = AIMode.backend;
      settings.backendModel = 'gpt-4o-a';
      final arrived = Completer<void>(), release = Completer<void>();
      listenServer((request) async {
        requests.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        arrived.complete();
        await release.future;
        request.response.headers.contentType =
            stream ? ContentType('text', 'event-stream') : ContentType.json;
        respond(request);
      });
      final run = start(stream: stream);
      await arrived.future.timeout(const Duration(seconds: 3));
      catalogData = {'models': []};
      await ModelCatalog.refreshFromBackend();
      await run.finished.timeout(const Duration(seconds: 3));
      expect(run.stage, ConversationGenerationStage.interrupted);
      expect(service.registry.lookup('a', 1), isNull);
      expect(requests, hasLength(1));
      expect(run.record!.attempts, 1);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(jsonEncode(await storage.db.query('tb_messages')),
          isNot(contains('LOOPBACK_REPLY')));
      evidence.add({
        'case': 'backend-$stream-empty-catalog-held',
        'posts': requests.toList(),
        'attempts': run.record!.attempts,
        'lateReplyRows': 0
      });
    });
  }
  test(
      'Direct actual two tool rounds preserve protocol and same lifecycle guard',
      () async {
    var reads = 0;
    listenServer((request) async {
      requests.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      respond(request, tool: requests.length == 1);
    });
    final run = start(
        tools: ToolRegistry([
      ChatTool(
          name: 'test_read',
          description: '合成只读',
          parameters: {'type': 'object'},
          execute: (_) async {
            reads++;
            return const ToolOutcome(content: 'READ_SNAPSHOT');
          })
    ]));
    await run.finished.timeout(const Duration(seconds: 3));
    expect(run.stage, ConversationGenerationStage.complete);
    expect(requests, hasLength(2));
    expect(reads, 1);
    final second = requests.last['messages'] as List;
    expect(second.where((m) => m['role'] == 'tool').single['content'],
        'READ_SNAPSHOT');
    expect(run.record!.attempts, 2);
    final row = (await storage.db
            .query('tb_messages', where: "ownerType='OwnerType.receiver'"))
        .single;
    expect((row['blocks'] as String), contains('READ_SNAPSHOT'));
    evidence.add(
        {'case': 'direct-tools', 'posts': requests.toList(), 'reads': reads});
  });
  test(
      'Direct upload wait stop aborts first image and never sends next upload/chat',
      () async {
    var uploads = 0, chatPosts = 0;
    final arrived = Completer<void>(), release = Completer<void>();
    listenServer((request) async {
      await request.drain<void>();
      if (request.uri.path.endsWith('/files')) {
        uploads++;
        if (!arrived.isCompleted) arrived.complete();
        await release.future;
        request.response.write(jsonEncode({
          'id': 'file-synthetic',
          'filename': 'one.png',
          'purpose': 'user_data',
          'bytes': 8
        }));
        await request.response.close();
      } else {
        chatPosts++;
        request.response.write('{}');
        await request.response.close();
      }
    });
    final data = 'data:image/png;base64,${base64Encode([
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          1,
          2,
          3,
          4
        ])}';
    final run = start(
        attachments: ChatAttachments(images: [data, data]),
        createChat: (s) => DirectChatService(s.activeLocal,
            providerId: s.activeProviderId,
            providerCode: 'openai',
            attachmentAdapter: DeepSeekAttachmentAdapter(
                chatCompletionsUrl: s.activeLocal.baseUrl,
                apiKey: 'synthetic')));
    await arrived.future.timeout(const Duration(seconds: 3));
    await run.stop('停止上传').timeout(const Duration(seconds: 3));
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(uploads, 1);
    expect(chatPosts, 0);
    expect(run.record!.attempts, 0);
    evidence.add(
        {'case': 'upload-stop', 'uploads': uploads, 'chatPosts': chatPosts});
  });
  test('search HTTP cancellation propagates without fallback main request',
      () async {
    final arrived = Completer<void>(),
        release = Completer<void>(),
        abort = Completer<void>();
    var posts = 0;
    listenServer((request) async {
      await request.drain<void>();
      posts++;
      if (request.uri.path == '/search') {
        arrived.complete();
        await release.future;
        request.response.write('{}');
      } else {
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {
                'content': '{"needSearch":true,"queries":["synthetic"]}'
              }
            }
          ]
        }));
      }
      await request.response.close();
    });
    // 此用例直接覆盖真实 SearchOrchestrator；服务的主请求循环在上面的两传输矩阵覆盖。
    final provider = _LocalSearch(
        Uri.parse('http://${server.address.host}:${server.port}/search'));
    final options = ChatRequestOptions(
        abortTrigger: abort.future,
        dispatchIsCurrent: () => !abort.isCompleted);
    final orchestrator = SearchOrchestrator(
        chatService: ChatService.from(settings), provider: provider);
    service = ConversationGenerationService(
        observeApplication: false, createMemory: (_) async => null);
    final pending =
        orchestrator.run(prompt: 'synthetic', history: [], options: options);
    final assertion = expectLater(
        pending,
        throwsA(isA<ChatTransportException>()
            .having((e) => e.failureKind, 'kind', ChatFailureKind.cancelled)));
    await arrived.future.timeout(const Duration(seconds: 3));
    abort.complete();
    await assertion.timeout(const Duration(seconds: 3));
    release.complete();
    expect(provider.calls, 1);
    expect(posts, 2);
    evidence.add({'case': 'search-stop', 'intentAndSearchPosts': posts});
  });
  tearDownAll(() async {
    HttpOverrides.global = originalOverrides;
    if (!held.isCompleted) held.complete();
    // 只有显式指定本轮独立工件路径才写证据，不覆盖之前已冻结的记录。
    final path = Platform.environment['CHATAI_CONTINUITY_EVIDENCE_PATH'];
    if (path != null && path.isNotEmpty) {
      await File(path)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    }
  });
}
