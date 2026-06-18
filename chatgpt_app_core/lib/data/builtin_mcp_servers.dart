import 'package:chatgpt_app_core/chat/application/mcp/mcp_types.dart';

/// MCP 服务商店的鉴权方式。
enum McpAuthKind {
  /// 公开、无需鉴权。
  none,

  /// 需在请求头带令牌（如 `Authorization: Bearer <token>`）。
  header,

  /// 令牌拼在 URL 里（如 `https://host/{API_KEY}/mcp`）。
  apiKeyInUrl,

  /// 需 OAuth 授权——客户端直连暂不支持，仅作信息展示。
  oauth,
}

/// MCP 服务商店的一条精选条目。对应「助手市场」的 [BuiltinAssistant]：
/// 一份纯静态、可扩展、便于单测的精选目录。两端共用同一份内容（admin 侧
/// 有等价的 TS 版本 `chatgpt_admin/src/lib/mcpStore.ts`，改这里时一并更新）。
///
/// 收录的远程 server 均经联网核实公开可用；stdio 型为 MCP 官方 reference server。
class McpStoreEntry {
  /// 分类（商店按此分组展示）。
  final String category;

  /// 稳定 code：用作直连 server 的 id / 后端 server 的 code（工具名前缀的一部分）。
  final String id;
  final String name;
  final String emoji;
  final String description;

  /// 'http'（远程 Streamable HTTP，方案 A 可直连）| 'stdio'（本地子进程，仅后端方案 B）。
  final String transport;

  /// http 端点（transport == 'http' 时有效）。apiKeyInUrl 型含 `{API_KEY}` 占位。
  final String url;

  /// stdio 命令 + 参数（transport == 'stdio' 时有效）。
  final String command;
  final List<String> args;

  final McpAuthKind auth;

  /// 鉴权/配置提示（展示给用户，如「在请求头填 Authorization: Bearer <你的 token>」）。
  final String authHint;

  /// 项目主页 / 文档（可空）。
  final String homepage;

  const McpStoreEntry({
    required this.category,
    required this.id,
    required this.name,
    required this.emoji,
    required this.description,
    required this.transport,
    this.url = '',
    this.command = '',
    this.args = const [],
    this.auth = McpAuthKind.none,
    this.authHint = '',
    this.homepage = '',
  });

  bool get isHttp => transport == 'http';
  bool get isStdio => transport == 'stdio';

  /// 客户端能否直接「一键添加」（方案 A 仅支持 HTTP，且非 OAuth）。
  bool get directAddable => isHttp && auth != McpAuthKind.oauth;

  /// 预填一个直连 server 配置（用户在添加对话框里再补鉴权头 / 替换占位）。
  McpServerConfig toServerConfig() => McpServerConfig(
        id: id,
        name: name,
        url: url,
      );
}

/// MCP 服务商店目录。精选、可扩展。
class McpStore {
  const McpStore._();

