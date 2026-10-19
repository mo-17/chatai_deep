import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_app_core/backup/backup_service.dart';
import 'package:chatgpt_app_core/chat/application/story_backend_generation_snapshot.dart';
import 'package:chatgpt_app_core/chat/application/story_room_tool_runner.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/chat/domain/backend_selection.dart';
import 'package:chatgpt_app_core/db/assistant_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/model/assistant_model.dart';
import 'package:chatgpt_app_core/model/story_room_model.dart';
import 'package:chatgpt_app_core/util/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backend_pair_transport_test.dart' show PairTokens;
import 'support/story_p2_gate_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HiDBManager storage;
  late StoryP2Gate gate;
  late PairTokens tokens;
  late String oldHost;
  late bool oldHttps;
  final runs = <StoryBackendGenerationSnapshot>[];
  final cleanups = <Map<String, Object?>>[];
  int serial = 0, completions = 0, toolCalls = 0;
  String toolName = 'mcp__srv__write';
  late AISettings settings;
  late Completer<void> confirmed, releaseConfirm;
  late StoryBackendGenerationSnapshot run;
  setUpAll(() {
    sqfliteFfiInit();
    root = Directory(Platform.environment['R3B3B_ROOT']!);
    expect(root.path,
        '/tmp/chatai-r3b3b-owned-${Platform.environment['R3B3B_NONCE']}');
    expect(
        jsonDecode(
            File('${root.path}/fixture-sentinel.json').readAsStringSync()),
        {'nonce': Platform.environment['R3B3B_NONCE']});
  });
  setUp(() async {
    gate = StoryP2Gate();
    storage = HiDBManager.test(StoryP2Database(
        await databaseFactoryFfi.openDatabase(
            '${root.path}/case-${serial++}.sqlite',
            options: OpenDatabaseOptions(singleInstance: false)),
        gate));
    tokens = PairTokens();
    LoginDao.resetHooksForTest();
    LoginSdkConfig.install(LoginSdkConfig(
        baseUrl: 'story.synthetic.invalid',
        headerProvider: () async => {},
        syncHeaders: () => {},
        routes: LoginRoutes.imooc,
        responseAdapter: ImoocResponseAdapter(),
        storage: tokens,
        onLogoutNavigate: () {}));
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    BackendConfig.host = 'story.synthetic.invalid';
    BackendConfig.useHttps = true;
    ModelCatalog.resetExecutionForTest();
    completions = toolCalls = 0;
    confirmed = Completer();
    releaseConfirm = Completer();
    toolName = 'mcp__srv__write';
    settings = AISettings.defaults()
      ..mode = AIMode.backend
      ..backendSelection = BackendSelection.pair(
          providerCode: 'P',
          modelId: 'gpt-4o-mini',
          accountHash: 'account-a',
          origin: 'https://story.synthetic.invalid')
      ..mcpServers = [
        const McpServerConfig(
            id: 'srv',
            name: 'SYNTHETIC',
            url: 'https://mcp.synthetic.invalid/rpc')
      ];
  });
  tearDown(() async {
    if (!releaseConfirm.isCompleted) releaseConfirm.complete();
    if (!gate.ddlRelease.isCompleted) gate.ddlRelease.complete();
    for (final r in runs) {
      r.retire();
    }
    runs.clear();
    await storage.db.close();
    expect(storage.db.isOpen, isFalse);
    cleanups.add({
      'sqliteClosed': true,
      'completions': completions,
      'toolCalls': toolCalls
    });
    LoginSdkConfig.reset();
    LoginDao.resetHooksForTest();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    ModelCatalog.resetExecutionForTest();
  });
  tearDownAll(() => File('${root.path}/cleanup.json').writeAsStringSync(
          jsonEncode({
        'cases': cleanups,
        'allClosed': true,
        'network': 'injected MCP/model HTTP only'
      })));
  Future<Object?> observe(Future<Object?> value) async {
    try {
      return await value;
    } catch (e) {
      return e;
    }
  }

  Future<void> mocked(Future<void> Function() action) => http.runWithClient(
      action,
      () => MockClient((request) async {
            if (request.url.host == 'mcp.synthetic.invalid') {
              final j = jsonDecode(request.body) as Map;
              if (j['method'] == 'notifications/initialized') {
                return http.Response('', 204);
              }
              if (j['method'] == 'tools/call') toolCalls++;
              final result = j['method'] == 'initialize'
                  ? {'capabilities': {}}
                  : j['method'] == 'tools/list'
                      ? {
                          'tools': [
                            {
                              'name': 'write',
                              'inputSchema': {'type': 'object'},
                              'annotations': {'readOnlyHint': false}
                            }
                          ]
                        }
                      : {
                          'content': [
                            {'type': 'text', 'text': 'SYNTHETIC'}
                          ]
                        };
              return http.Response(
                  jsonEncode(
                      {'jsonrpc': '2.0', 'id': j['id'], 'result': result}),
                  200);
            }
            expect(request.url.host, 'story.synthetic.invalid');
            expect(request.url.path, '/uapi/chat/completions/stream');
            completions++;
            final data = jsonDecode(request.body) as Map;
            final first =
                !(data['messages'] as List).any((m) => m['role'] == 'tool');
            final delta = first
                ? {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 't1',
                        'type': 'function',
                        'function': {
                          'name': toolName,
                          'arguments': toolName == 'save_favorite'
                              ? '{"content":"SYNTHETIC"}'
                              : '{}'
                        }
                      }
                    ]
                  }
                : {'content': 'SYNTHETIC'};
            return http.Response(
                'data: ${jsonEncode({
                      'choices': [
                        {'delta': delta}
                      ]
                    })}\n\ndata: [DONE]\n\n',
                200,
                headers: {'content-type': 'text/event-stream'});
          }));
  Future<Object?> execute({bool waitConfirm = true}) async {
    final dao = await AssistantDao.create(storage);
    final id = await dao.saveAssistant(AssistantModel(
        name: 'SYNTHETIC',
        prompt: 'SYNTHETIC',
        useTools: true,
        toolIds: [toolName]));
    final p = StoryParticipantModel(
        id: 1,
        roomId: 1,
        participantKey: 'P',
        role: 'assistant',
        name: 'P',
        assistantId: id,
        backendSelection: settings.backendSelection);
    run = StoryBackendGenerationSnapshot(
        global: settings,
        room: StoryRoomModel(
            title: 'S', backendSelection: BackendSelection.follow()),
        participants: [p],
        isCurrent: () => true);
    runs.add(run);
    final prepared = await run.prepareParticipant(p);
    return observe(StoryRoomToolRunner(openStorage: () async => storage)
        .runPrepared(
            prepared: prepared,
            speakerAssistantId: id,
            history: [],
            prompt: 'SYNTHETIC',
            confirm: (_, __) async {
              if (!confirmed.isCompleted) confirmed.complete();
              if (waitConfirm) await releaseConfirm.future;
              return true;
            })
        .toList());
  }

  for (final kind in ['account', 'origin', 'retire', 'revision']) {
    test(
        'review MCP confirmation $kind invalidates before actual tool POST',
        () async => mocked(() async {
              final result = execute();
              await confirmed.future;
              if (kind == 'account') tokens.account = 'account-b';
              if (kind == 'origin') {
                BackendConfig.host = 'other.synthetic.invalid';
              }
              if (kind == 'retire') run.retire();
              if (kind == 'revision') BackupService.agentExecutionRevision++;
              releaseConfirm.complete();
              await result;
              expect(toolCalls, 0);
              expect(completions, 1);
            }));
  }
  for (final kind in ['origin', 'revision']) {
    test(
        'review builtin actual DAO wait $kind invalidates before favorite insert',
        () async => mocked(() async {
              toolName = 'save_favorite';
              gate.holdFavoriteDdl = true;
              final result = execute(waitConfirm: false);
              await gate.ddlEntered.future;
              if (kind == 'origin') {
                BackendConfig.host = 'other.synthetic.invalid';
              } else {
                BackupService.agentExecutionRevision++;
              }
              gate.ddlRelease.complete();
              await result;
              final rows = await storage.db.query('tb_favorite');
              expect(rows, isEmpty);
              expect(completions, 1);
            }));
  }
  test(
      'review same original scope MCP and builtin writes still execute exactly once',
      () async => mocked(() async {
            final mcp = execute(waitConfirm: false);
            await mcp;
            expect(toolCalls, 1);
            expect(completions, 2);
            toolName = 'save_favorite';
            completions = 0;
            await execute(waitConfirm: false);
            expect((await storage.db.query('tb_favorite')).length, 1);
            expect(completions, 2);
          }));
}
