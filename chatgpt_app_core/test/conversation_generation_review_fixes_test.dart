import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/conversation_execution_registry.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/conversation_generation.dart';
import 'package:chatgpt_app_core/dao/chat/backend_chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/dao/chat/direct_chat_service.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'agent_workflow_foundation_test.dart' show FakeWorkflowBackground;
import 'conversation_generation_test.dart'
    show GenerationTestAuth, generationSettings;

/// 所有 HTTP、账号与资料均为回环合成数据；捕获真正客户端的取消而非测试主动 stop。
class _CancelObservedBackend extends BackendChatService {
  final Completer<void> cancelled;
  _CancelObservedBackend(super.settings, this.cancelled);
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      attachments,
      required ChatRequestOptions options}) async {
    try {
      return await super.chatWithUsageWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: options);
    } on ChatTransportException catch (e) {
      if ((e.failureKind == ChatFailureKind.cancelled ||
              e.safeCode == 'cancelled') &&
          !cancelled.isCompleted) {
        cancelled.complete();
      }
      rethrow;
    }
  }
}

class _CancelObservedDirect extends DirectChatService {
  final Completer<void> cancelled;
  _CancelObservedDirect(super.config, this.cancelled);
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      attachments,
      required ChatRequestOptions options}) async {
    try {
      return await super.chatWithUsageWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: options);
    } on ChatTransportException catch (e) {
      if ((e.failureKind == ChatFailureKind.cancelled ||
              e.safeCode == 'cancelled') &&
          !cancelled.isCompleted) {
        cancelled.complete();
      }
      rethrow;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final original = HttpOverrides.current;
  HttpOverrides.global = null;
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late ConversationListDao conversations;
  late ConversationGenerationService service;
  late HttpServer server;
  late String oldHost;
  late bool oldHttps;
  late int rowId;
  late AISettings settings;
  final evidence = <Object>[];
  late Future<void> Function(HttpRequest) respond;
  final servers = <HttpServer>[];
  final gates = <Completer<void>>[];
  Future<void> jsonResponse(HttpRequest r, Map<String, dynamic> body) async {
    try {
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(body));
      await r.response.close();
    } on SocketException {/* 客户端已取消，真实迟到响应不得落盘。 */} on HttpException {/* 同上。 */}
  }

  Map<String, dynamic> catalog(bool available) => {
        'code': 0,
        'data': {
          'models': available
              ? [
                  {'modelId': 'gpt-4o-a', 'providerCode': 'openai'}
                ]
              : []
        }
      };
  Future<HttpServer> newServer(
      Future<void> Function(HttpRequest) handler) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(s);
    s.listen(handler);
    return s;
  }

  void endpoint(HttpServer s) {
    BackendConfig.host = '${s.address.host}:${s.port}';
    BackendConfig.useHttps = false;
  }

  ConversationGenerationRun start(
      {String account = 'a',
      String prompt = 'new',
      int at = 100,
      bool backend = true}) {
    final selected = settings.clone();
    if (backend) {
      selected.mode = AIMode.backend;
      selected.backendModel = 'gpt-4o-a';
    }
    return service.start(
        scope: ConversationGenerationScope(account: account),
        dao: dao,
        profile: ConversationGenerationProfile(selected, account,
            loadSettings: () async => selected, visibleSettings: () => null),
        input: ConversationGenerationInput(
            cid: 1,
            conversationRowId: rowId,
            stream: false,
            user: MessageModel(
                ownerType: OwnerType.sender, content: prompt, createdAt: at)),
        preparation:
            ReadyConversationTurn(PreparedConversationTurn(prompt: prompt)));
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    GenerationTestAuth().install();
    ModelCatalog.resetExecutionForTest();
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    conversations = await ConversationListDao.create(storage);
    rowId = (await conversations
        .saveConversation(ConversationModel(cid: 1, title: '合成', icon: '')))!;
    dao = await ConversationGenerationDao.create(storage);
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    server = await newServer((r) => respond(r));
    endpoint(server);
    settings = generationSettings()
      ..activeProvider.apiHost =
          'http://${server.address.host}:${server.port}/v1';
    service = ConversationGenerationService(createMemory: (_) async => null);
  });
  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    for (final run in service.runs.where((r) => r.busy)) {
      await run.retire('fixture cleanup');
    }
    service.dispose();
    for (final s in servers) {
      await s.close(force: true);
    }
    servers.clear();
    await storage.db.close();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    LoginSdkConfig.reset();
  });

  for (final change in [
    'account',
    'same-account-login',
    'endpoint',
    'refresh-generation'
  ]) {
    test(
        'late $change directory response cannot revoke a new no-UI-provider backend request',
        () async {
      final oldArrived = Completer<void>(),
          oldRelease = Completer<void>(),
          posted = Completer<void>(),
          postRelease = Completer<void>(),
          cancelled = Completer<void>();
      gates.addAll([oldRelease, postRelease]);
      var gets = 0, posts = 0;
      Future<void> handler(HttpRequest r) async {
        if (r.uri.path == '/uapi/ai/catalog') {
          gets++;
          if (gets == 1) {
            oldArrived.complete();
            await oldRelease.future;
            await jsonResponse(r, catalog(false));
          } else {
            await jsonResponse(r, catalog(true));
          }
        } else {
          await utf8.decoder.bind(r).join();
          posts++;
          posted.complete();
          await postRelease.future;
          await jsonResponse(r, {
            'code': 0,
            'data': {'content': 'late-should-ignore'}
          });
        }
      }

      respond = handler;
      final oldRefresh = ModelCatalog.refreshFromBackend();
      await oldArrived.future.timeout(const Duration(seconds: 3));
      var account = 'a';
      if (change == 'account' || change == 'same-account-login') {
        account = change == 'account' ? 'b' : 'a';
        await LoginDao.saveAuthToken('synthetic-new',
            userName: '合成', extras: {'accountHash': account});
      } else if (change == 'endpoint') {
        final fresh = await newServer(handler);
        endpoint(fresh);
      }
      await ModelCatalog.refreshFromBackend();
      service.dispose();
      final selected = settings.clone()..mode = AIMode.backend;
      selected.backendModel = 'gpt-4o-a';
      service = ConversationGenerationService(
          createMemory: (_) async => null,
          createChat: (_) => _CancelObservedBackend(selected, cancelled));
      final run = start(account: account);
      await posted.future.timeout(const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException(
              'POST not reached; run=${run.stage}; notice=${run.notice}'));
      oldRelease.complete();
      await oldRefresh;
      expect(ModelCatalog.backendProfileAvailable('gpt-4o-a', account: account),
          isTrue);
      expect(run.stage, ConversationGenerationStage.generating);
      expect(cancelled.isCompleted, isFalse);
      // 同一身份的真正新空目录必须自动取消；不调用 run.stop 帮助这个断言。
      respond = (r) => jsonResponse(r, catalog(false));
      if (change == 'endpoint') {
        // 新 endpoint 的 handler 也要改为真实空目录。
        final fresh = await newServer((r) => jsonResponse(r, catalog(false)));
        endpoint(fresh);
      } else {
        await ModelCatalog.refreshFromBackend();
      }
      await run.finished.timeout(const Duration(seconds: 3),
          onTimeout: () =>
              throw TimeoutException('run not settled: ${run.stage}'));
      await cancelled.future.timeout(const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException(
              'client cancellation not observed; run=${run.stage}; posts=$posts'));
      expect(run.stage, ConversationGenerationStage.interrupted);
      expect(posts, 1);
      expect(service.registry.lookup(account, 1), isNull);
      postRelease.complete();
      evidence.add({
        'case': change,
        'posts': posts,
        'clientCancelled': true,
        'oldDirectoryIgnored': true
      });
    });
  }

  test(
      'UI cached/applyRemote empty directory cannot supply execution authority',
      () async {
    respond = (r) async {
      await utf8.decoder.bind(r).join();
      await jsonResponse(r, {
        'code': 0,
        'data': {'content': 'NO_UI_CACHE_AUTHORITY'}
      });
    };
    ModelCatalog.applyRemote({'models': []});
    final run = start();
    await run.finished.timeout(const Duration(seconds: 3),
        onTimeout: () =>
            throw TimeoutException('run not settled: ${run.stage}'));
    expect(run.stage, ConversationGenerationStage.complete);
    expect(run.receiver.content, 'NO_UI_CACHE_AUTHORITY');
    expect(run.record!.attempts, 1);
  });

  test(
      'confirmed current revocation survives UI cache and failed refresh; zero chat POST or source rows',
      () async {
    var failRefresh = false, chatPosts = 0;
    respond = (r) async {
      if (r.uri.path == '/uapi/ai/catalog') {
        if (failRefresh) {
          r.response.statusCode = 503;
          await r.response.close();
        } else {
          await jsonResponse(r, catalog(false));
        }
      } else {
        chatPosts++;
        await jsonResponse(r, {
          'code': 0,
          'data': {'content': 'unexpected'}
        });
      }
    };
    await ModelCatalog.refreshFromBackend();
    expect(ModelCatalog.backendProfileAvailable('gpt-4o-a', account: 'a'),
        isFalse);
    ModelCatalog.loadFromCache();
    ModelCatalog.applyRemote(catalog(true)['data'] as Map<String, dynamic>);
    failRefresh = true;
    await ModelCatalog.refreshFromBackend();
    expect(ModelCatalog.backendProfileAvailable('gpt-4o-a', account: 'a'),
        isFalse);
    final run = start();
    await run.finished.timeout(const Duration(seconds: 3));
    expect(chatPosts, 0);
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect(await storage.db.query('tb_conversation_generation'), isEmpty);
    evidence.add({
      'case': 'revocation-ui-cache-failed-refresh',
      'posts': 0,
      'sourceRows': 0
    });
  });

  for (final target in ['a', 'b']) {
    test(
        'real login A→$target cancels ordinary held client and new identity can run without old retirement contamination',
        () async {
      final arrived = Completer<void>(),
          release = Completer<void>(),
          cancelled = Completer<void>();
      gates.add(release);
      final posts = <Map<String, dynamic>>[];
      respond = (r) async {
        posts.add(jsonDecode(await utf8.decoder.bind(r).join())
            as Map<String, dynamic>);
        final old = posts.length == 1;
        if (old) {
          arrived.complete();
          await release.future;
        }
        await jsonResponse(r, {
          'code': 0,
          'data': {
            'content': old ? 'LATE_OLD' : 'CURRENT_REPLY',
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          }
        });
      };
      service.dispose();
      service = ConversationGenerationService(
          createMemory: (_) async => null,
          createChat: (selected) =>
              _CancelObservedBackend(selected, cancelled));
      final old = start(prompt: 'OLD', at: 10);
      await arrived.future.timeout(const Duration(seconds: 3));
      await LoginDao.saveAuthToken('synthetic-next',
          userName: '合成',
          extras: {'accountHash': target}).timeout(const Duration(seconds: 3));
      await old.finished.timeout(const Duration(seconds: 3));
      await cancelled.future.timeout(const Duration(seconds: 3));
      expect(old.executionStopped, isTrue);
      expect(old.busy, isFalse);
      expect(service.registry.lookup('a', 1), isNull);
      final originalStorage = storage;
      expect(await originalStorage.db.query('tb_usage'), isEmpty);
      expect(
          await originalStorage.db
              .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
          isEmpty);
      if (target == 'b') {
        storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
            inMemoryDatabasePath,
            options: OpenDatabaseOptions(singleInstance: false)));
        addTearDown(() => originalStorage.db.close());
        conversations = await ConversationListDao.create(storage);
        rowId = (await conversations.saveConversation(
            ConversationModel(cid: 1, title: '账号B合成', icon: '')))!;
        dao = await ConversationGenerationDao.create(storage);
      }
      final next = start(account: target, prompt: 'CURRENT', at: 100);
      await next.finished.timeout(const Duration(seconds: 3));
      expect(next.stage, ConversationGenerationStage.complete);
      expect(posts, hasLength(2));
      expect(next.record!.attempts, 1);
      await old.retryPersistence();
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await storage.db.query('tb_usage'), hasLength(1));
      expect(
          await storage.db
              .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
          hasLength(1));
      expect(await storage.db.query('tb_messages', where: "content='LATE_OLD'"),
          isEmpty);
      if (target == 'b') {
        expect(await originalStorage.db.query('tb_usage'), isEmpty);
        expect(
            await originalStorage.db
                .query('tb_messages', where: "ownerType='OwnerType.receiver'"),
            isEmpty);
      }
      evidence.add({
        'case': 'ordinary-login-a-to-$target',
        'posts': posts,
        'clientCancelled': true,
        'oldLateReplies': 0,
        'oldUsage': 0,
        'newUsage': 1,
        'newReply': 1
      });
    });
  }

  for (final deleteConversation in [false, true]) {
    test(
        'real workflow held HTTP cancelled by DAO ${deleteConversation ? "conversation" : "source"} deletion, same cid can immediately run ordinary',
        () async {
      final entered = Completer<void>(),
          release = Completer<void>(),
          clientCancelled = Completer<void>();
      gates.add(release);
      var posts = 0;
      respond = (r) async {
        await utf8.decoder.bind(r).join();
        posts++;
        if (posts == 1) {
          entered.complete();
          await release.future;
        }
        await jsonResponse(r, {
          'choices': [
            {
              'message': {'content': 'ORDINARY_NEW'}
            }
          ],
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
        });
      };
      final workflowDao =
          await AgentWorkflowDao.create(storage, accountHash: 'a');
      final scope = AgentWorkflowScope(accountHash: 'a');
      final task = await workflowDao.createFromSource(scope,
          cid: 1,
          newTask: 'WORKFLOW_OLD',
          newUserCreatedAt: 10,
          profiles: {
            for (final role in WorkflowRole.values)
              role: WorkflowModelProfile('local', 'fixture', role.name)
          },
          acceptance: const TaskAcceptanceCriteria(requireFullRead: false));
      final native = FakeWorkflowBackground(granted: true);
      final runner = AgentWorkflowRunner(
          dao: workflowDao,
          scope: scope,
          workflow: task,
          serviceForProfile: (p) async => _CancelObservedDirect(
              ProviderConfig(
                  apiKey: 'synthetic',
                  baseUrl:
                      'http://${server.address.host}:${server.port}/v1/chat/completions',
                  model: p.modelId),
              clientCancelled),
          profileAvailable: (_) async => true,
          foreground: () => true,
          background: native,
          channel: AgentExecutionChannel());
      final running = runner.start();
      await entered.future.timeout(const Duration(seconds: 3));
      expect(ConversationExecutionRegistry.instance.lookup('a', 1)!.storageKey,
          same(storage.db));
      if (deleteConversation) {
        await conversations
            .deleteConversation(
                ConversationModel(cid: 1, id: rowId, icon: '', title: '合成'))
            .timeout(const Duration(seconds: 3));
        rowId = (await conversations.saveConversation(
            ConversationModel(cid: 1, title: '新会话', icon: '')))!;
      } else {
        await (await MessageDao.create(storage, cid: 1))
            .deleteMessage(task.toRow()['sourceRowId'] as int)
            .timeout(const Duration(seconds: 3));
      }
      await running.timeout(const Duration(seconds: 3));
      await clientCancelled.future.timeout(const Duration(seconds: 3));
      expect(ConversationExecutionRegistry.instance.lookup('a', 1), isNull);
      expect(native.active, false);
      expect(await storage.db.query(AgentWorkflowDao.publications), isEmpty);
      final fresh = start(backend: false);
      await fresh.finished.timeout(const Duration(seconds: 3));
      expect(fresh.stage, ConversationGenerationStage.complete);
      expect(posts, 2);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
          await storage.db
              .query('tb_messages', where: "content='ORDINARY_NEW'"),
          hasLength(1));
      evidence.add({
        'case': deleteConversation
            ? 'workflow-delete-conversation'
            : 'workflow-delete-source',
        'posts': posts,
        'publicationCount': 0,
        'ordinaryComplete': true,
        'nativeReleased': true,
        'clientCancelled': true
      });
    });
  }

  test(
      'cid maintenance blocks new admission through actual deletion window while another cid is untouched',
      () async {
    final registry = ConversationExecutionRegistry();
    final stopped = Completer<void>(),
        stopRelease = Completer<void>(),
        transaction = Completer<void>(),
        commit = Completer<void>();
    final owner1 = Object(), owner2 = Object();
    late final ConversationExecutionTicket ticket1;
    ticket1 = registry.claim(
        account: 'a',
        cid: 1,
        owner: owner1,
        storageKey: storage.db,
        kind: ConversationExecutionKind.ordinary,
        stop: (_) async {
          stopped.complete();
          await stopRelease.future;
          registry.release(ticket1);
        });
    final ticket2 = registry.claim(
        account: 'a',
        cid: 2,
        owner: owner2,
        storageKey: storage.db,
        kind: ConversationExecutionKind.ordinary,
        stop: (_) async => fail('不应停止另一个 cid'));
    final maintaining = registry.maintainStorage(
        storage.db,
        () => storage.db.transaction((tx) async {
              transaction.complete();
              await commit.future;
              await tx.delete('tb_messages', where: 'cid=?', whereArgs: [1]);
            }),
        cid: 1);
    await stopped.future;
    stopRelease.complete();
    await transaction.future;
    expect(
        () => registry.claim(
            account: 'a',
            cid: 1,
            owner: Object(),
            storageKey: storage.db,
            kind: ConversationExecutionKind.ordinary,
            stop: (_) async {}),
        throwsStateError);
    expect(registry.lookup('a', 2), same(ticket2));
    commit.complete();
    await maintaining;
    final replacement = registry.claim(
        account: 'a',
        cid: 1,
        owner: Object(),
        storageKey: storage.db,
        kind: ConversationExecutionKind.ordinary,
        stop: (_) async {});
    registry.release(ticket1);
    expect(registry.lookup('a', 1), same(replacement));
    registry.release(replacement);
    registry.release(ticket2);
  });

  tearDownAll(() async {
    const path = String.fromEnvironment('CHATAI_CONTINUITY_REVIEW_EVIDENCE');
    if (path.isNotEmpty) await File(path).writeAsString(jsonEncode(evidence));
    HttpOverrides.global = original;
  });
}