  /// 全部条目（按收录顺序）。
  static const List<McpStoreEntry> all = [
    // ── 文档检索 ───────────────────────────────────────────
    McpStoreEntry(
      category: '文档检索',
      id: 'context7',
      name: 'Context7',
      emoji: '📚',
      description: '按版本拉取主流框架/库的实时官方文档与示例，消除模型幻觉 API。',
      transport: 'http',
      url: 'https://mcp.context7.com/mcp',
      auth: McpAuthKind.none,
      authHint: '公开可用；如需更高额度可在请求头加 Context7 API Key。',
      homepage: 'https://context7.com',
    ),
    McpStoreEntry(
      category: '文档检索',
      id: 'deepwiki',
      name: 'DeepWiki',
      emoji: '🧭',
      description: '对任意 GitHub 公开仓库提问，返回其文档与源码层面的解答。',
      transport: 'http',
      url: 'https://mcp.deepwiki.com/mcp',
      auth: McpAuthKind.none,
      homepage: 'https://deepwiki.com',
    ),

    // ── 代码与仓库 ─────────────────────────────────────────
    McpStoreEntry(
      category: '代码与仓库',
      id: 'gitmcp',
      name: 'GitMCP',
      emoji: '🐙',
      description: '把任意 GitHub 仓库变成 MCP 文档源。URL 里把 {owner}/{repo} 换成目标仓库。',
      transport: 'http',
      url: 'https://gitmcp.io/{owner}/{repo}',
      auth: McpAuthKind.none,
      authHint: '无需鉴权；保存前请把 URL 中的 {owner}/{repo} 替换为实际仓库。',
      homepage: 'https://gitmcp.io',
    ),

    // ── 安全 ──────────────────────────────────────────────
    McpStoreEntry(
      category: '安全',
      id: 'semgrep',
      name: 'Semgrep',
      emoji: '🛡️',
      description: '基于 Semgrep 的代码安全漏洞扫描与规则检索。',
      transport: 'http',
      url: 'https://mcp.semgrep.ai/mcp',
      auth: McpAuthKind.none,
      homepage: 'https://semgrep.dev',
    ),

    // ── 网页抓取 ───────────────────────────────────────────
    McpStoreEntry(
      category: '网页抓取',
      id: 'firecrawl',
      name: 'Firecrawl',
      emoji: '🔥',
      description: 'LLM 驱动的网页抓取与结构化数据提取。',
      transport: 'http',
      url: 'https://mcp.firecrawl.dev/{API_KEY}/mcp',
      auth: McpAuthKind.apiKeyInUrl,
      authHint: '保存前把 URL 中的 {API_KEY} 替换为你的 Firecrawl API Key。',
      homepage: 'https://firecrawl.dev',
    ),

    // ── 自动化 ─────────────────────────────────────────────
    McpStoreEntry(
      category: '自动化',
      id: 'apify',
      name: 'Apify Actors',
      emoji: '🕷️',
      description: '4000+ 网页抓取 / 自动化 Actor，按需调用。',
      transport: 'http',
      url: 'https://mcp.apify.com',
      auth: McpAuthKind.header,
      authHint: '在请求头填 Authorization: Bearer <你的 Apify Token>。',
      homepage: 'https://apify.com',
    ),
    McpStoreEntry(
      category: '自动化',
      id: 'tally',
      name: 'Tally Forms',
      emoji: '📝',
      description: '用自然语言创建与管理 Tally 表单。',
      transport: 'http',
      url: 'https://api.tally.so/mcp',
      auth: McpAuthKind.header,
      authHint: '在请求头填 Authorization: Bearer <你的 Tally Token>。',
      homepage: 'https://tally.so',
    ),

    // ── 实用工具 ───────────────────────────────────────────
    McpStoreEntry(
      category: '实用工具',
      id: 'roundtable',
      name: 'Roundtable',
      emoji: '🧠',
      description: '多模型「圆桌」头脑风暴，内置十余个协作工具。',
      transport: 'http',
      url: 'https://mcp.roundtable.now/mcp',
      auth: McpAuthKind.none,
      homepage: 'https://roundtable.now',
    ),
    McpStoreEntry(
      category: '实用工具',
      id: 'usefulai',
      name: 'Useful AI',
      emoji: '🧰',
      description: '340+ 自动构建的通用小工具集合。',
      transport: 'http',
      url: 'https://api.usefulai.fun/mcp',
      auth: McpAuthKind.none,
      homepage: 'https://usefulai.fun',
    ),

    // ── 官方示例 / 本地（stdio，仅后端方案 B 可用）────────────
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'everything',
      name: 'Everything（官方示例）',
      emoji: '🧪',
      description: 'MCP 官方测试/示例 server，集齐 tools / resources / prompts，适合验证联通。',
      transport: 'stdio',
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-everything'],
      authHint: '需后端宿主装有 Node（npx）。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'filesystem',
      name: 'Filesystem（官方）',
      emoji: '📁',
      description: '受控的本地文件读写，需在 args 末尾追加允许访问的目录。',
      transport: 'stdio',
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-filesystem', '/允许访问的目录'],
      authHint: '需 Node（npx）；把 args 末尾替换为后端可访问的真实目录。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'memory',
      name: 'Memory（官方）',
      emoji: '🧩',
      description: '基于知识图谱的持久记忆 server。',
      transport: 'stdio',
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-memory'],
      authHint: '需 Node（npx）。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'sequentialthinking',
      name: 'Sequential Thinking（官方）',
      emoji: '🔗',
      description: '把复杂问题拆成可反思的思考序列。',
      transport: 'stdio',
      command: 'npx',
      args: ['-y', '@modelcontextprotocol/server-sequentialthinking'],
      authHint: '需 Node（npx）。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'fetch',
      name: 'Fetch（官方）',
      emoji: '🌐',
      description: '抓取网页并转成适合 LLM 的 Markdown。',
      transport: 'stdio',
      command: 'uvx',
      args: ['mcp-server-fetch'],
      authHint: '需后端宿主装有 uv（uvx）。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'git',
      name: 'Git（官方）',
      emoji: '🌿',
      description: '读取、检索、操作本地 Git 仓库。',
      transport: 'stdio',
      command: 'uvx',
      args: ['mcp-server-git'],
      authHint: '需 uv（uvx）。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
    McpStoreEntry(
      category: '官方·本地（需后端）',
      id: 'time',
      name: 'Time（官方）',
      emoji: '🕐',
      description: '时间与时区换算。',
      transport: 'stdio',
      command: 'uvx',
      args: ['mcp-server-time'],
      authHint: '需 uv（uvx）。',
      homepage: 'https://github.com/modelcontextprotocol/servers',
    ),
  ];

  /// 适合客户端直连（方案 A）的条目：仅远程 HTTP。
  static List<McpStoreEntry> get httpEntries =>
      all.where((e) => e.isHttp).toList();

  /// 按分类分组（保持收录顺序）。[onlyHttp] 为 true 时只含可直连的 HTTP 条目。
  static Map<String, List<McpStoreEntry>> grouped({bool onlyHttp = false}) {
    final out = <String, List<McpStoreEntry>>{};
    for (final e in all) {
      if (onlyHttp && !e.isHttp) continue;
      (out[e.category] ??= []).add(e);
    }
    return out;
  }
}
