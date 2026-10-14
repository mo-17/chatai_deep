import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/agent_execution_channel.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_models.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_runner.dart';
import 'package:chatgpt_app_core/chat/application/agent_workflow_scope.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_service.dart';
import 'package:chatgpt_app_core/chat/application/agent_workspace_tools.dart';
import 'package:chatgpt_app_core/chat/domain/agent_workflow.dart';
import 'package:chatgpt_app_core/db/agent_workflow_dao.dart';
import 'package:chatgpt_app_core/db/agent_workspace_dao.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/assistant_memory_dao.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/message_dao.dart';
import 'package:chatgpt_app_core/db/personal_memory_dao.dart';
import 'package:chatgpt_app_core/model/ai_provider.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/assistant_memory_model.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'agent_workflow_foundation_test.dart' show FakeWorkflowBackground;
import 'support/personal_memory_test_support.dart';

// 实际HTTP仅回环；真实DAO、配置wrapper、ToolLoop与单次网络attempt共同闭环。
void main() {
  final evidence = <Object?>[];
  for (final backend in [false, true]) {
    for (final budget in [8, 5]) {
      test('${backend ? 'Backend' : 'Direct'} 独立三节点真实POST/工具验收与父预算$budget',
          () async {
        LoginDao.resetHooksForTest();
        PersonalMemoryTestAccount('a').install();
        sqfliteFfiInit();
        final storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
            inMemoryDatabasePath,
            options: OpenDatabaseOptions(singleInstance: false)));
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final oldHost = BackendConfig.host, oldHttps = BackendConfig.useHttps;
        BackendConfig.host = '${server.address.host}:${server.port}';
        BackendConfig.useHttps = false;
        addTearDown(() async {
          await server.close(force: true);
          await storage.db.close();
          BackendConfig.host = oldHost;
          BackendConfig.useHttps = oldHttps;
          LoginSdkConfig.reset();
        });
        ModelCatalog.applyRemote({
          'models': [
            for (final r in WorkflowRole.values)
              {
                'modelId': 'gpt-4o-${r.name}',
                'providerCode': 'openai',
                'displayName': '合成${r.name}',
                'supportsTool': true
              }
          ]
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
                  for (final r in WorkflowRole.values)
                    AiModel(id: 'gpt-4o-${r.name}')
                ])
          ]
          ..activeProviderId = 'fixture';
        settings.setActiveModel('gpt-4o-analysis');
        final assistantId = (await (await AssistantDao.create(storage))
            .saveAssistant(AssistantModel(
                name: '合成角色',
                prompt: 'ASSISTANT_PROMPT_SENTINEL',
                description: 'TAVERN_METADATA_SENTINEL')))!;
        await (await AssistantMemoryDao.create(storage)).saveMemory(
            AssistantMemoryModel(
                assistantId: assistantId,
                content: 'ASSISTANT_MEMORY_SENTINEL',
                confirmedByUser: true));
        final memories =
            await PersonalMemoryDao.create(storage, accountHash: 'a');
        await memories.save('PERSONAL_MEMORY_SENTINEL');
        final prefs = await memories.preferences();
        await memories.setPreferences(
            revision: prefs.revision, enabled: true, suggestionsEnabled: false);
        await (await ConversationListDao.create(storage)).saveConversation(
            ConversationModel(
                cid: 1, title: '合成', icon: '', assistantId: assistantId));
        final userId = await (await MessageDao.create(storage, cid: 1))
            .saveMessageWithBlocks(MessageModel(
                content: '本次合成任务', ownerType: OwnerType.sender, createdAt: 10));
        final files = await AgentWorkspaceDao.create(storage, cid: 1);
        final input = await files.saveInput(
            name: 'input.txt',
            sourceKey: 'synthetic',
            contentHash: workflowHash('SELECTED_BODY'),
            content: 'SELECTED_BODY',
            pageTexts: [],
            sizeBytes: 13);
        await files.saveInput(
            name: 'private.txt',
            sourceKey: 'private',
            contentHash: workflowHash('PRIVATE_BODY_SENTINEL'),
            content: 'PRIVATE_BODY_SENTINEL',
            pageTexts: [],
            sizeBytes: 20);
        final posts = <Map<String, dynamic>>[];
        server.listen((request) async {
          final body =
              (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                  .cast<String, dynamic>();
          posts.add(body);
          final messages = body['messages'] as List;
          final read = messages.any((m) => m['role'] == 'tool');
          request.response.headers.contentType =
              ContentType('text', 'event-stream', charset: 'utf-8');
          final delta = read
              ? {
                  'content': (body['model'] as String).endsWith('review')
                      ? '{"decision":"accept","feedback":"仅模型意见"}'
                      : '${body['model']}-result'
                }
              : {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_${posts.length}',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': jsonEncode({'file_id': input.id})
                      }
                    }
                  ]
                };
          request.response.write('data: ${jsonEncode({
                'choices': [
                  {'delta': delta}
                ],
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
              })}\n\ndata: [DONE]\n\n');
          await request.response.close();
        });
        final scope = AgentWorkflowScope(accountHash: 'a');
        final dao = await AgentWorkflowDao.create(storage, accountHash: 'a');
        final w = await dao.createFromSource(scope,
            cid: 1,
            userRowId: userId,
            profiles: {
              for (final r in WorkflowRole.values)
                r: WorkflowModelProfile(backend ? 'backend' : 'local',
                    backend ? 'backend' : 'fixture', 'gpt-4o-${r.name}')
            },
            inputFileIds: [input.id],
            grantedTools: {'read_file'},
            budget: WorkflowBudget(maxDispatches: budget));
        final workspace = await AgentWorkspaceTools.create(storage,
            cid: 1,
            workspace: await AgentWorkspaceService.create(storage, cid: 1));
        final models =
            AgentWorkflowModels(scope, settings: () async => settings.clone());
        final native = FakeWorkflowBackground();
        final runner = AgentWorkflowRunner(
            dao: dao,
            scope: scope,
            workflow: w,
            serviceForProfile: models.service,
            profileAvailable: models.available,
            workspaceTools: workspace,
            backgroundEnabled: false,
            foreground: () => true,
            background: native,
            channel: AgentExecutionChannel());
        await runner.start().timeout(const Duration(seconds: 15));
        expect(posts.length, budget == 8 ? 6 : 5);
        expect(runner.workflow.dispatches, posts.length);
        expect(
            runner.workflow.state,
            budget == 8
                ? WorkflowState.complete
                : WorkflowState.budgetExhausted);
        expect(posts.map((p) => p['model']), [
          'gpt-4o-analysis',
          'gpt-4o-analysis',
          'gpt-4o-writing',
          'gpt-4o-writing',
          'gpt-4o-review',
          if (budget == 8) 'gpt-4o-review'
        ]);
        expect(posts.every((p) => p['max_tokens'] == 2048), true);
        final raw = jsonEncode(posts);
        for (final secret in [
          'PERSONAL_MEMORY_SENTINEL',
          'ASSISTANT_MEMORY_SENTINEL',
          'ASSISTANT_PROMPT_SENTINEL',
          'TAVERN_METADATA_SENTINEL',
          'PRIVATE_BODY_SENTINEL'
        ]) {
          expect(raw, isNot(contains(secret)));
        }
        expect(raw, contains('SELECTED_BODY'));
        expect((await workspace.store.readIntervals(1, 10, input.id, 1)).length,
            3);
        expect(native.started, isEmpty);
        expect(native.stopped, 0);
        if (budget == 8) {
          expect(runner.workflow.verification!['isPassed'], true);
          await dao.publishReplyOnce(scope, w.id, runner.workflow.revision,
              createdAt: 20);
        }
        evidence.add({
          'mode': backend ? 'backend' : 'direct',
          'limit': budget,
          'dispatches': runner.workflow.dispatches,
          'state': runner.workflow.state.name,
          'posts': posts,
          'attempts': await dao.attemptHistory(w.id)
        });
      });
    }
  }
  tearDownAll(() async {
    const path = String.fromEnvironment('CHATAI_WORKFLOW_HTTP_EVIDENCE');
    if (path.isNotEmpty) await File(path).writeAsString(jsonEncode(evidence));
  });
}
