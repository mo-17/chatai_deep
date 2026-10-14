import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_task_verifier.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_coordinator.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/managed_attachment_store.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'agent_workflow_foundation_test.dart'
    show FakeWorkflowBackground, FakeWorkflowTransport;

class _Auth implements TokenStorage {
  String account = 'a';
  @override
  Future<void> clear() async {
    account = '';
  }

  @override
  Map<String, dynamic> readProfileSync() =>
      {'accountHash': account, 'userName': '合成', 'avatar': ''};
  @override
  Future<Map<String, dynamic>> readProfile() async => readProfileSync();
  @override
  String readTokenSync() => 'guest-mode';
  @override
  Future<String> readToken() async => readTokenSync();
  @override
  Future<void> writeProfile(
      {required String token,
      required String userName,
      String? avatar,
      Map<String, dynamic> extras = const {}}) async {
    account = extras['accountHash'] as String;
  }
}

/// 只观察实际客户端取消结果，保持原 abort 与消息钩子。
class _ObservedChat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareNonStreamingChatService {
  final ChatService inner;
  final void Function() cancelled;
  _ObservedChat(this.inner, this.cancelled);
  @override
  ModelCapabilities get capabilities => inner.capabilities;
  @override
  Future<ChatCompletionResult> chatWithUsageWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      required ChatRequestOptions options}) async {
    try {
      return await inner.chatWithUsageWithOptions(
          prompt: prompt,
          history: history,
          attachments: attachments,
          options: options);
    } on ChatTransportException catch (e) {
      if (e.failureKind == ChatFailureKind.cancelled ||
          e.safeCode == 'cancelled') {
        cancelled();
      }
      rethrow;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late HiDBManager storage;
  late AgentWorkflowDao dao;
  late _Auth auth;
  late int epoch;
  final evidence = <Object?>[];
  final profiles = {
    for (final r in WorkflowRole.values)
      r: WorkflowModelProfile('local', 'fixture', r.name)
  };
  AgentWorkflowScope scope() => AgentWorkflowScope(
      accountHash: auth.account, currentLoginEpoch: () => epoch);
  Future<AgentWorkspaceTools> tools() async =>
      AgentWorkspaceTools.create(storage,
          cid: 1,
          workspace: await AgentWorkspaceService.create(storage, cid: 1));
  Future<AgentWorkflow> create(
          {TaskAcceptanceCriteria acceptance =
              const TaskAcceptanceCriteria(requireFullRead: false)}) =>
      dao.createFromSource(scope(),
          cid: 1,
          newTask: '本次任务（不含条件哨兵）',
          newUserCreatedAt: 10,
          profiles: profiles,
          acceptance: acceptance);
  Future<AgentWorkflowRunner> fakeRun(
      AgentWorkflow task, AgentWorkspaceTools workspace) async {
    final transport = FakeWorkflowTransport();
    final r = AgentWorkflowRunner(
        dao: dao,
        scope: scope(),
        workflow: task,
        serviceForProfile: (p) async => transport.service(p),
        profileAvailable: (_) async => true,
        foreground: () => true,
        background: FakeWorkflowBackground(),
        backgroundEnabled: false,
        workspaceTools: workspace,
        channel: AgentExecutionChannel());
    await r.start().timeout(const Duration(seconds: 5));
    return r;
  }

  setUp(() async {
    LoginDao.resetHooksForTest();
    auth = _Auth();
    epoch = 0;
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'localhost:3000',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: auth,
        onLogoutNavigate: () {}));
    LoginDao.addLoginHook(() => epoch++);
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    await (await ConversationListDao.create(storage))
        .saveConversation(ConversationModel(cid: 1, title: '合成', icon: ''));
    dao = await AgentWorkflowDao.create(storage, accountHash: 'a');
  });
  tearDown(() async {
    await storage.db.close();
    LoginSdkConfig.reset();
  });
  tearDownAll(() async {
    const path = String.fromEnvironment('CHATAI_WORKFLOW_B_FIX_EVIDENCE');
    if (path.isNotEmpty) {
      await File(path).writeAsString(jsonEncode(evidence));
    }
  });

  for (final backend in [false, true]) {
    for (final stream in [false, true]) {
      test(
          '预算预留后配置撤销 ${backend ? 'Backend' : 'Direct'} ${stream ? 'stream' : 'nonstream'} 明确未发，明确继续才请求',
          () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final oldHost = BackendConfig.host, oldHttps = BackendConfig.useHttps;
        BackendConfig.host = '${server.address.host}:${server.port}';
        BackendConfig.useHttps = false;
        addTearDown(() async {
          await server.close(force: true);
          BackendConfig.host = oldHost;
          BackendConfig.useHttps = oldHttps;
        });
        final catalog = {
          'models': [
            for (final r in WorkflowRole.values)
              {
                'modelId': 'gpt-4o-${r.name}',
                'providerCode': 'openai',
                'supportsTool': true
              }
          ]
        };
        ModelCatalog.applyRemote(catalog);
        final settings = AISettings.defaults()
          ..providers = [
            AiProvider(
                id: 'fixture',
                name: '回环',
                type: 'openai',
                apiKey: 'synthetic',
                apiHost: 'http://${server.address.host}:${server.port}/v1',
                enabled: true,
                models: [
                  for (final r in WorkflowRole.values)
                    AiModel(id: 'gpt-4o-${r.name}')
                ])
          ]
          ..activeProviderId = 'fixture';
        var revoke = true;
        final s = scope();
        final models = AgentWorkflowModels(s,
            visibleSettings: () => null,
            settings: () async {
              if (revoke &&
                  (await storage.db.query(AgentWorkflowDao.attempts,
                          where: "state='dispatched'"))
                      .isNotEmpty) {
                revoke = false;
                if (backend) {
                  ModelCatalog.applyRemote({
                    'models': [
                      {'modelId': 'removed-synthetic', 'providerCode': 'openai'}
                    ]
                  });
                } else {
                  settings.providers.single.apiKey = '';
                }
              }
              return settings.clone();
            });
        final posts = <Map<String, dynamic>>[];
        server.listen((request) async {
          final body =
              (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                  .cast<String, dynamic>();
          posts.add(body);
          final content =
              (body['model'] as String).endsWith('review') ? '行' : '合成正文';
          final result = content == '行'
              ? '{"decision":"accept","feedback":"合成意见"}'
              : content;
          if (body['stream'] == true || request.uri.path.endsWith('/stream')) {
            request.response.headers.contentType =
                ContentType('text', 'event-stream', charset: 'utf-8');
            request.response.write('data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': result}
                    }
                  ],
                  'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
                })}\n\ndata: [DONE]\n\n');
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(backend
                ? {
                    'code': 0,
                    'data': {
                      'content': result,
                      'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
                    }
                  }
                : {
                    'choices': [
                      {
                        'message': {'content': result}
                      }
                    ],
                    'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
                  }));
          }
          await request.response.close();
        });
        final task = await dao.createFromSource(s,
            cid: 1,
            newTask: '纯合成任务',
            newUserCreatedAt: 10,
            profiles: {
              for (final r in WorkflowRole.values)
                r: WorkflowModelProfile(backend ? 'backend' : 'local',
                    backend ? 'backend' : 'fixture', 'gpt-4o-${r.name}')
            },
            grantedTools: stream ? {'list_files'} : {},
            acceptance: const TaskAcceptanceCriteria(
                expectedOutputNames: ['result.md'],
                format: 'md',
                requiredTerms: ['CONFIRMED_HTTP_TERM'],
                requireFullRead: false));
        final workspace = await tools();
        await workspace.store.saveCriteria(
            2,
            const TaskAcceptanceCriteria(requiredTerms: ['OTHER_HTTP_CID'])
                .toJson());
        AgentWorkflowRunner runner(AgentWorkflow w) => AgentWorkflowRunner(
            dao: dao,
            scope: s.fork(),
            workflow: w,
            serviceForProfile: models.service,
            profileAvailable: models.available,
            foreground: () => true,
            background: FakeWorkflowBackground(),
            backgroundEnabled: false,
            workspaceTools: workspace,
            channel: AgentExecutionChannel());
        final first = runner(task);
        await first.start().timeout(const Duration(seconds: 8));
        expect(posts, isEmpty);
        expect(first.workflow.state, WorkflowState.needsConfiguration);
        final failed = await dao.attemptHistory(task.id);
        expect(failed.single['state'], 'failed');
        expect(failed.single['reason'], contains('明确未发送'));
        expect(failed.single['promptTokens'], 0);
        expect(failed.single['completionTokens'], 0);
        expect(first.workflow.dispatches, 1);
        expect(first.workflow.reservedTokens, greaterThan(0));
        ModelCatalog.applyRemote(catalog);
        settings.providers.single.apiKey = 'synthetic';
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(posts, isEmpty);
        final resumed = runner(first.workflow);
        await resumed.start().timeout(const Duration(seconds: 8));
        expect(resumed.workflow.state, WorkflowState.waitingConfirmation);
        expect(posts, hasLength(3));
        expect(resumed.workflow.dispatches, 4);
        for (final post in posts) {
          expect(jsonEncode(post), contains('CONFIRMED_HTTP_TERM'));
          expect(jsonEncode(post), isNot(contains('OTHER_HTTP_CID')));
        }
        evidence.add({
          'case': 'unsent',
          'backend': backend,
          'stream': stream,
          'unsentAttempt': failed.single,
          'posts': posts
        });
      });
    }
  }

  for (final deletion in [false, true]) {
    test('验收读取后成果${deletion ? '删除' : '编辑'}，accept拒绝通过与发布', () async {
      final workspace = await tools();
      final task = (await fakeRun(
              await create(
                  acceptance: const TaskAcceptanceCriteria(
                      expectedOutputNames: ['result.md'],
                      requireFullRead: false)),
              workspace))
          .workflow;
      expect(task.state, WorkflowState.waitingConfirmation);
      final id = await dao.publishOutputOnce(scope(), task, name: 'result.md');
      final arrived = Completer<void>(), release = Completer<void>();
      await workspace.beginTurn(10, [],
          resume: true,
          executionGuard: () => true,
          transactionGuard: (tx) =>
              dao.verifySnapshotTransaction(scope(), task, tx),
          stableOperation: (action) async {
            arrived.complete();
            await release.future;
            await scope().stable(action);
          });
      final reading = workspace.verify();
      await arrived.future.timeout(const Duration(seconds: 3));
      final files = await AgentWorkspaceDao.create(storage, cid: 1);
      if (deletion) {
        await storage.db.delete(AgentWorkspaceDao.filesTable,
            where: 'id=? AND cid=?', whereArgs: [id, 1]);
      } else {
        await files.saveOutput(
            fileId: id,
            name: 'result.md',
            content: '手动修改',
            contentHash: workflowHash('手动修改'),
            sizeBytes: 12,
            note: '用户编辑');
      }
      release.complete();
      final report = await reading;
      expect(report.isPassed, true);
      await expectLater(dao.acceptVerification(scope(), task, report),
          throwsA(isA<WorkflowStale>()));
      expect(
          (await dao.read(task.id))!.state, WorkflowState.waitingConfirmation);
      expect(await storage.db.query(AgentWorkflowDao.publications), isEmpty);
      expect(
          await storage.db.query('tb_messages',
              where: 'ownerType=?', whereArgs: [OwnerType.receiver.toString()]),
          isEmpty);
    });
  }
  test('已接受的验收文件变化，首次reply发布拒绝', () async {
    final workspace = await tools();
    var task = (await fakeRun(
            await create(
                acceptance: const TaskAcceptanceCriteria(
                    expectedOutputNames: ['result.md'],
                    requireFullRead: false)),
            workspace))
        .workflow;
    final id = await dao.publishOutputOnce(scope(), task, name: 'result.md');
    await workspace.beginTurn(10, [], resume: true);
    task =
        await dao.acceptVerification(scope(), task, await workspace.verify());
    await (await AgentWorkspaceDao.create(storage, cid: 1)).saveOutput(
        fileId: id,
        name: 'result.md',
        content: '变化',
        contentHash: workflowHash('变化'),
        sizeBytes: 6,
        note: '用户编辑');
    await expectLater(
        dao.publishReplyOnce(scope(), task.id, task.revision, createdAt: 20),
        throwsA(isA<WorkflowStale>()));
    expect(await storage.db.query(AgentWorkflowDao.publications), isEmpty);
  });
  for (final completing in [false, true]) {
    test('${completing ? 'complete' : 'saveVerification'}事务拒绝验收后的成果变动',
        () async {
      final workspace = await tools();
      var task = (await fakeRun(
              await create(
                  acceptance: const TaskAcceptanceCriteria(
                      expectedOutputNames: ['result.md'],
                      requireFullRead: false)),
              workspace))
          .workflow;
      final id = await dao.publishOutputOnce(scope(), task, name: 'result.md');
      task = await dao.stop(scope(), task.id, task.revision);
      task = await dao.claim(scope(), task.id, task.revision);
      await workspace.beginTurn(10, [],
          resume: true,
          executionGuard: () => true,
          transactionGuard: (tx) =>
              dao.verifyTransaction(scope(), WorkflowFence.of(task), tx),
          stableOperation: (a) => scope().stable(a));
      final report = await workspace.verify();
      expect(report.isPassed, true);
      if (completing) {
        task =
            await dao.saveVerification(scope(), WorkflowFence.of(task), report);
      }
      await (await AgentWorkspaceDao.create(storage, cid: 1)).saveOutput(
          fileId: id,
          name: 'result.md',
          content: '验收后编辑',
          contentHash: workflowHash('验收后编辑'),
          sizeBytes: 15,
          note: '用户编辑');
      await expectLater(
          completing
              ? dao.complete(scope(), WorkflowFence.of(task))
              : dao.saveVerification(scope(), WorkflowFence.of(task), report),
          throwsA(isA<WorkflowStale>()));
      expect((await dao.read(task.id))!.state, WorkflowState.running);
      expect(await storage.db.query(AgentWorkflowDao.publications), isEmpty);
    });
  }

  for (final reportWrite in [false, true]) {
    for (final restore in [false, true]) {
      test(
          '${reportWrite ? 'report' : 'beginTurn'}落盘前${restore ? '真实恢复' : '源删重建'}，旧验收不写新状态',
          () async {
        final task = await create(), workspace = await tools();
        List<int>? archive;
        if (restore) {
          final root =
              await Directory.systemTemp.createTemp('workflow-B-restore-');
          BackupService.debugGeneratedImageDirectoryResolver = () async => root;
          BackupService.debugRoleCardAssetsDirectoryResolver = () async => root;
          ManagedAttachmentStore.debugRootDirectory =
              Directory('${root.path}/attachments');
          addTearDown(() async {
            BackupService.debugGeneratedImageDirectoryResolver = null;
            BackupService.debugRoleCardAssetsDirectoryResolver = null;
            ManagedAttachmentStore.debugRootDirectory = null;
            await root.delete(recursive: true);
          });
          archive = await BackupService(storage)
              .exportArchive(settings: AISettings.defaults(), accountHash: 'a');
        }
        final arrived = Completer<void>(), release = Completer<void>();
        Future<void> stable(Future<void> Function() a) async {
          arrived.complete();
          await release.future;
          await scope().stable(a);
        }

        Future<void> guard(Transaction tx) =>
            dao.verifySnapshotTransaction(scope(), task, tx);
        if (reportWrite) {
          await workspace.beginTurn(10, [],
              executionGuard: () => true,
              transactionGuard: guard,
              stableOperation: (a) => scope().stable(a));
        }
        final Future<void> stale;
        if (reportWrite) {
          workspace.bindReadTransactionGuard(guard, stable);
          stale = workspace.verify().then((_) {});
        } else {
          stale = workspace.beginTurn(10, [],
              executionGuard: () => true,
              transactionGuard: guard,
              stableOperation: stable);
        }
        final caught = expectLater(stale, throwsA(isA<WorkflowStale>()));
        await arrived.future.timeout(const Duration(seconds: 3));
        if (restore) {
          await BackupService(storage)
              .importArchive(archive!, accountHash: 'a');
        } else {
          await storage.db.delete('tb_messages',
              where: 'id=?', whereArgs: [task.toRow()['sourceRowId']]);
          await (await MessageDao.create(storage, cid: 1))
              .saveMessageWithBlocks(MessageModel(
                  content: '新消息', ownerType: OwnerType.sender, createdAt: 10));
        }
        await workspace.store.saveCriteria(
            1,
            const TaskAcceptanceCriteria(requiredTerms: ['NEW_CRITERIA'])
                .toJson());
        await workspace.store.beginTurn(1, 10, {
          'inputIds': [],
          'outputs': {},
          'criteria': const TaskAcceptanceCriteria().toJson()
        });
        await workspace.store.saveCriteria(
            1,
            const TaskAcceptanceCriteria(requiredTerms: ['NEW_CRITERIA'])
                .toJson());
        await workspace.store.saveReport(1, 10, {'sentinel': 'NEW_REPORT'});
        final before = await workspace.store.loadTurn(1, 10);
        release.complete();
        await caught;
        expect(await workspace.store.criteriaArmed(1), true);
        expect(await workspace.store.loadTurn(1, 10), before);
        expect(await workspace.store.loadLatestReport(1),
            {'sentinel': 'NEW_REPORT'});
        expect(await storage.db.query('tb_agent_read_interval'), isEmpty);
      });
    }
  }

  for (final next in ['b', 'a']) {
    test('真实LoginDao A→$next held HTTP及时撤销，释放许可后新登录任务可开始', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final held = Completer<void>(),
          release = Completer<void>(),
          clientCancelled = Completer<void>();
      final posts = <Map<String, dynamic>>[];
      var aborted = false;
      server.listen((r) async {
        final body = (jsonDecode(await utf8.decoder.bind(r).join()) as Map)
            .cast<String, dynamic>();
        posts.add(body);
        if (posts.length == 1) {
          r.response.done.catchError((Object _) {
            aborted = true;
          });
          held.complete();
          await release.future;
        }
        final text = (body['model'] as String).endsWith('review')
            ? '{"decision":"accept","feedback":"合成意见"}'
            : '合成正文';
        try {
          r.response.headers.contentType = ContentType.json;
          r.response.write(jsonEncode({
            'choices': [
              {
                'message': {'content': text}
              }
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          }));
          await r.response.close();
        } on SocketException {
          aborted = true;
        } on HttpException {
          aborted = true;
        }
      });
      final settings = AISettings.defaults()
        ..providers = [
          AiProvider(
              id: 'fixture',
              name: '回环',
              type: 'openai',
              apiKey: 'synthetic',
              apiHost: 'http://${server.address.host}:${server.port}/v1',
              enabled: true,
              models: [
                for (final r in WorkflowRole.values) AiModel(id: r.name)
              ])
        ]
        ..activeProviderId = 'fixture';
      final channel = AgentExecutionChannel(),
          native = FakeWorkflowBackground(granted: true);
      final coordinator = AgentWorkflowCoordinator(
          channel: channel,
          background: native,
          foreground: () => true,
          profileAvailable: (_) async => true,
          serviceForProfile: (p) async => _ObservedChat(
                  await AgentWorkflowModels(scope(),
                      settings: () async => settings.clone(),
                      visibleSettings: () => null).service(p), () {
                aborted = true;
                if (!clientCancelled.isCompleted) {
                  clientCancelled.complete();
                }
              }));
      final old = await dao.createFromSource(scope(),
          cid: 1,
          newTask: '旧合成任务',
          newUserCreatedAt: 10,
          profiles: profiles,
          backgroundEnabled: true,
          acceptance: const TaskAcceptanceCriteria(requireFullRead: false));
      final pending = coordinator.start(dao, scope(), old);
      await held.future.timeout(const Duration(seconds: 3));
      await LoginDao.saveAuthToken('guest-mode',
          userName: '合成',
          extras: {'accountHash': next}).timeout(const Duration(seconds: 3));
      await pending.timeout(const Duration(seconds: 3));
      await clientCancelled.future.timeout(const Duration(seconds: 3));
      expect(native.started, hasLength(1));
      expect(native.stopped, 1);
      expect(native.active, false);
      final oldRow = (await dao.read(old.id))!.toRow(),
          oldAttempts = await dao.attemptHistory(old.id);
      expect(await storage.db.query(AgentWorkflowDao.publications), isEmpty);
      final targetStorage = next == 'a'
          ? storage
          : HiDBManager.test(await databaseFactoryFfi.openDatabase(
              inMemoryDatabasePath,
              options: OpenDatabaseOptions(singleInstance: false)));
      if (next != 'a') {
        addTearDown(() => targetStorage.db.close());
      }
      final cid = next == 'a' ? 2 : 1;
      await (await ConversationListDao.create(targetStorage)).saveConversation(
          ConversationModel(cid: cid, title: '新合成', icon: ''));
      final target =
          await AgentWorkflowDao.create(targetStorage, accountHash: next);
      final task = await target.createFromSource(scope(),
          cid: cid,
          newTask: '新登录任务',
          newUserCreatedAt: 30,
          profiles: profiles,
          acceptance: const TaskAcceptanceCriteria(requireFullRead: false));
      await coordinator
          .start(target, scope(), task)
          .timeout(const Duration(seconds: 5));
      expect((await target.read(task.id))!.state, WorkflowState.complete);
      expect(posts, hasLength(4));
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await dao.read(old.id))!.toRow(), oldRow);
      expect(await dao.attemptHistory(old.id), oldAttempts);
      expect(
          await storage.db.query(AgentWorkflowDao.publications,
              where: 'parentId=?', whereArgs: [old.id]),
          isEmpty);
      expect(aborted, true);
      evidence.add({
        'case': 'login-held-http',
        'next': next,
        'posts': posts,
        'oldAttempts': oldAttempts,
        'aborted': aborted,
        'nativeStarts': native.started,
        'nativeStops': native.stopped
      });
    });
  }
  test('三个独立节点收到本任务条件，别的对话条件不进入；按实际payload预算', () async {
    final transport = FakeWorkflowTransport();
    final task = await create(
        acceptance: const TaskAcceptanceCriteria(
            expectedOutputNames: ['result.csv'],
            format: 'csv',
            minChars: 2,
            maxChars: 500,
            requiredTerms: ['CONFIRMED_TERM'],
            requireFullRead: false));
    final workspace = await tools();
    await workspace.store.saveCriteria(
        2,
        const TaskAcceptanceCriteria(requiredTerms: ['OTHER_CID_TERM'])
            .toJson());
    final r = AgentWorkflowRunner(
        dao: dao,
        scope: scope(),
        workflow: task,
        serviceForProfile: (p) async => transport.service(p),
        profileAvailable: (_) async => true,
        foreground: () => true,
        background: FakeWorkflowBackground(),
        backgroundEnabled: false,
        workspaceTools: workspace,
        channel: AgentExecutionChannel());
    await r.start().timeout(const Duration(seconds: 5));
    expect(transport.requests, hasLength(3));
    for (final req in transport.requests) {
      expect(jsonEncode(req), contains('CONFIRMED_TERM'));
      expect(jsonEncode(req), contains('csv'));
      expect(jsonEncode(req), isNot(contains('OTHER_CID_TERM')));
    }
    expect(r.workflow.reservedTokens, greaterThan(3 * 2048));
    evidence
        .add({'case': 'confirmedAcceptance', 'requests': transport.requests});
  });
  test('DAO拒绝多输出/JSON/过大输出/无读取能力，零源行零父任务', () async {
    for (final c in [
      const TaskAcceptanceCriteria(expectedOutputNames: ['a.md', 'b.md']),
      const TaskAcceptanceCriteria(expectedOutputNames: ['result.json']),
      const TaskAcceptanceCriteria(format: 'json'),
      const TaskAcceptanceCriteria(minChars: 12001)
    ]) {
      await expectLater(create(acceptance: c), throwsFormatException);
    }
    final f = await (await AgentWorkspaceDao.create(storage, cid: 1)).saveInput(
        name: 'in.txt',
        sourceKey: 'x',
        contentHash: workflowHash('x'),
        content: 'x',
        pageTexts: [],
        sizeBytes: 1);
    await expectLater(
        dao.createFromSource(scope(),
            cid: 1,
            newTask: '无能力',
            newUserCreatedAt: 10,
            profiles: profiles,
            inputFileIds: [f.id],
            grantedTools: {'read_file'}),
        throwsFormatException);
    expect(await storage.db.query('tb_messages'), isEmpty);
    expect(await storage.db.query(AgentWorkflowDao.workflows), isEmpty);
  });
}
