/// 客户端直连的 MCP server 配置（方案 A）。移动端只能直连远程 Streamable HTTP
/// 型 server（stdio 子进程在 iOS/Android/OHOS 上跑不了，那类走方案 B 后端代理）。
class McpServerConfig {
  /// 稳定 id：工具名前缀 mcp__<id>__<tool> 的一部分，也是去重 / 路由依据。
  final String id;
  final String name;

  /// Streamable HTTP 端点（如 https://example.com/mcp）。
  final String url;

  /// 附加请求头（如鉴权 Authorization）。
  final Map<String, String> headers;

  /// 是否启用（关闭则不参与工具发现）。
  final bool enabled;

  /// 是否信任：信任的 server 其工具调用免确认；默认 false（每次调用前需确认，
  /// 与项目「防提示注入静默执行」的安全取向一致）。
  final bool trusted;

  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.headers = const {},
    this.enabled = true,
    this.trusted = false,
  });

  McpServerConfig copyWith({
    String? id,
    String? name,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
    bool? trusted,
  }) =>
      McpServerConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        url: url ?? this.url,
        headers: headers ?? this.headers,
        enabled: enabled ?? this.enabled,
        trusted: trusted ?? this.trusted,
      );

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? (j['id'] as String? ?? 'MCP'),
        url: j['url'] as String? ?? '',
        headers: (j['headers'] as Map?)
                ?.map((k, v) => MapEntry('$k', '$v')) ??
            const {},
        enabled: j['enabled'] as bool? ?? true,
        trusted: j['trusted'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'headers': headers,
        'enabled': enabled,
        'trusted': trusted,
      };
}

/// MCP server 暴露的一个工具声明（tools/list 的元素）。
class McpToolSpec {
  /// 暴露给模型的工具名（已加 mcp__<serverId>__ 前缀，全局唯一）。
  final String name;
  final String? description;

  /// 工具参数的 JSON Schema（OpenAI function parameters）。
  final Map<String, dynamic> inputSchema;

  /// 来源 server id（路由调用用）。
  final String serverId;

  /// 是否信任（来源 server 的 trusted）。信任则调用免确认。
  final bool trusted;

  const McpToolSpec({
    required this.name,
    required this.inputSchema,
    required this.serverId,
    this.description,
    this.trusted = false,
  });
}
