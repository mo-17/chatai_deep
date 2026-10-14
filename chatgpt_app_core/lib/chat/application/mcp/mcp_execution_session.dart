import 'package:chatgpt_app_core/chat/application/tool_execution_scope.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_backend_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:http/http.dart' as http;

/// 一个普通 run 的连接/发现结果；不借用全局池或跨账号目录缓存。
final class McpExecutionSession {
  final ToolExecutionScope scope;
  final Uri backendBase;
  final Map<String, String> backendHeaders;
  final http.Client Function()? clientFactory;
  final Map<String, DirectMcpClient> _direct = {};
  BackendMcpClient? _backend;
  bool _closed = false;
  McpExecutionSession(
      {required this.scope,
      required this.backendBase,
      required Map<String, String> backendHeaders,
      this.clientFactory})
      : backendHeaders = Map.unmodifiable(backendHeaders);

  DirectMcpClient direct(McpServerConfig server) {
    scope.verify();
    if (_closed) throw StateError('MCP 运行已结束');
    return _direct.putIfAbsent(
        server.id,
        () => DirectMcpClient(
            url: server.url,
            headers: Map.unmodifiable(server.headers),
            executionScope: scope,
            client: clientFactory?.call(),
            closeInjectedClient: true));
  }

  BackendMcpClient backend() {
    scope.verify();
    if (_closed) throw StateError('MCP 运行已结束');
    return _backend ??= BackendMcpClient(
        executionScope: scope,
        baseUri: backendBase,
        fixedHeaders: backendHeaders,
        client: clientFactory?.call(),
        closeInjectedClient: true);
  }

  void evict(McpServerConfig server) => _direct.remove(server.id)?.close();
  void close() {
    _closed = true;
    for (final c in _direct.values) {
      c.close();
    }
    _direct.clear();
    _backend?.close();
    _backend = null;
  }
}
