import 'dart:convert';

import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client_pool.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_tool_source.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:chatgpt_app_core/db/hi_db_manager.dart';
import 'package:chatgpt_app_core/db/tool_audit_dao.dart';
import 'package:chatgpt_app_core/model/ai_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 一个最小的 MCP server 模拟器：按 JSON-RPC method 分派，可选 SSE 输出。
/// 记录收到的 tools/call 参数供断言。
class _FakeMcpServer {
  final bool sse;
  final bool resources;
  final bool prompts;
  Map<String, dynamic>? lastCallArgs;
  int initCount = 0;

  _FakeMcpServer(
      {this.sse = false, this.resources = false, this.prompts = false});

  http.Client client() => MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final method = body['method'] as String;
        final id = body['id'];

        // 通知（无 id）：notifications/initialized 等，回 202 空体。
        if (id == null) return http.Response('', 202);

        Map<String, dynamic> result;
        switch (method) {
          case 'initialize':
            initCount++;
            result = {
              'protocolVersion': '2025-06-18',
              'capabilities': {
                'tools': <String, dynamic>{},
                if (resources) 'resources': <String, dynamic>{},
                if (prompts) 'prompts': <String, dynamic>{},
              },
              'serverInfo': {'name': 'fake', 'version': '1.0.0'},
            };
            return _reply(id, result, headers: {'mcp-session-id': 'sess-1'});
          case 'resources/list':
            return _reply(id, {
              'resources': [
                {'uri': 'file:///a.txt', 'name': 'A', 'mimeType': 'text/plain'},
              ],
            });
          case 'resources/read':
            return _reply(id, {
              'contents': [
                {'uri': 'file:///a.txt', 'text': 'resource-body'},
              ],
            });
          case 'prompts/list':
            return _reply(id, {
              'prompts': [
                {'name': 'greet', 'description': '打招呼'},
              ],
            });
          case 'prompts/get':
            return _reply(id, {
              'messages': [
                {
                  'role': 'user',
                  'content': {'type': 'text', 'text': 'hello there'},
                },
              ],
            });
          case 'tools/list':
            result = {
              'tools': [
                {
                  'name': 'echo',
                  'description': '回声',
                  'inputSchema': {
                    'type': 'object',
                    'properties': {
                      'text': {'type': 'string'}
                    },
                    'required': ['text'],
                  },
                },
              ],
            };
            return _reply(id, result);
          case 'tools/call':
            lastCallArgs =
                (body['params'] as Map)['arguments'] as Map<String, dynamic>;
            result = {
              'content': [
                {'type': 'text', 'text': 'pong:${lastCallArgs!['text']}'},
              ],
            };
            return _reply(id, result);
          default:
            return _reply(id, <String, dynamic>{});
        }
      });

  http.Response _reply(Object? id, Map<String, dynamic> result,
      {Map<String, String> headers = const {}}) {
    final payload = {'jsonrpc': '2.0', 'id': id, 'result': result};
    // 用 UTF-8 字节构造，避免 http.Response 默认以 Latin1 编码中文正文。
    final body = sse
        ? 'event: message\ndata: ${jsonEncode(payload)}\n\n'
        : jsonEncode(payload);
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {
        'content-type': sse ? 'text/event-stream' : 'application/json',
        ...headers,
      },
    );
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(McpToolSource.clearCache);
  tearDown(McpToolSource.clearCache);

  Future<HiDBManager> newDb() async => HiDBManager.test(
      await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));

  group('AISettings MCP 字段', () {
    test('toJson/fromJson 往返（直连 server + 后端开关）', () {
      final s = AISettings.defaults()
        ..mcpServers = [
          const McpServerConfig(
            id: 'demo',
            name: 'Demo',
            url: 'https://x/mcp',
            headers: {'Authorization': 'Bearer t'},
            trusted: true,
            permission: McpToolPermission.readOnly,
            enabledProjectIds: [7, 9],
          ),
        ]
        ..mcpBackendEnabled = true
        ..mcpBackendTrusted = true;
      final r = AISettings.fromJson(s.toJson());
      expect(r.mcpServers.length, 1);
      expect(r.mcpServers.first.id, 'demo');
      expect(r.mcpServers.first.headers['Authorization'], 'Bearer t');
      expect(r.mcpServers.first.trusted, isTrue);
      expect(r.mcpServers.first.permission, McpToolPermission.readOnly);
      expect(r.mcpServers.first.enabledProjectIds, [7, 9]);
      expect(r.mcpBackendEnabled, isTrue);
      expect(r.mcpBackendTrusted, isTrue);
    });

    test('缺省：无 MCP server、后端关闭、mcpConfigured=false', () {
      final s = AISettings.fromJson({});
      expect(s.mcpServers, isEmpty);
      expect(s.mcpBackendEnabled, isFalse);
      expect(s.mcpConfigured, isFalse);
    });

    test('enabledMcpServers 过滤掉禁用 / 空 URL', () {
      final s = AISettings.defaults()
        ..mcpServers = const [
          McpServerConfig(id: 'a', name: 'A', url: 'https://a/mcp'),
          McpServerConfig(id: 'b', name: 'B', url: '', enabled: true),
          McpServerConfig(id: 'c', name: 'C', url: 'https://c', enabled: false),
        ];
      expect(s.enabledMcpServers.map((e) => e.id), ['a']);
      expect(s.mcpConfigured, isTrue);
    });

    test('McpServerConfig 项目白名单：空白名单通用，非空必须命中 projectId', () {
      const common = McpServerConfig(id: 'a', name: 'A', url: 'https://a');
      const scoped = McpServerConfig(
        id: 'b',
        name: 'B',
        url: 'https://b',
        enabledProjectIds: [7],
      );

      expect(common.isEnabledForProject(null), isTrue);
      expect(common.isEnabledForProject(3), isTrue);
      expect(scoped.isEnabledForProject(null), isFalse);
      expect(scoped.isEnabledForProject(3), isFalse);
      expect(scoped.isEnabledForProject(7), isTrue);
    });
  });

  group('DirectMcpClient', () {
    test('JSON 响应：listTools + callTool', () async {
      final fake = _FakeMcpServer();
      final c = DirectMcpClient(url: 'https://x/mcp', client: fake.client());
      final tools = await c.listTools();
      expect(tools.length, 1);
      expect(tools.first.name, 'echo');
      expect(tools.first.inputSchema['type'], 'object');
      final out = await c.callTool('echo', {'text': 'hi'});
      expect(out, 'pong:hi');
      expect(fake.lastCallArgs, {'text': 'hi'});
    });

    test('SSE 响应：从 event-stream 里取出匹配结果', () async {
      final fake = _FakeMcpServer(sse: true);
      final c = DirectMcpClient(url: 'https://x/mcp', client: fake.client());
      final tools = await c.listTools();
      expect(tools.single.name, 'echo');
      final out = await c.callTool('echo', {'text': 'sse'});
      expect(out, 'pong:sse');
    });

    test('HTTP 错误转 McpException', () async {
      final c = DirectMcpClient(
        url: 'https://x/mcp',
        client: MockClient((_) async => http.Response('nope', 500)),
      );
      expect(() => c.listTools(), throwsA(isA<McpException>()));
    });
  });

  group('McpToolSource 直连发现 + 映射', () {
    AISettings settingsWith({bool trusted = false}) => AISettings.defaults()
      ..mcpServers = [
        McpServerConfig(
            id: 'srv', name: 'Srv', url: 'https://x/mcp', trusted: trusted),
      ];

    test('发现工具：名称加 mcp__<id>__ 前缀、schema 透传', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(),
          confirm: (_, __) async => true, client: fake.client());
      expect(tools.length, 1);
      expect(tools.first.name, 'mcp__srv__echo');
      expect(tools.first.parameters['required'], ['text']);
    });

    test('项目白名单未命中：会话发现不下发该 server 工具', () async {
      final fake = _FakeMcpServer();
      final settings = AISettings.defaults()
        ..mcpServers = const [
          McpServerConfig(
            id: 'srv',
            name: 'Srv',
            url: 'https://x/mcp',
            enabledProjectIds: [7],
          ),
        ];

      final miss = await McpToolSource.discover(settings,
          currentProjectId: 8,
          confirm: (_, __) async => true,
          client: fake.client());
      final hit = await McpToolSource.discover(settings,
          currentProjectId: 7,
          confirm: (_, __) async => true,
          client: fake.client());

      expect(miss, isEmpty);
      expect(hit.map((e) => e.name), ['mcp__srv__echo']);
    });

    test('readOnly 权限：隐藏普通 MCP tools，仅保留资源/提示词只读工具', () async {
      final fake = _FakeMcpServer(resources: true, prompts: true);
      final settings = AISettings.defaults()
        ..mcpServers = const [
          McpServerConfig(
            id: 'srv',
            name: 'Srv',
            url: 'https://x/mcp',
            trusted: true,
            permission: McpToolPermission.readOnly,
          ),
        ];

      final tools = await McpToolSource.discover(settings,
          confirm: (_, __) async => true, client: fake.client());
      final names = tools.map((e) => e.name).toSet();

      expect(names, isNot(contains('mcp__srv__echo')));
      expect(
          names,
          containsAll([
            'mcp__srv__resources_list',
            'mcp__srv__resources_read',
            'mcp__srv__prompts_list',
            'mcp__srv__prompts_get',
          ]));
    });

    test('信任源：免确认直接执行', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(trusted: true),
          confirm: (_, __) async => false, client: fake.client());
      final out = await tools.first.execute({'text': 'go'});
      expect(out.content, 'pong:go');
    });

    test('非信任源：confirm 返回 false 则拒绝、不调用', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(),
          confirm: (_, __) async => false, client: fake.client());
      final out = await tools.first.execute({'text': 'x'});
      expect(out.content, contains('拒绝'));
      expect(fake.lastCallArgs, isNull); // 未真正调用
    });

    test('非信任源：confirm 返回 true 则执行', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(),
          confirm: (_, __) async => true, client: fake.client());
      final out = await tools.first.execute({'text': 'ok'});
      expect(out.content, 'pong:ok');
      expect(fake.lastCallArgs, {'text': 'ok'});
    });

    test('confirm 为 null（无 UI）：一律拒绝', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(),
          confirm: null, client: fake.client());
      final out = await tools.first.execute({'text': 'x'});
      expect(out.content, contains('拒绝'));
    });

    test('审计轨迹记录：执行参数与拒绝状态可追溯', () async {
      McpToolSource.clearAuditTrail();
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(),
          confirm: (_, __) async => true, client: fake.client());

      final out = await tools.first.execute({'text': 'ok', 'count': 1});
      expect(out.content, 'pong:ok');
      expect(McpToolSource.auditTrail, hasLength(1));
      expect(McpToolSource.auditTrail.first.toolName, tools.first.name);
      expect(McpToolSource.auditTrail.first.approved, isTrue);
      expect(McpToolSource.auditTrail.first.argCount, 2);
      expect(McpToolSource.auditTrail.first.sourceServerId, 'srv');

      final denied = await McpToolSource.discover(settingsWith(),
          confirm: (_, __) async => false, client: fake.client());
      final deniedOut = await denied.first.execute({'text': 'x', 'count': 2});
      expect(deniedOut.content, contains('拒绝'));
      expect(McpToolSource.auditTrail, hasLength(2));
      expect(McpToolSource.auditTrail.first.approved, isFalse);
      expect(McpToolSource.auditTrail.first.argCount, 2);
    });

    test('审计轨迹可持久化到 SQLite', () async {
      McpToolSource.clearAuditTrail();
      final storage = await newDb();
      final auditDao = await ToolAuditDao.create(storage);
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(),
          confirm: (_, __) async => true,
          auditDao: auditDao,
          client: fake.client());

      await tools.first.execute({'text': 'persist'});

      final rows = await auditDao.latest();
      expect(rows.single.toolName, tools.first.name);
      expect(rows.single.sourceType, 'mcp');
      expect(rows.single.sourceId, 'srv');
      expect(rows.single.approved, isTrue);
      expect(rows.single.success, isTrue);
      expect(rows.single.argsPreview, contains('persist'));
      expect(rows.single.resultPreview, contains('pong:persist'));
      await storage.db.close();
    });

    test('未配置 MCP：discover 返回空', () async {
      final tools = await McpToolSource.discover(AISettings.defaults());
      expect(tools, isEmpty);
    });

    test('连接池：发现 + 多次调用只握手一次、池内一条连接', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settingsWith(trusted: true),
          confirm: (_, __) async => true, client: fake.client());
      await tools.first.execute({'text': 'a'});
      await tools.first.execute({'text': 'b'});
      expect(fake.initCount, 1); // 仅初始化握手一次，后续复用
      expect(McpClientPool.size, 1);
    });
  });

  group('Resources / Prompts（item 7）', () {
    AISettings settings() => AISettings.defaults()
      ..mcpServers = [
        const McpServerConfig(
            id: 'srv', name: 'Srv', url: 'https://x/mcp', trusted: true),
      ];

    test('无能力声明：不暴露资源 / 提示词合成工具', () async {
      final fake = _FakeMcpServer();
      final tools = await McpToolSource.discover(settings(),
          confirm: (_, __) async => true, client: fake.client());
      final names = tools.map((t) => t.name);
      expect(names, ['mcp__srv__echo']);
    });

    test('声明 resources + prompts：暴露 4 个合成工具', () async {
      final fake = _FakeMcpServer(resources: true, prompts: true);
      final tools = await McpToolSource.discover(settings(),
          confirm: (_, __) async => true, client: fake.client());
      final names = tools.map((t) => t.name).toSet();
      expect(
          names,
          containsAll([
            'mcp__srv__resources_list',
            'mcp__srv__resources_read',
            'mcp__srv__prompts_list',
            'mcp__srv__prompts_get',
          ]));
    });

    test('resources_read / prompts_get 执行返回文本', () async {
      final fake = _FakeMcpServer(resources: true, prompts: true);
      final tools = await McpToolSource.discover(settings(),
          confirm: (_, __) async => true, client: fake.client());
      ChatToolFinder find(String n) => ChatToolFinder(tools, n);

      final read = await find('mcp__srv__resources_read')
          .tool
          .execute({'uri': 'file:///a.txt'});
      expect(read.content, 'resource-body');

      final got =
          await find('mcp__srv__prompts_get').tool.execute({'name': 'greet'});
      expect(got.content, contains('hello there'));
    });
  });

  group('助手绑定（item 5）', () {
    AISettings settings() => AISettings.defaults()
      ..mcpServers = [
        const McpServerConfig(id: 'srv', name: 'Srv', url: 'https://x/mcp'),
      ];

    test('listSpecs：返回可绑定的 MCP 工具名 + 描述', () async {
      final fake = _FakeMcpServer(resources: true);
      final specs =
          await McpToolSource.listSpecs(settings(), client: fake.client());
      final names = specs.map((e) => e.name).toSet();
      expect(
          names,
          containsAll([
            'mcp__srv__echo',
            'mcp__srv__resources_list',
            'mcp__srv__resources_read',
          ]));
      expect(specs.firstWhere((e) => e.name == 'mcp__srv__echo').description,
          contains('回声'));
    });

    test('listSpecs：返回元信息字段（来源 + trust + readOnly）', () async {
      final fake = _FakeMcpServer();
      final settings = AISettings.defaults()
        ..mcpServers = [
          const McpServerConfig(
              id: 'srv', name: 'Srv', url: 'https://x/mcp', trusted: true),
        ];
      final specs =
          await McpToolSource.listSpecs(settings, client: fake.client());

      final echo = specs.firstWhere((e) => e.name == 'mcp__srv__echo');
      expect(echo.sourceServerId, 'srv');
      expect(echo.sourceServerName, 'Srv');
      expect(echo.trusted, isTrue);
      expect(echo.readOnly, isFalse);
      expect(echo.enabledProjects, isEmpty);
    });

    test('listSpecs：绑定面保留项目白名单工具，由会话运行时按项目过滤', () async {
      final fake = _FakeMcpServer();
      final settings = AISettings.defaults()
        ..mcpServers = [
          const McpServerConfig(
            id: 'srv',
            name: 'Srv',
            url: 'https://x/mcp',
            enabledProjectIds: [7],
          ),
        ];

      final specs =
          await McpToolSource.listSpecs(settings, client: fake.client());

      final echo = specs.firstWhere((e) => e.name == 'mcp__srv__echo');
      expect(echo.enabledProjects, ['7']);
    });

    test('按 toolIds 过滤：只保留勾选的 MCP 工具（与会话页一致）', () async {
      final fake = _FakeMcpServer(resources: true);
      final all = await McpToolSource.discover(settings(),
          confirm: (_, __) async => true, client: fake.client());
      const bound = {'mcp__srv__echo'};
      final filtered = all.where((t) => bound.contains(t.name)).toList();
      expect(filtered.map((t) => t.name), ['mcp__srv__echo']);
    });
  });
}

/// 小工具：从工具列表里按名取出某个 ChatTool（测试可读性）。
class ChatToolFinder {
  final dynamic tool;
  ChatToolFinder(List tools, String name)
      : tool = tools.firstWhere((t) => t.name == name);
}
