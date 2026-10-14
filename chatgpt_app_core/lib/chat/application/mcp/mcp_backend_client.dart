import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';

import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/util/hi_const.dart';
import 'package:http/http.dart' as http;
import 'package:login_sdk/dao/header_util.dart';

/// 后端聚合下发的一个工具（名称已由后端加好 mcp__<serverId>__ 前缀）。
class BackendMcpTool {
  final String name;
  final String? description;
  final Map<String, dynamic> parameters;
  final String serverId;

  const BackendMcpTool({
    required this.name,
    required this.parameters,
    required this.serverId,
    this.description,
  });
}

/// 后端 MCP Host 桥接（方案 B）。不走 MCP 协议本身，而是调本项目后端的
/// /uapi/mcp/* 接口（JWT 鉴权经 hiHeaders）。后端再用真正的 MCP 客户端连各
/// server——故移动端经此可间接用上 stdio 型 server。
class BackendMcpClient {
  final ToolExecutionScope? executionScope;
  final Uri? baseUri;
  final Map<String, String>? fixedHeaders;
  final http.Client _client;
  final bool _ownClient;
  final Duration timeout;

  BackendMcpClient(
      {http.Client? client,
      bool closeInjectedClient = false,
      this.executionScope,
      this.baseUri,
      Map<String, String>? fixedHeaders,
      this.timeout = const Duration(seconds: 30)})
      : fixedHeaders =
            fixedHeaders == null ? null : Map.unmodifiable(fixedHeaders),
        _client = client ?? http.Client(),
        _ownClient = client == null || closeInjectedClient;

  void close() {
    if (_ownClient) _client.close();
  }

  Future<http.Response> _request(String method, String path,
      [String? body]) async {
    await executionScope?.beforeRequest();
    executionScope?.verify();
    final uri = baseUri == null
        ? BackendConst.buildUri('uapi/mcp/$path')
        : baseUri!.resolve(path);
    final request = http.AbortableRequest(method, uri,
        abortTrigger: executionScope?.abortTrigger)
      ..headers.addAll({
        ...(fixedHeaders ?? hiHeaders()),
        if (body != null) 'content-type': 'application/json'
      });
    if (body != null) request.body = body;
    executionScope?.verifyRequest();
    final pending =
        _client.send(request).then(http.Response.fromStream).timeout(timeout);
    final response = executionScope == null
        ? await pending
        : await executionScope!.wait(pending);
    executionScope?.verify();
    return response;
  }

  /// 拉取聚合工具清单；后端未配置任何 server 时返回空。
  Future<List<BackendMcpTool>> listTools() async {
    final resp = await _request('GET', 'tools');
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      throw McpException('后端 MCP 列工具失败 HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json['code'] != 0) throw McpException('后端 MCP 列工具失败：$body');
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tools = (data['tools'] as List?) ?? const [];
    return [
      for (final t in tools)
        BackendMcpTool(
          name: '${(t as Map)['name']}',
          description: t['description'] as String?,
          parameters: (t['parameters'] as Map?)?.cast<String, dynamic>() ??
              const {'type': 'object', 'properties': <String, dynamic>{}},
          serverId: '${t['serverId'] ?? ''}',
        ),
    ];
  }

  /// 让后端代为执行一次工具调用，返回纯文本结果。
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final resp = await _request(
        'POST', 'call', jsonEncode({'name': name, 'arguments': args}));
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      throw McpException('后端 MCP 调用失败 HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json['code'] != 0) throw McpException('后端 MCP 调用失败：$body');
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return '${data['content'] ?? ''}';
  }
}
