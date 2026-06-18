import 'package:chatgpt_app_core/chat/application/mcp/mcp_client.dart';
import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';
import 'package:http/http.dart' as http;

class _Pooled {
  final DirectMcpClient client;
  DateTime lastUsed;
  _Pooled(this.client, this.lastUsed);
}

/// 直连 MCP 客户端连接池（方案 A，对应 item 6）。按 server 签名（url + 排序后的
/// 请求头）复用同一个 [DirectMcpClient]，使工具发现与多轮工具调用共享同一条
/// 已初始化的会话，免去每次调用都重做 initialize 握手。空闲超时自动回收；
/// 调用出错时显式驱逐，下次 acquire 会重新连接。
class McpClientPool {
  const McpClientPool._();

  /// 空闲连接的回收时长。
  static const Duration idleTtl = Duration(minutes: 5);

  static final Map<String, _Pooled> _pool = {};

  /// 取一个（可复用的）直连客户端。[client] 仅在新建时用于注入测试用 http.Client。
  static DirectMcpClient acquire(McpServerConfig server, {http.Client? client}) {
    _evictIdle();
    final sig = _signature(server);
    final existing = _pool[sig];
    if (existing != null) {
      existing.lastUsed = DateTime.now();
      return existing.client;
    }
    final c = DirectMcpClient(
      url: server.url,
      headers: server.headers,
      client: client,
    );
    _pool[sig] = _Pooled(c, DateTime.now());
    return c;
  }

  /// 驱逐某 server 的连接（调用出错后用，迫使下次重连）。
  static void evict(McpServerConfig server) {
    _pool.remove(_signature(server))?.client.close();
  }

  /// 清空整池（设置变更 / 登出 / 测试隔离）。
  static void clear() {
    for (final p in _pool.values) {
      p.client.close();
    }
    _pool.clear();
  }

  /// 当前池内连接数（仅供测试 / 诊断）。
  static int get size => _pool.length;

  static void _evictIdle() {
    final now = DateTime.now();
    _pool.removeWhere((_, v) {
      final stale = now.difference(v.lastUsed) > idleTtl;
      if (stale) v.client.close();
      return stale;
    });
  }

  static String _signature(McpServerConfig s) {
    final headers = s.headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final h = headers.map((e) => '${e.key}=${e.value}').join('&');
    return '${s.url}|$h';
  }
}
