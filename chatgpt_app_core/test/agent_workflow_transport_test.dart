import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_background_execution.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_memory_test_support.dart';

/// 真实 SDK/HTTP 只访问回环服务；凭据、账号、回复均为合成 fixture。
void main() {
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late HttpServer server;
  late PersonalMemoryTestAccount auth;
  late String previousHost;
  late bool previousHttps;
  late int userId, epoch, restore;
  late List<Map<String, dynamic>> bodies;
  late Future<void> Function(HttpRequest) respond;
  final evidence = <String, Object?>{};
  final profiles = {
    for (final role in WorkflowRole.values)
      role: WorkflowModelProfile('local', 'fixture', role.name)
  };
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: 'a',
      currentAccount: () => auth.account,
      currentLoginEpoch: () => epoch,
      currentRestoreRevision: () => restore,
      stableOperation: (action) => action());
  Future<AgentWorkflow> create({int budget = 8}) =>
      dao.createFromSource(scope(),
          cid: 1,
          userRowId: userId,
          profiles: profiles,
          budget: WorkflowBudget(maxDispatches: budget));
  ChatService service(bool backend, {String model = 'analysis'}) {
    if (backend) {
      final settings = AISettings.defaults()..mode = AIMode.backend;
      settings.backendModel = model;
      return BackendChatService(settings);
    }
    return DirectChatService(
        ProviderConfig(
            apiKey: 'synthetic-test-key',
            baseUrl:
                'http://${server.address.host}:${server.port}/chat/completions',
            model: model),
        providerId: 'fixture');
  }

  Future<void> success(HttpRequest request,
      {required bool stream, String content = '合成结果'}) async {
    if (stream) {
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': content}
              }
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          })}\n\ndata: [DONE]\n\n');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(request.uri.path.startsWith('/uapi/')
          ? {
              'code': 0,
              'data': {
                'content': content,
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
              }
            }
          : {
              'choices': [
                {
                  'message': {'content': content}
                }
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
            }));
    }
    await request.response.close();
  }

  Future<dynamic> request(
          ChatService chat, bool stream, ChatRequestOptions options) =>
      stream
          ? chat
              .chatStreamEventsWithOptions(
                  prompt: '本次任务', history: [], options: options)
              .toList()
          : chat.chatWithUsageWithOptions(
              prompt: '本次任务', history: [], options: options);
  setUp(() async {
    sqfliteFfiInit();
    epoch = 1;
    restore = 0;
    auth = PersonalMemoryTestAccount('a')..install();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 1, title: '合成任务', icon: '', assistantId: 777));
    userId = await (await MessageDao.create(storage, cid: 1))
        .saveMessageWithBlocks(MessageModel(
            content: '只使用本次任务', ownerType: OwnerType.sender, createdAt: 10));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'a');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    previousHost = BackendConfig.host;
    previousHttps = BackendConfig.useHttps;
    BackendConfig.host = '${server.address.host}:${server.port}';
    BackendConfig.useHttps = false;
    bodies = [];
    respond = (r) => success(r, stream: false);
    server.listen((r) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(r).join())
          as Map<String, dynamic>);
      await respond(r);
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await storage.db.close();
    BackendConfig.host = previousHost;
    BackendConfig.useHttps = previousHttps;
    LoginSdkConfig.reset();
  });
  tearDownAll(() => File('/tmp/chatai-workflow-A-transport-payloads.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(evidence)));

  for (final backend in [false, true]) {
    final mode = backend ? 'backend' : 'direct';
    test('$mode 三节点真实HTTP独立模型/上下文，预留预算且不混入父助手资料', () async {
      respond = (r) async {
        final model = bodies.last['model'];
        await success(r,
            stream: false,
            content: model == 'review'
                ? '{"decision":"accept","feedback":"合成模型意见"}'
                : '$model-result');
      };
      final run = AgentWorkflowRunner(
          dao: dao,
          scope: scope(),
          workflow: await create(),
          serviceForProfile: (p) async => service(backend, model: p.modelId),
          profileAvailable: (_) async => true,
          foreground: () => true,
          background: _NoBackground(),
          backgroundEnabled: false,
          channel: AgentExecutionChannel());
      await run.start().timeout(const Duration(seconds: 8));
      expect(run.workflow.state, WorkflowState.complete);
      expect(bodies.map((b) => b['model']), ['analysis', 'writing', 'review']);
      expect(bodies.every((b) => b['max_tokens'] == 2048), true);
      expect((bodies.first['messages'] as List).length, 2);
      expect(jsonEncode(bodies[1]), contains('analysis-result'));
      expect(jsonEncode(bodies[2]), contains('writing-result'));
      expect(jsonEncode(bodies), isNot(contains('777')));
      expect((await dao.attemptHistory(run.workflow.id)).map((a) => a['state']),
          ['succeeded', 'succeeded', 'succeeded']);
      expect(run.workflow.dispatches, 3);
      expect(run.workflow.estimatedCost, null);
      evidence['$mode-three-nodes'] = {
        'bodies': bodies,
        'dispatches': run.workflow.dispatches,
        'states': (await dao.attemptHistory(run.workflow.id))
            .map((a) => a['state'])
            .toList()
      };
    });
    test('$mode 真实hook预算不足保持budgetExhausted，不被传输错误包装改判paused', () async {
      respond =
          (r) async => success(r, stream: false, content: 'analysis-result');
      final run = AgentWorkflowRunner(
          dao: dao,
          scope: scope(),
          workflow: await create(budget: 1),
          serviceForProfile: (p) async => service(backend, model: p.modelId),
          profileAvailable: (_) async => true,
          foreground: () => true,
          background: _NoBackground(),
          backgroundEnabled: false,
          channel: AgentExecutionChannel());
      await run.start();
      expect(bodies, hasLength(1));
      expect(run.workflow.state, WorkflowState.budgetExhausted);
      expect((await dao.read(run.workflow.id))!.state,
          WorkflowState.budgetExhausted);
    });
    test('$mode 最末模型撤权进入needsConfiguration，0 HTTP/0预算扣用', () async {
      var checks = 0;
      final run = AgentWorkflowRunner(
          dao: dao,
          scope: scope(),
          workflow: await create(),
          serviceForProfile: (p) async => service(backend, model: p.modelId),
          profileAvailable: (_) async => ++checks < 2,
          foreground: () => true,
          background: _NoBackground(),
          backgroundEnabled: false,
          channel: AgentExecutionChannel());
      await run.start();
      expect(bodies, isEmpty);
      expect(run.workflow.dispatches, 0);
      expect(run.workflow.state, WorkflowState.needsConfiguration);
    });
    for (final stream in [false, true]) {
      final label = '$mode-${stream ? 'stream' : 'nonstream'}';
      for (final limit in [1, 2]) {
        test('$label 503真实retry逐次预留，预算$limit且动态resolver保留', () async {
          respond = (r) async {
            if (bodies.length == 1) {
              r.response.statusCode = 503;
              r.response.write('{}');
              await r.response.close();
            } else {
              await success(r, stream: stream);
            }
          };
          final captured = scope();
          var w = await create(budget: limit);
          w = await dao.claim(captured, w.id, w.revision);
          final n = (await dao.steps(w.id)).first;
          w = await dao.beginStep(captured, WorkflowFence.of(w), n.id,
              inputHash: workflowHash('input'));
          String? attempt;
          var hooks = 0, resolvers = 0;
          final options = ChatRequestOptions(
              maxAutoRetries: 1,
              retryBaseDelay: Duration.zero,
              maxRetryDelay: Duration.zero,
              maxOutputTokensOverride: 2048,
              messagesForAttempt: (prepared) async => [
                    ...prepared,
                    {'role': 'system', 'content': 'dynamic-${++resolvers}'}
                  ],
              beforeDispatch: (messages) async {
                hooks++;
                if (attempt != null) {
                  w = await dao.finishAttempt(
                      captured, WorkflowFence.of(w), attempt!,
                      state: WorkflowAttemptState.failed, reason: '503');
                  w = await dao.claim(captured, w.id, w.revision);
                  w = await dao.beginStep(captured, WorkflowFence.of(w), n.id,
                      inputHash: workflowHash('input'));
                }
                final reserved = await dao.reserveDispatch(
                    captured, WorkflowFence.of(w), n.id,
                    inputHash: workflowHash(jsonEncode(messages)),
                    estimatedInput: 100);
                w = reserved.workflow;
                attempt = reserved.attemptId;
                if (!reserved.allowed) {
                  throw const ChatTransportException(
                      safeCode: 'invalid_request',
                      safeMessage: '合成预算拒绝',
                      failureKind: ChatFailureKind.state);
                }
              },
              dispatchIsCurrent: () => captured.isCurrent);
          if (limit == 1) {
            await expectLater(
                request(service(backend), stream, options), throwsA(anything));
            expect(w.state, WorkflowState.budgetExhausted);
            expect(bodies, hasLength(1));
          } else {
            await request(service(backend), stream, options);
            w = await dao.finishAttempt(captured, WorkflowFence.of(w), attempt!,
                state: WorkflowAttemptState.succeeded,
                result: '合成结果',
                promptTokens: 10,
                completionTokens: 5);
            expect(bodies, hasLength(2));
            expect(jsonEncode(bodies.last), contains('dynamic-2'));
          }
          expect(hooks, 2);
          expect(resolvers, 2);
          expect(w.dispatches, limit);
          expect(jsonEncode(bodies.first), contains('dynamic-1'));
          expect((await dao.attemptHistory(w.id)).length, limit);
          evidence['$label-retry-limit$limit'] = {
            'bodies': bodies,
            'hooks': hooks,
            'resolvers': resolvers,
            'dispatches': w.dispatches,
            'state': w.state.name
          };
        });
      }
      test('$label 默认协作无自动retry，503只发一次且记录失败不退款', () async {
        respond = (r) async {
          r.response.statusCode = 503;
          r.response.write('{}');
          await r.response.close();
        };
        final captured = scope();
        var w = await create();
        w = await dao.claim(captured, w.id, w.revision);
        final n = (await dao.steps(w.id)).first;
        w = await dao.beginStep(captured, WorkflowFence.of(w), n.id,
            inputHash: workflowHash('x'));
        String? attempt;
        await expectLater(
            request(
                service(backend),
                stream,
                ChatRequestOptions(
                    maxAutoRetries: 0,
                    maxOutputTokensOverride: 2048,
                    beforeDispatch: (m) async {
                      final a = await dao.reserveDispatch(
                          captured, WorkflowFence.of(w), n.id,
                          inputHash: workflowHash(jsonEncode(m)),
                          estimatedInput: 100);
                      w = a.workflow;
                      attempt = a.attemptId;
                    })),
            throwsA(isA<ChatTransportException>()
                .having((e) => e.statusCode, 'status', 503)));
        w = await dao.finishAttempt(captured, WorkflowFence.of(w), attempt!,
            state: WorkflowAttemptState.failed, reason: '503');
        expect(bodies, hasLength(1));
        expect(w.dispatches, 1);
        expect(w.reservedTokens, 2148);
      });
      for (final change in ['account', 'restore', 'cancel', 'dbFailure']) {
        test('$label 组装等待期间$change，最末hook拒绝且0 HTTP', () async {
          final captured = scope();
          var w = await create();
          w = await dao.claim(captured, w.id, w.revision);
          final n = (await dao.steps(w.id)).first;
          w = await dao.beginStep(captured, WorkflowFence.of(w), n.id,
              inputHash: workflowHash('x'));
          final ready = Completer<void>(), release = Completer<void>();
          final pending = request(
              service(backend),
              stream,
              ChatRequestOptions(
                  maxAutoRetries: 0,
                  maxOutputTokensOverride: 2048,
                  messagesForAttempt: (messages) async {
                    ready.complete();
                    await release.future;
                    return messages;
                  },
                  beforeDispatch: (messages) async {
                    final a = await dao.reserveDispatch(
                        captured, WorkflowFence.of(w), n.id,
                        inputHash: workflowHash(jsonEncode(messages)),
                        estimatedInput: 100);
                    w = a.workflow;
                  },
                  dispatchIsCurrent: () => captured.isCurrent));
          final assertion = expectLater(pending, throwsA(anything));
          await ready.future.timeout(const Duration(seconds: 5));
          switch (change) {
            case 'account':
              auth.account = 'b';
              epoch++;
            case 'restore':
              restore++;
            case 'cancel':
              captured.cancel();
            case 'dbFailure':
              await storage.db.execute(
                  'CREATE TRIGGER synthetic_budget_failure BEFORE INSERT ON ${AgentWorkflowDao.attempts} BEGIN SELECT RAISE(ABORT,\'synthetic\'); END');
          }
          release.complete();
          await assertion;
          expect(bodies, isEmpty);
          expect((await dao.read(w.id))!.dispatches, 0);
          expect(await dao.attemptHistory(w.id), isEmpty);
          evidence['$label-$change'] = {'http': bodies.length, 'dispatches': 0};
        });
      }
    }
  }
}

class _NoBackground implements AgentBackgroundExecution {
  @override
  bool isActive(String runId) => false;
  @override
  Future<void> stop({required String runId, bool success = false}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
