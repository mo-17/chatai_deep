import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_message/models/message_model.dart';
import 'package:chatgpt_app_core/chat/application/builtin_tools.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_profile.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_scope.dart';
import 'package:chatgpt_app_core/chat/application/conversation_generation_service.dart';
import 'package:chatgpt_app_core/chat/application/conversation_run_tools.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_execution_session.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_backend_client.dart';
import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';
import 'package:chatgpt_app_core/chat/application/tool_registry.dart';
import 'package:chatgpt_app_core/chat/domain/chat_attachments.dart';
import 'package:chatgpt_app_core/chat/domain/chat_request_options.dart';
import 'package:chatgpt_app_core/chat/domain/model_capabilities.dart';
import 'package:chatgpt_app_core/chat/domain/stream_event.dart';
import 'package:chatgpt_app_core/dao/chat/chat_service.dart';
import 'package:chatgpt_app_core/db/conversation_dao.dart';
import 'package:chatgpt_app_core/db/conversation_generation_dao.dart';
import 'package:chatgpt_app_core/db/favorite_dao.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:chatgpt_app_core/dao/ai_settings_dao.dart';
import 'package:flutter_hi_cache/flutter_hi_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:login_sdk/dao/backend_host.dart';
import 'package:chatgpt_app_core/model/conversation_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:login_sdk/dao/login_dao.dart';
import 'package:login_sdk/login_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conversation_generation_test.dart' as support;

