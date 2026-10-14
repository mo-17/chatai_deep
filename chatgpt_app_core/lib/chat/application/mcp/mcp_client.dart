import 'dart:convert';
import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';

import 'package:http/http.dart' as http;

/// 客户端直连 MCP 工具（raw 名、未加前缀）。
class RawMcpTool {
  final String name;
  final String? description;
  final Map<String, dynamic> inputSchema;

  const RawMcpTool({
    required this.name,
    required this.inputSchema,
    this.description,
  });
}

/// 直连式 MCP 客户端（方案 A）：手写 JSON-RPC 2.0 over Streamable HTTP。
/// 不引第三方 SDK——一个端点 POST 请求，响应可能是 JSON 也可能是 SSE。
/// 移动端只用得上 HTTP 传输（stdio 子进程在移动端不可用）。
class DirectMcpClient {
  static const _protocolVersion = '2025-06-18';
  static const _clientInfo = {'name': 'chatai-flutter-mcp', 'version': '1.0.0'};

  final ToolExecutionScope? executionScope;
  final String url;
  final Map<String, String> headers;
  final Duration timeout;
  final http.Client _client;
  final bool _ownClient;

  String? _sessionId;
  bool _initialized = false;
  int _nextId = 1;
  Map<String, dynamic> _capabilities = const {};

  /// server 在 initialize 时声明的能力（含 resources / prompts / tools）。
  Map<String, dynamic> get capabilities => _capabilities;
  bool get supportsResources => _capabilities.containsKey('resources');
  bool get supportsPrompts => _capabilities.containsKey('prompts');

  DirectMcpClient({
    required this.url,
    this.executionScope,
    this.headers = const {},
    this.timeout = const Duration(seconds: 30),
    http.Client? client,
    bool closeInjectedClient = false,
  })  : _client = client ?? http.Client(),
        _ownClient = client == null || closeInjectedClient;