class _Chat
    implements
        ChatService,
        AttemptAwareChatService,
        OptionsAwareChatService,
        OptionsAwareNonStreamingChatService {
  int requests = 0;
  final release = Completer<void>();
  @override
  ModelCapabilities get capabilities => const ModelCapabilities(tool: true);
  @override
  Stream<StreamEvent> chatStreamEventsWithOptions(
      {required String prompt,
      required List<Map<String, dynamic>> history,
      ChatAttachments? attachments,
      List<Map<String, dynamic>>? tools,
      List<Map<String, dynamic>> extraMessages = const [],
      required ChatRequestOptions options}) async* {
    await options.resolveAttemptMessages([
      ...history,
      {'role': 'user', 'content': prompt}
    ]);
    requests++;
    await Future.any([release.future, options.abortTrigger!]);
    yield StreamEvent.text('synthetic final');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackedClient extends http.BaseClient {
  final http.Client delegate;
  int closes = 0;
  _TrackedClient(this.delegate);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      delegate.send(request);
  @override
  void close() {
    closes++;
    delegate.close();
  }
}

class _BlockingToolSecretStore implements SecureKeyValueStore {
  final values = <String, String>{};
  Completer<void>? _started, _gate;
  bool failWrites = false;
  ({Future<void> started, void Function() release}) blockNextWrite() {
    final started = _started = Completer<void>();
    final gate = _gate = Completer<void>();
    return (
      started: started.future,
      release: () {
        if (!gate.isCompleted) gate.complete();
      }
    );
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<void> write(String key, String value) async {
    final started = _started, gate = _gate;
    _started = null;
    _gate = null;
    started?.complete();
    if (gate != null) await gate.future.timeout(const Duration(seconds: 5));
    if (failWrites) throw StateError('synthetic secure write failed');
    values[key] = value;
  }
}

class _Prep implements ConversationTurnPreparation {
  final ConversationRunTools tools;
  ToolRegistry? registry;
  _Prep(this.tools);
  @override
  Future<PreparedConversationTurn> prepare(
      ConversationGenerationRun run) async {
    registry = await tools.create(run);
    return PreparedConversationTurn(
        prompt: run.input.user.content, tools: registry);
  }

  @override
  Future<void> release() async => tools.release();
}

class _ProbeScope extends ToolExecutionScope {
  final ConversationGenerationRun run;
  Future<void> Function()? next;
  _ProbeScope(this.run);
  @override
  Future<void> get abortTrigger => run.abortTrigger;
  @override
  void verify() => run.verify();
  @override
  Future<void> beforeRequest() async {
    await run.guard();
    await next?.call();
    verify();
  }

  @override
  Future<T> commit<T>(Future<T> Function(Transaction tx) action) =>
      run.commitTool(action);
}

Future<void> until(bool Function() value) => support.waitGeneration(value);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  tearDownAll(() => HttpOverrides.global = originalOverrides);
  late HiDBManager storage;
  late ConversationGenerationDao dao;
  late ConversationGenerationService service;
  late AISettings settings;
  late _Chat chat;
  late int rowId;
  late String oldHost;
  late bool oldHttps;
  final evidence = <Map<String, Object?>>[];
  tearDownAll(() async {
    final path = Platform.environment['CHATAI_CONTINUITY_L2B_EVIDENCE_PATH'];
    if (path != null) {
      await File(path).writeAsString(jsonEncode(evidence));
    }
  });
  final serverResponses = <Completer<void>>[];
  final clients = <dynamic>[];
  HttpServer? server;
  setUp(() async {
    LoginDao.resetHooksForTest();
    support.GenerationTestAuth().install();
    oldHost = BackendConfig.host;
    oldHttps = BackendConfig.useHttps;
    SharedPreferences.setMockInitialValues({});
    await HiCache.preInit();
    AISettingsDao.resetSecureStateForTest();
    sqfliteFfiInit();
    storage = HiDBManager.test(await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false)));
    rowId = (await (await ConversationListDao.create(storage)).saveConversation(
        ConversationModel(cid: 1, title: 'synthetic', icon: '', toolIds: [])))!;
    dao = await ConversationGenerationDao.create(storage);
    await FavoriteDao.create(storage);
    settings = support.generationSettings();
    chat = _Chat();
    service = ConversationGenerationService(
        createChat: (_) => chat, createMemory: (_) async => null);
  });
  tearDown(() async {
    for (final gate in serverResponses) {
      if (!gate.isCompleted) gate.complete();
    }
    serverResponses.clear();
    for (final run in service.runs.where((r) => r.busy)) {
      await run.retire('test cleanup').timeout(const Duration(seconds: 3));
    }
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    await server?.close(force: true);
    server = null;
    service.dispose();
    BackendConfig.host = oldHost;
    BackendConfig.useHttps = oldHttps;
    AISettingsDao.resetSecureStateForTest();
    await storage.db.close();
    LoginDao.resetHooksForTest();
    LoginSdkConfig.reset();
  });
  ConversationGenerationRun start(
          {ConversationTurnPreparation? prep,
          int cid = 1,
          int? id,
          bool useSettingsDao = false,
          AISettings? Function()? visibleSettings,
          Future<AISettings> Function()? loadSettings}) =>
      service.start(
          scope: ConversationGenerationScope(account: 'a'),
          dao: dao,
          profile: ConversationGenerationProfile(settings, 'a',
              loadSettings: useSettingsDao
                  ? null
                  : loadSettings ?? (() async => settings),
              visibleSettings: visibleSettings),
          input: ConversationGenerationInput(
              cid: cid,
              conversationRowId: id ?? rowId,
              user: MessageModel(
                  ownerType: OwnerType.sender,
                  content: 'task$cid',
                  createdAt: cid * 10)),
          preparation: prep ??
              ReadyConversationTurn(
                  PreparedConversationTurn(prompt: 'task$cid')));
  Future<String> endpoint(void Function(HttpRequest) onRequest) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen(onRequest);
    return 'http://127.0.0.1:${server!.port}/';
  }

  Future<void> respond(HttpRequest r, Object data) async {
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(data));
    await r.response.close();
  }

  test(
      'confirmation belongs to exact visible host and stays pending after route detach',
      () async {
    final run = start();
    await until(() => chat.requests == 1);
    final oldHost = Object(), other = Object(), reopened = Object();
    run.attachVisibleHost(oldHost);
    final result = run.confirm('title', 'detail');
    await until(() => run.confirmation != null);
    final id = run.confirmation!.id;
    run.detachVisibleHost(oldHost);
    expect(
        await run.answerConfirmation(
            host: oldHost, confirmationId: id, accepted: true),
        false);
    expect(
        await run.answerConfirmation(
            host: other, confirmationId: id, accepted: true),
        false);
    expect(run.confirmation!.id, id);
    run.attachVisibleHost(reopened);
    expect(
        await run.answerConfirmation(
            host: reopened, confirmationId: id, accepted: true),
        true);
    expect(await result, true);
    expect(chat.requests, 1);
    await run.stop('test stop');
  });
  for (final kind in ['favorite', 'conversation', 'stick']) {
    test(
        'final transaction rejects $kind after confirmation and held storage/source edit',
        () async {
      final run = start();
      await until(() => chat.requests == 1);
      final scope = _ProbeScope(run), gate = Completer<void>();
      final entered = Completer<void>();
      final ctx = ToolActionContext(
          executionScope: scope,
          confirm: (_, __) async => true,
          openStorage: () async {
            entered.complete();
            await gate.future;
            return storage;
          });
      final tool = kind == 'favorite'
          ? BuiltinTools.saveFavorite(ctx)
          : kind == 'conversation'
              ? BuiltinTools.createConversation(ctx)
              : BuiltinTools.stickConversation(ctx);
      final future = tool.execute({
        'content': 'new favorite',
        'title': 'new title',
        'cid': 1,
        'stick': true
      });
      final checked =
          expectLater(future, throwsA(isA<ConversationGenerationStale>()));
      await entered.future.timeout(const Duration(seconds: 3));
      await storage.db.update('tb_messages', {'content': 'edited'},
          where: 'id=?', whereArgs: [run.record!.userRowId]);
      gate.complete();
      await checked.timeout(const Duration(seconds: 3));
      expect(await storage.db.query('tb_favorite'), isEmpty);
      final conversations = await storage.db.query('tb_conversation_list');
      expect(conversations.length, 1);
      expect(conversations.single['stickTime'], 0);
      expect(chat.requests, 1);
      await run.stop('stale stop');
    });
  }
  test(
      'tool transaction waits account permit then rechecks source before mutation',
      () async {
    final run = start();
    await until(() => chat.requests == 1);
    final held = Completer<void>(), acquired = Completer<void>();
    final lease = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          acquired.complete();
          await held.future;
        });
    await acquired.future;
    final write =
        run.commitTool((tx) => tx.insert('tb_favorite', {'content': 'late'}));
    final checked =
        expectLater(write, throwsA(isA<ConversationGenerationStale>()));
    await storage.db.update('tb_messages', {'blocks': '[{"type":"changed"}]'},
        where: 'id=?', whereArgs: [run.record!.userRowId]);
    held.complete();
    await lease;
    await checked.timeout(const Duration(seconds: 3));
    expect(await storage.db.query('tb_favorite'), isEmpty);
    await run.stop('stale');
  });
  test(
      'tool choice withdrawn while waiting account permit rejects final local mutation',
      () async {
    final prep = _Prep(ConversationRunTools(toolIds: []));
    final run = start(prep: prep);
    await until(() => chat.requests == 1);
    final held = Completer<void>(), acquired = Completer<void>();
    final lease = LoginDao.runWithStableAccount(
        expectedAccountHash: 'a',
        action: () async {
          acquired.complete();
          await held.future;
        });
    await acquired.future;
    final write = prep.tools
        .commit((tx) => tx.insert('tb_favorite', {'content': 'late'}));
    final checked =
        expectLater(write, throwsA(isA<ConversationGenerationStale>()));
    await storage.db.update('tb_conversation_list', {'toolIds': '["datetime"]'},
        where: 'cid=?', whereArgs: [1]);
    held.complete();
    await lease;
    await checked.timeout(const Duration(seconds: 3));
    expect(await storage.db.query('tb_favorite'), isEmpty);
    await run.stop('stale');
  });
  for (final backend in [false, true]) {
    test(
        'real ${backend ? 'backend' : 'direct'} MCP held HTTP abort settles without following request',
        () async {
      final held = Completer<void>();
      serverResponses.add(held);
      final arrived = Completer<void>();
      final methods = <String>[];
      final url = await endpoint((r) async {
        methods.add(backend
            ? r.uri.path
            : (jsonDecode(await utf8.decoder.bind(r).join()) as Map)['method']
                as String);
        if (!arrived.isCompleted) arrived.complete();
        await held.future;
        await respond(
            r,
            backend
                ? {
                    'code': 0,
                    'data': {'tools': []}
                  }
                : {
                    'jsonrpc': '2.0',
                    'id': 1,
                    'result': {'capabilities': {}}
                  });
      });
      final run = start();
      await until(() => chat.requests == 1);
      final scope = _ProbeScope(run);
      final future = backend
          ? (() {
              final c = BackendMcpClient(
                  executionScope: scope,
                  baseUri: Uri.parse(url),
                  fixedHeaders: {});
              clients.add(c);
              return c.listTools();
            })()
          : (() {
              final c = DirectMcpClient(url: url, executionScope: scope);
              clients.add(c);
              return c.listTools();
            })();
      final checked = expectLater(future, throwsA(anything));
      await arrived.future.timeout(const Duration(seconds: 3));
      await run.stop('stop MCP').timeout(const Duration(seconds: 2));
      await checked.timeout(const Duration(seconds: 3));
      held.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      evidence.add({
        'case': 'held-${backend ? 'backend' : 'direct'}',
        'observedHttp': methods.toList(),
        'fakeChatRequests': chat.requests,
        'journal': run.record?.state
      });
      expect(methods, backend ? ['/tools'] : ['initialize']);
      expect(chat.requests, 1);
    });
  }
  test(
      'direct MCP checks run again after handshake response before initialized notification',
      () async {
    final methods = <String>[];
    final entered = Completer<void>(), release = Completer<void>();
    final url = await endpoint((r) async {
      final j = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
      methods.add(j['method'] as String);
      await respond(r, {
        'jsonrpc': '2.0',
        'id': j['id'],
        'result': {'capabilities': {}}
      });
    });
    final run = start();
    await until(() => chat.requests == 1);
    final scope = _ProbeScope(run);
    int checks = 0;
    scope.next = () async {
      if (++checks == 2) {
        entered.complete();
        await release.future;
      }
    };
    final c = DirectMcpClient(url: url, executionScope: scope);
    clients.add(c);
    final future = c.listTools();
    final checked = expectLater(future, throwsA(anything));
    await entered.future.timeout(const Duration(seconds: 3));
    await run.stop('stop between RPC');
    release.complete();
    await checked.timeout(const Duration(seconds: 3));
    evidence.add(
        {'case': 'after-handshake-stop', 'observedHttp': methods.toList()});
    expect(methods, ['initialize']);
  });
  test('stop during fetch URL DNS prevents real GET after late resolver',
      () async {
    final run = start();
    await until(() => chat.requests == 1);
    final gate = Completer<List<InternetAddress>>(),
        entered = Completer<void>();
    int gets = 0;
    final client = MockClient((_) async {
      gets++;
      return http.Response('body', 200);
    });
    clients.add(client);
    final pending = BuiltinTools.fetchUrl(
        executionScope: _ProbeScope(run),
        client: client,
        resolver: (_) {
          entered.complete();
          return gate.future;
        }).execute({'url': 'https://example.com'});
    await entered.future.timeout(const Duration(seconds: 3));
    await run.stop('DNS stop');
    gate.complete([InternetAddress('93.184.216.34')]);
    await pending;
    expect(gets, 0);
    expect(chat.requests, 1);
  });
  test(
      'run-owned tool assembly executes confirmed create without treating list refresh as restore',
      () async {
    await storage.db.update(
        'tb_conversation_list', {'toolIds': '["create_conversation"]'},
        where: 'cid=?', whereArgs: [1]);
    final prep = _Prep(
        ConversationRunTools(toolIds: [ToolRegistry.createConversationId]));
    final run = start(prep: prep);
    await until(() => chat.requests == 1);
    final host = Object();
    run.attachVisibleHost(host);
    final created = prep.registry!.tools.single.execute({'title': 'new'});
    await until(() => run.confirmation != null);
    expect(
        await run.answerConfirmation(
            host: host, confirmationId: run.confirmation!.id, accepted: true),
        true);
    expect((await created).content, contains('已新建'));
    expect(await storage.db.query('tb_conversation_list'), hasLength(2));
    expect(run.current, true);
    chat.release.complete();
    await run.finished;
    expect(run.record!.receiverRowId, isNotNull);
    expect(chat.requests, 1);
  });
  Future<Map<String, dynamic>> mcpRequest(
      HttpRequest r, List<String> methods) async {
    final j = (jsonDecode(await utf8.decoder.bind(r).join()) as Map)
        .cast<String, dynamic>();
    methods.add(j['method'] as String);
    return j;
  }

  Future<void> mcpResponse(HttpRequest r, Map j, {String text = 'echo'}) async {
    if (j['method'] == 'notifications/initialized') {
      r.response.statusCode = 204;
      await r.response.close();
      return;
    }
    await respond(r, {
      'jsonrpc': '2.0',
      'id': j['id'],
      'result': j['method'] == 'initialize'
          ? {'capabilities': {}}
          : j['method'] == 'tools/list'
              ? {
                  'tools': [
                    {
                      'name': 'echo',
                      'inputSchema': {'type': 'object'}
                    }
                  ]
                }
              : {
                  'content': [
                    {'type': 'text', 'text': text}
                  ]
                }
    });
  }

  test(
      'two run-owned MCP sessions perform real calls and abort A without cancelling B or writing late audit',
      () async {
    final methods = <String>[], calls = <String>[];
    final held = Completer<void>(), arrived = Completer<void>();
    serverResponses.add(held);
    final url = await endpoint((r) async {
      final j = await mcpRequest(r, methods);
      final text = (j['params'] as Map?)?['arguments']?['text'] as String?;
      if (j['method'] == 'tools/call') {
        calls.add(text!);
        if (text == 'A') {
          arrived.complete();
          await held.future;
        }
      }
      await mcpResponse(r, j, text: 'echo:$text');
    });
    settings.mcpServers = [
      McpServerConfig(id: 's', name: 'synthetic', url: url, trusted: true)
    ];
    final row2 = (await (await ConversationListDao.create(storage))
        .saveConversation(
            ConversationModel(cid: 2, title: 'B', icon: '', toolIds: [])))!;
    final pa = _Prep(ConversationRunTools(toolIds: [])),
        pb = _Prep(ConversationRunTools(toolIds: []));
    final a = start(prep: pa), b = start(prep: pb, cid: 2, id: row2);
    await until(() => chat.requests == 2);
    final callA = pa.registry!.tools.single.execute({'text': 'A'});
    final checked = expectLater(callA, throwsA(anything));
    await arrived.future.timeout(const Duration(seconds: 3));
    final outcome = await pb.registry!.tools.single.execute({'text': 'B'});
    expect(outcome.content, 'echo:B');
    expect(b.current, true);
    await a.stop('stop only A');
    await checked.timeout(const Duration(seconds: 3));
    held.complete();
    expect(b.current, true);
    expect(calls, ['A', 'B']);
    expect(methods.where((m) => m == 'initialize').length, 2);
    final audits = await storage.db.query('tb_tool_audit');
    expect(audits, hasLength(1));
    expect(audits.single['argsPreview'], '{"text":"B"}');
    chat.release.complete();
    await b.finished;
    expect(chat.requests, 2);
    evidence.add({
      'case': 'two-sessions-A-stop-B-complete',
      'observedHttp': methods.toList(),
      'observedToolInputs': calls.toList(),
      'fakeChatRequests': chat.requests,
      'auditRows': audits,
      'aJournal': a.record?.state,
      'bJournal': b.record?.state,
      'bReceiverRowId': b.record?.receiverRowId
    });
    expect(b.record!.receiverRowId, isNotNull);
  });
  test(
      'source changed during last MCP configuration read cannot dispatch tools call',
      () async {
    final methods = <String>[];
    final url = await endpoint((r) async {
      final j = await mcpRequest(r, methods);
      await mcpResponse(r, j);
    });
    settings.mcpServers = [
      McpServerConfig(id: 's', name: 'synthetic', url: url, trusted: true)
    ];
    final prep = _Prep(ConversationRunTools(toolIds: []));
    var armed = false;
    var reads = 0;
    final entered = Completer<void>(), released = Completer<void>();
    final run = start(
        prep: prep,
        loadSettings: () async {
          if (armed && ++reads == 8) {
            entered.complete();
            await released.future;
          }
          return settings;
        });
    await until(() => chat.requests == 1);
    armed = true;
    final call = prep.registry!.tools.single.execute({'text': 'old'});
    final checked = expectLater(call, throwsA(anything));
    await entered.future.timeout(const Duration(seconds: 3));
    // The source UUID/body stay unchanged; only the captured blocks identity changes.
    await storage.db.update('tb_messages', {'blocks': '[{"type":"changed"}]'},
        where: 'id=?', whereArgs: [run.record!.userRowId]);
    released.complete();
    await checked.timeout(const Duration(seconds: 3));
    evidence.add({
      'case': 'source-block-change-during-final-config-read',
      'observedHttp': methods.toList(),
      'toolCallPostCount': 0,
      'auditRows': await storage.db.query('tb_tool_audit')
    });
    expect(methods, ['initialize', 'notifications/initialized', 'tools/list']);
    expect(await storage.db.query('tb_tool_audit'), isEmpty);
    expect(chat.requests, 1);
    await run.stop('source invalidated');
  });
  for (final backend in [false, true]) {
    for (final revocation in [
      'credentials',
      'trust',
      'enabled',
      'tool-selection'
    ]) {
      test(
          'real ${backend ? 'backend' : 'direct'} MCP final guard held then $revocation revoked sends zero call POST',
          () async {
        final observed = <String>[];
        final url = await endpoint((r) async {
          if (backend) {
            observed.add('${r.method} ${r.uri.path}');
            await respond(r, {
              'code': 0,
              'data': {
                'tools': [
                  {
                    'name': 'mcp__s__write',
                    'serverId': 's',
                    'parameters': {'type': 'object'}
                  }
                ],
                'content': 'SHOULD_NOT_SEND'
              }
            });
          } else {
            final j = await mcpRequest(r, observed);
            await mcpResponse(r, j);
          }
        });
        if (backend) {
          BackendConfig.host = Uri.parse(url).authority;
          BackendConfig.useHttps = false;
          settings.mcpBackendEnabled = true;
          settings.mcpBackendTrusted = true;
        }
        settings.mcpServers = backend
            ? []
            : [
                McpServerConfig(
                    id: 's',
                    name: 'synthetic',
                    url: url,
                    trusted: true,
                    headers: {'x-fixture': 'old'})
              ];
        final prep = _Prep(ConversationRunTools(toolIds: []));
        var armed = false, reads = 0;
        final entered = Completer<void>(), released = Completer<void>();
        start(
            prep: prep,
            loadSettings: () async {
              if (armed && ++reads == 9) {
                entered.complete();
                await released.future.timeout(const Duration(seconds: 3));
              }
              return settings;
            });
        await until(() => chat.requests == 1);
        armed = true;
        final call = prep.registry!.tools.single.execute({'text': 'old'});
        final rejected = expectLater(call, throwsA(anything));
        await entered.future.timeout(const Duration(seconds: 3));
        if (revocation == 'tool-selection') {
          await storage.db.update(
              'tb_conversation_list', {'toolIds': '["calculator"]'},
              where: 'id=?', whereArgs: [rowId]);
        } else {
          settings = settings.clone();
          if (backend) {
            if (revocation == 'enabled') {
              settings.mcpBackendEnabled = false;
            } else if (revocation == 'trust') {
              settings.mcpBackendTrusted = false;
            } else {
              await LoginDao.saveAuthToken('rotated-synthetic-token',
                  userName: 'synthetic', extras: {'accountHash': 'a'});
            }
          } else {
            settings.mcpServers = [
              settings.mcpServers.single.copyWith(
                  headers:
                      revocation == 'credentials' ? {'x-fixture': 'new'} : null,
                  trusted: revocation == 'trust' ? false : null,
                  enabled: revocation == 'enabled' ? false : null)
            ];
          }
          await AISettingsDao.saveFor('a', settings);
        }
        released.complete();
        await rejected.timeout(const Duration(seconds: 3));
        evidence.add({
          'case': 'final-guard-$revocation-${backend ? 'backend' : 'direct'}',
          'observedHttp': observed.toList(),
          'toolCallPostCount': observed
              .where((m) => m.contains('tools/call') || m.startsWith('POST '))
              .length,
          'gateSettingsReads': reads,
          'fakeChatRequests': chat.requests
        });
        expect(
            observed.where(
                (m) => m.contains('tools/call') || m.startsWith('POST ')),
            isEmpty);
        expect(await storage.db.query('tb_tool_audit'), isEmpty);
        // No manual stop participates in the assertion: this cleanup happens afterwards.
        expect(chat.requests, 1);
      });
    }
  }
  test('clear authorization cannot be rebound from an old settings snapshot',
      () async {
    await AISettingsDao.saveFor('a', settings);
    final old = settings.clone();
    final clearing = AISettingsDao.clearFor('a');
    AISettingsDao.bindExecutionConfiguration('a', old);
    expect(AISettingsDao.executionConfigurationMatches('a', old), false);
    await clearing;
    AISettingsDao.bindExecutionConfiguration('a', old);
    expect(AISettingsDao.executionConfigurationMatches('a', old), false);
    await AISettingsDao.saveFor('a', old);
    expect(AISettingsDao.executionConfigurationMatches('a', old), true);
  });
  for (final backend in [false, true]) {
    for (final failedSave in [false, true]) {
      test(
          'default DAO ${backend ? 'backend' : 'direct'} pending secure ${failedSave ? 'failure' : 'success'} never rebinds old tool authorization',
          () async {
        final observed = <String>[], callHeaders = <String?>[];
        final url = await endpoint((r) async {
          if (backend) {
            observed.add('${r.method} ${r.uri.path}');
            await respond(r, {
              'code': 0,
              'data': {
                'tools': [
                  {
                    'name': 'mcp__s__write',
                    'serverId': 's',
                    'parameters': {'type': 'object'}
                  }
                ],
                'content': 'synthetic new result'
              }
            });
          } else {
            final j = await mcpRequest(r, observed);
            if (j['method'] == 'tools/call') {
              callHeaders.add(r.headers.value('x-fixture'));
            }
            await mcpResponse(r, j);
          }
        });
        if (backend) {
          BackendConfig.host = Uri.parse(url).authority;
          BackendConfig.useHttps = false;
          settings.mcpBackendEnabled = true;
          settings.mcpBackendTrusted = true;
          settings.mcpServers = [];
        } else {
          settings.mcpServers = [
            McpServerConfig(
                id: 's',
                name: 'synthetic',
                url: url,
                trusted: true,
                headers: {'x-fixture': 'old'})
          ];
        }
        final secure = _BlockingToolSecretStore();
        AISettingsDao.configureSecretStore(secure);
        settings = await AISettingsDao.saveFor('a', settings);
        await AISettingsDao.prepareAccount('a');
        final original = settings.clone();
        final prep = _Prep(ConversationRunTools(toolIds: []));
        start(prep: prep, useSettingsDao: true, visibleSettings: () => null);
        await until(() => chat.requests == 1);
        final latest = original.clone();
        if (backend) {
          latest.mcpBackendTrusted = false;
        } else {
          latest.mcpServers = [
            latest.mcpServers.single.copyWith(headers: {'x-fixture': 'new'})
          ];
        }
        final block = secure.blockNextWrite();
        final save = AISettingsDao.saveFor('a', latest);
        final saved = save.then<Object?>((_) => null,
            onError: (Object e, StackTrace _) => e);
        try {
          await block.started.timeout(const Duration(seconds: 3));
          // 已 prepared 的默认读取仍返回旧 A；不能借它认领目标 B 的新授权代次。
          final cached = await AISettingsDao.loadForAsync('a');
          expect(jsonEncode(cached.toJson()), jsonEncode(original.toJson()));
          final call = prep.registry!.tools.single
              .execute({'text': 'old'}).then<Object?>((_) => null,
                  onError: (Object e, StackTrace _) => e);
          final verifies = Future.wait(List.generate(
              3,
              (_) => prep.tools.verifyConfiguration().then<Object?>((_) => null,
                  onError: (Object e, StackTrace _) => e)));
          final callError = await call.timeout(const Duration(seconds: 3));
          final verifyErrors =
              await verifies.timeout(const Duration(seconds: 3));
          final oldCalls = observed
              .where((m) => backend ? m.startsWith('POST ') : m == 'tools/call')
              .length;
          evidence.add({
            'case':
                'pending-secure-${backend ? 'backend' : 'direct'}-${failedSave ? 'failure' : 'success'}-before-settle',
            'oldToolCallPosts': oldCalls,
            'observedHttp': observed.toList(),
            'cachedOriginal': true,
            'fakeChatRequests': chat.requests,
            'concurrentVerifiesRejected':
                verifyErrors.where((e) => e != null).length
          });
          expect(callError, isA<ConversationGenerationStale>());
          expect(
              verifyErrors, everyElement(isA<ConversationGenerationStale>()));
          expect(oldCalls, 0);
          secure.failWrites = failedSave;
          block.release();
          final saveError = await saved.timeout(const Duration(seconds: 3));
          expect(saveError,
              failedSave ? isA<AISecretsUnavailableException>() : isNull);
          await expectLater(prep.tools.verifyConfiguration(),
              throwsA(isA<ConversationGenerationStale>()));
          await expectLater(
              prep.registry!.tools.single.execute({'text': 'still old'}),
              throwsA(isA<ConversationGenerationStale>()));
          expect(
              observed.where(
                  (m) => backend ? m.startsWith('POST ') : m == 'tools/call'),
              isEmpty);
          // 明确保存当前配置，再开始新运行；不能刷新旧运行授权来恢复。
          secure.failWrites = false;
          if (backend) latest.mcpBackendTrusted = true;
          settings = await AISettingsDao.saveFor('a', latest);
          final secondId = (await (await ConversationListDao.create(storage))
              .saveConversation(ConversationModel(
                  cid: 2, title: 'new explicit', icon: '', toolIds: [])))!;
          final next = _Prep(ConversationRunTools(toolIds: []));
          start(
              prep: next,
              cid: 2,
              id: secondId,
              useSettingsDao: true,
              visibleSettings: () => null);
          await until(() => chat.requests == 2);
          final result = await next.registry!.tools.single
              .execute({'text': 'new'}).timeout(const Duration(seconds: 3));
          expect(result.content, backend ? 'synthetic new result' : 'echo');
          expect(
              observed.where(
                  (m) => backend ? m.startsWith('POST ') : m == 'tools/call'),
              hasLength(1));
          if (!backend) expect(callHeaders, ['new']);
          evidence.add({
            'case':
                'pending-secure-${backend ? 'backend' : 'direct'}-${failedSave ? 'failure' : 'success'}-explicit-new-run',
            'oldToolCallPosts': 0,
            'newToolCallPosts': 1,
            'observedHttp': observed.toList(),
            'fakeChatRequests': chat.requests,
            'saveFailed': saveError != null
          });
        } finally {
          block.release();
          await saved.timeout(const Duration(seconds: 3));
        }
      });
    }
  }
  test(
      'global active model change during final guard preserves original model and unchanged MCP permission',
      () async {
    final methods = <String>[];
    final url = await endpoint((r) async {
      final j = await mcpRequest(r, methods);
      await mcpResponse(r, j);
    });
    settings.mcpServers = [
      McpServerConfig(id: 's', name: 'synthetic', url: url, trusted: true)
    ];
    final prep = _Prep(ConversationRunTools(toolIds: []));
    var armed = false, reads = 0;
    final entered = Completer<void>(), released = Completer<void>();
    final run = start(
        prep: prep,
        loadSettings: () async {
          if (armed && ++reads == 9) {
            entered.complete();
            await released.future;
          }
          return settings;
        });
    await until(() => chat.requests == 1);
    armed = true;
    final call = prep.registry!.tools.single.execute({'text': 'allowed'});
    await entered.future.timeout(const Duration(seconds: 3));
    settings = settings.clone()..setActiveModel('gpt-4o-b');
    await AISettingsDao.saveFor('a', settings);
    released.complete();
    final result = await call.timeout(const Duration(seconds: 3));
    expect(result.content, 'echo');
    expect(methods.where((m) => m == 'tools/call'), hasLength(1));
    expect(run.profile.modelId, 'gpt-4o-a');
    expect(settings.effectiveModel, 'gpt-4o-b');
    expect(run.current, true);
    expect(chat.requests, 1);
    evidence.add({
      'case': 'global-active-model-unchanged-tool-permit',
      'observedHttp': methods.toList(),
      'toolCallPostCount': 1,
      'runModel': run.profile.modelId,
      'activeModel': settings.effectiveModel,
      'fakeChatRequests': chat.requests
    });
  });
  test('MCP credential changed after discovery is refused with zero tool POST',
      () async {
    final methods = <String>[];
    final url = await endpoint((r) async {
      final j = await mcpRequest(r, methods);
      await mcpResponse(r, j);
    });
    settings.mcpServers = [
      McpServerConfig(
          id: 's',
          name: 'synthetic',
          url: url,
          trusted: true,
          headers: {'x-fixture': 'old'})
    ];
    final prep = _Prep(ConversationRunTools(toolIds: []));
    final run = start(prep: prep);
    await until(() => chat.requests == 1);
    settings.mcpServers = [
      settings.mcpServers.single.copyWith(headers: {'x-fixture': 'new'})
    ];
    await expectLater(prep.registry!.tools.single.execute({'text': 'old'}),
        throwsA(isA<ConversationGenerationStale>()));
    evidence.add({
      'case': 'credential-revoked',
      'observedHttp': methods.toList(),
      'toolCallPostCount': 0
    });
    expect(methods, ['initialize', 'notifications/initialized', 'tools/list']);
    expect(await storage.db.query('tb_tool_audit'), isEmpty);
    await run.stop('configuration revoked');
  });
  test(
      'real backend MCP tools call aborts while response held and cannot issue another POST',
      () async {
    final arrived = Completer<void>(), held = Completer<void>();
    serverResponses.add(held);
    final payloads = <Object>[];
    final url = await endpoint((r) async {
      payloads.add(jsonDecode(await utf8.decoder.bind(r).join()));
      arrived.complete();
      await held.future;
      await respond(r, {
        'code': 0,
        'data': {'content': 'late'}
      });
    });
    final run = start();
    await until(() => chat.requests == 1);
    final c = BackendMcpClient(
        executionScope: _ProbeScope(run),
        baseUri: Uri.parse(url),
        fixedHeaders: {'x-fixture': 'only'});
    clients.add(c);
    final call = c.callTool('mcp__synthetic__write', {'text': 'fixture'});
    final checked = expectLater(call, throwsA(anything));
    await arrived.future.timeout(const Duration(seconds: 3));
    await run.stop('backend tool stop');
    await checked.timeout(const Duration(seconds: 3));
    held.complete();
    evidence.add({
      'case': 'backend-tool-call-aborted',
      'observedHttpPayloads': payloads.toList(),
      'journal': run.record?.state,
      'fakeChatRequests': chat.requests
    });
    expect(payloads, [
      {
        'name': 'mcp__synthetic__write',
        'arguments': {'text': 'fixture'}
      }
    ]);
    expect(chat.requests, 1);
  });
  test(
      'session owns factory clients and releases each only once without using global pool',
      () async {
    final run = start();
    await until(() => chat.requests == 1);
    final own = <_TrackedClient>[];
    final session = McpExecutionSession(
        scope: _ProbeScope(run),
        backendBase: Uri.parse('https://fixture.invalid/'),
        backendHeaders: {},
        clientFactory: () {
          final client = _TrackedClient(MockClient((request) async {
            final j =
                request.body.isEmpty ? {} : jsonDecode(request.body) as Map;
            return http.Response(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': j['id'],
                  'result': {'capabilities': {}, 'tools': []},
                  'code': 0,
                  'data': {'tools': []}
                }),
                200);
          }));
          own.add(client);
          return client;
        });
    await session
        .direct(const McpServerConfig(
            id: 'x', name: 'x', url: 'https://fixture.invalid/'))
        .listTools();
    await session.backend().listTools();
    session.close();
    session.close();
    expect(own.map((c) => c.closes).toList(), [1, 1]);
    expect(run.current, true);
    await run.stop('test stop');
  });
  test(
      'known MCP result survives audit DB failure without hidden retry of the real external call',
      () async {
    final methods = <String>[];
    final url = await endpoint((r) async {
      final j = await mcpRequest(r, methods);
      await mcpResponse(r, j, text: 'known-result');
    });
    settings.mcpServers = [
      McpServerConfig(id: 's', name: 'synthetic', url: url, trusted: true)
    ];
    final prep = _Prep(ConversationRunTools(toolIds: []));
    final run = start(prep: prep);
    await until(() => chat.requests == 1);
    await storage.db.execute(
        "create trigger fail_audit before insert on tb_tool_audit begin select raise(abort,'audit disk failure'); end");
    final result =
        await prep.registry!.execute('mcp__s__echo', {'text': 'once'});
    expect(result.content, contains('known-result'));
    expect(result.content, contains('审计未保存'));
    expect(prep.registry!.retryPolicy.enabled, false);
    expect(methods.where((m) => m == 'tools/call').length, 1);
    expect(await storage.db.query('tb_tool_audit'), isEmpty);
    evidence.add({
      'case': 'audit-failure-known-result-no-replay',
      'observedHttp': methods.toList(),
      'returnedResult': result.content,
      'auditRows': [],
      'fakeChatRequests': chat.requests
    });
    await run.stop('test stop');
  });
}