  /// 用完释放底层连接（仅当未注入外部 client 时）。
  void close() {
    if (_ownClient) _client.close();
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final init = await _rpc('initialize', {
      'protocolVersion': _protocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': _clientInfo,
    });
    _capabilities =
        (init?['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {};
    await _rpc('notifications/initialized', null, isNotification: true);
    _initialized = true;
  }

  Future<List<RawMcpTool>> listTools() async {
    await _ensureInitialized();
    final result = await _rpc('tools/list', <String, dynamic>{});
    final tools = (result?['tools'] as List?) ?? const [];
    return [
      for (final t in tools)
        RawMcpTool(
          name: '${(t as Map)['name']}',
          description: t['description'] as String?,
          inputSchema: (t['inputSchema'] as Map?)?.cast<String, dynamic>() ??
              const {'type': 'object', 'properties': <String, dynamic>{}},
        ),
    ];
  }

  Future<String> callTool(String rawName, Map<String, dynamic> args) async {
    await _ensureInitialized();
    final result =
        await _rpc('tools/call', {'name': rawName, 'arguments': args});
    return _extractText(result);
  }

  // ── Resources（item 7）──────────────────────────────────
  /// 列出 server 暴露的资源（uri / name / description / mimeType）。
  Future<List<Map<String, dynamic>>> listResources() async {
    await _ensureInitialized();
    final result = await _rpc('resources/list', <String, dynamic>{});
    final list = (result?['resources'] as List?) ?? const [];
    return [for (final r in list) (r as Map).cast<String, dynamic>()];
  }

  /// 读取一个资源，返回其文本内容（contents[].text 拼接）。
  Future<String> readResource(String uri) async {
    await _ensureInitialized();
    final result = await _rpc('resources/read', {'uri': uri});
    final contents = (result?['contents'] as List?) ?? const [];
    final parts = <String>[];
    for (final c in contents) {
      if (c is Map && c['text'] is String) {
        parts.add(c['text'] as String);
      } else if (c is Map && c['blob'] != null) {
        parts.add('(二进制内容，已省略：${c['mimeType'] ?? 'application/octet-stream'})');
      }
    }
    final text = parts.join('\n').trim();
    return text.isEmpty ? '(资源无文本内容)' : text;
  }

  // ── Prompts（item 7）────────────────────────────────────
  /// 列出 server 暴露的提示词模板（name / description / arguments）。
  Future<List<Map<String, dynamic>>> listPrompts() async {
    await _ensureInitialized();
    final result = await _rpc('prompts/list', <String, dynamic>{});
    final list = (result?['prompts'] as List?) ?? const [];
    return [for (final p in list) (p as Map).cast<String, dynamic>()];
  }

  /// 取一个提示词模板渲染后的文本（messages[].content 拼接）。
  Future<String> getPrompt(String name, Map<String, dynamic> args) async {
    await _ensureInitialized();
    final result = await _rpc('prompts/get', {'name': name, 'arguments': args});
    final messages = (result?['messages'] as List?) ?? const [];
    final parts = <String>[];
    for (final m in messages) {
      if (m is! Map) continue;
      final role = m['role'] ?? '';
      final content = m['content'];
      final text = content is Map ? '${content['text'] ?? ''}' : '$content';
      parts.add('[$role] $text');
    }
    final text = parts.join('\n').trim();
    return text.isEmpty ? '(提示词无内容)' : text;
  }

  /// 发送一次 JSON-RPC。返回 `result` 字段（通知返回 null）。
  Future<Map<String, dynamic>?> _rpc(
    String method,
    Object? params, {
    bool isNotification = false,
  }) async {
    final id = isNotification ? null : _nextId++;
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      if (id != null) 'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    await executionScope?.beforeRequest();
    executionScope?.verify();
    final request = http.AbortableRequest('POST', Uri.parse(url),
        abortTrigger: executionScope?.abortTrigger)
      ..headers.addAll({
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        'mcp-protocol-version': _protocolVersion,
        if (_sessionId != null) 'mcp-session-id': _sessionId!,
        ...headers,
      })
      ..body = jsonEncode(body);
    executionScope?.verifyRequest();
    final response = _client.send(request).then(http.Response.fromStream);
    final resp = executionScope == null
        ? await response.timeout(timeout)
        : await executionScope!.wait(response.timeout(timeout));
    executionScope?.verify();

    final sid = resp.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw McpException(_httpErrorMessage(resp));
    }
    if (isNotification) return null; // 202 Accepted，无响应体

    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final ct = resp.headers['content-type'] ?? '';
    final json = ct.contains('text/event-stream')
        ? _parseSse(text, id)
        : jsonDecode(text) as Map<String, dynamic>;

    final error = json['error'];
    if (error is Map) {
      throw McpException('MCP error ${error['code']}: ${error['message']}');
    }
    return (json['result'] as Map?)?.cast<String, dynamic>();
  }

  /// 从 SSE 文本里挑出与请求 id 匹配的 JSON-RPC 响应。
  Map<String, dynamic> _parseSse(String text, int? id) {
    Map<String, dynamic>? fallback;
    for (final block in text.split(RegExp(r'\n\n'))) {
      final data = block
          .split('\n')
          .where((l) => l.startsWith('data:'))
          .map((l) => l.substring(5).trim())
          .join('\n');
      if (data.isEmpty) continue;
      try {
        final obj = jsonDecode(data) as Map<String, dynamic>;
        if (obj['id'] == id) return obj;
        if (obj.containsKey('result') || obj.containsKey('error')) {
          fallback ??= obj;
        }
      } catch (_) {
        // 忽略无法解析的事件
      }
    }
    if (fallback != null) return fallback;
    throw const McpException('SSE 响应里没有匹配的结果');
  }

  static String _extractText(Map<String, dynamic>? result) {
    final content = (result?['content'] as List?) ?? const [];
    final parts = <String>[];
    for (final c in content) {
      if (c is Map && c['type'] == 'text' && c['text'] is String) {
        parts.add(c['text'] as String);
      } else if (c is Map && c['text'] != null) {
        parts.add('${c['text']}');
      } else {
        parts.add(jsonEncode(c));
      }
    }
    final text = parts.join('\n').trim();
    if (result?['isError'] == true) {
      return '工具返回错误：${text.isEmpty ? '(无内容)' : text}';
    }
    return text.isEmpty ? '(工具无文本输出)' : text;
  }

  static String _httpErrorMessage(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode == 404) {
      // Railway 网关回退与普通路径 404 不同，换 MCP 协议或补 Key 无法修复。
      Object? body;
      try {
        body = jsonDecode(text);
      } catch (_) {
        // 普通 HTML / 文本 404 仍按端点不存在提示。
      }
      if (response.headers['x-railway-fallback'] == 'true' &&
          body is Map &&
          body['message'] == 'Application not found') {
        return 'HTTP 404：服务端不可用，托管平台未找到该应用（Application not found）。'
            '请等待服务商恢复，或在 MCP 设置中暂时关闭此连接。';
      }
      return 'HTTP 404：未找到 MCP 端点，请核对服务商提供的完整地址；'
          '地址正确时需由服务商恢复服务。响应：${_cap(text, 300)}';
    }
    return 'HTTP ${response.statusCode}: ${_cap(text, 300)}';
  }

  static String _cap(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

class McpException implements Exception {
  final String message;
  const McpException(this.message);
  @override
  String toString() => 'McpException: $message';
}
