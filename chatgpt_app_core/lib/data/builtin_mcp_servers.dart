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

/// MCP 条目的移动端接入建议。
enum McpAccessKind {
  /// 免费、低权限、适合 App 端直接添加。
  freeDirect,

  /// 需要注册 / API Key / 免费额度，适合在商店中预填入口，由用户补 Key。
  keyRequired,

  /// OAuth 或付费/企业能力，不在移动端直接落直连配置，只展示入口与风险提示。
  externalEntry,
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

  final McpAccessKind access;

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
    this.access = McpAccessKind.freeDirect,
    this.authHint = '',
    this.homepage = '',
  });

  bool get isHttp => transport == 'http';
  bool get isStdio => transport == 'stdio';

  /// 客户端能否直接「一键添加」（方案 A 仅支持 HTTP，且非 OAuth）。
  bool get directAddable => isHttp && access != McpAccessKind.externalEntry;

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
    McpStoreEntry(
      category: '文档检索',
      id: 'microsoft_learn',
      name: 'Microsoft Learn',
      emoji: '📘',
      description: '搜索微软官方 / Azure 技术文档，返回高质量内容片段（标题 / URL / 摘录）。',
      transport: 'http',
      url: 'https://learn.microsoft.com/api/mcp',
      auth: McpAuthKind.none,
      authHint: '微软官方公开端点，无需鉴权。',
      homepage: 'https://learn.microsoft.com',
    ),
    McpStoreEntry(
      category: '文档检索',
      id: 'scholar_sidekick',
      name: 'Scholar Sidekick',
      emoji: '🎓',
      description: '解析 DOI/PMID/arXiv 等学术标识，格式化引用、查撤稿与开放获取情况。',
      transport: 'http',
      url: 'https://scholar-sidekick.com/api/mcp',
      auth: McpAuthKind.none,
      authHint: '匿名可用（限速）。',
      homepage: 'https://scholar-sidekick.com/mcp',
    ),
    McpStoreEntry(
      category: '文档检索',
      id: 'aws_knowledge',
      name: 'AWS Knowledge',
      emoji: '📗',
      description: '搜索 AWS 官方文档 / API 参考 / 博客与最新公告，返回权威内容片段；匿名可用。',
      transport: 'http',
      url: 'https://knowledge-mcp.global.api.aws/mcp',
      auth: McpAuthKind.none,
      authHint: 'AWS 官方公开端点，无需鉴权。',
      homepage: 'https://docs.aws.amazon.com',
    ),
    McpStoreEntry(
      category: '文档检索',
      id: 'cloudflare_docs',
      name: 'Cloudflare Docs',
      emoji: '📙',
      description: '搜索 Cloudflare 官方开发者文档，返回相关内容片段；匿名可用。',
      transport: 'http',
      url: 'https://docs.mcp.cloudflare.com/mcp',
      auth: McpAuthKind.none,
      authHint: 'Cloudflare 官方公开端点，无需鉴权。',
      homepage: 'https://developers.cloudflare.com',
    ),

    // ── 工具搜索 ───────────────────────────────────────────
    McpStoreEntry(
      category: '工具搜索',
      id: 'exa',
      name: 'Exa Search',
      emoji: '🔎',
      description: '作为 MCP 工具执行语义网络检索与正文抓取，支持时间 / 站点过滤；匿名可用（限速）。',
      transport: 'http',
      url: 'https://mcp.exa.ai/mcp',
      auth: McpAuthKind.none,
      authHint: '匿名免 Key 可用（限速）；如需更高额度可在 exa.ai 注册后在请求头加 API Key。',
      homepage: 'https://exa.ai',
    ),
    McpStoreEntry(
      category: '工具搜索',
      id: 'keenable',
      name: 'Keenable Search',
      emoji: '🔍',
      description: '作为 MCP 工具执行公开网页检索，返回网页摘要与链接，支持日期 / 站点过滤，无需注册。',
      transport: 'http',
      url: 'https://api.keenable.ai/mcp',
      auth: McpAuthKind.none,
      homepage: 'https://keenable.ai',
    ),
    McpStoreEntry(
      category: '工具搜索',
      id: 'tavily',
      name: 'Tavily Search',
      emoji: '🌊',
      description: '作为 MCP 工具提供生产级网页检索与内容提取（search / extract / map / crawl）。',
      transport: 'http',
      url: 'https://mcp.tavily.com/mcp/?tavilyApiKey={API_KEY}',
      auth: McpAuthKind.apiKeyInUrl,
      access: McpAccessKind.keyRequired,
      authHint:
          '在 app.tavily.com 免费注册获取 tvly- 开头的 API Key（每月 1000 次免费），替换 URL 中的 {API_KEY}。',
      homepage: 'https://tavily.com',
    ),
    McpStoreEntry(
      category: '工具搜索',
      id: 'kagi',
      name: 'Kagi Search',
      emoji: '🦝',
      description: '作为 MCP 工具调用 Kagi 高质量无广告检索，支持网页 / 新闻 / 视频 / 播客 / 图片。',
      transport: 'http',
      url: 'https://mcp.kagi.com/mcp',
      auth: McpAuthKind.header,
      access: McpAccessKind.keyRequired,
      authHint:
          '在 kagi.com/settings?p=api 生成 API Token，请求头填 Authorization: Bearer <token>。',
      homepage: 'https://kagi.com',
    ),
    McpStoreEntry(
      category: '工具搜索',
      id: 'serpapi',
      name: 'SerpApi',
      emoji: '🔭',
      description: '作为 MCP 工具获取多引擎 SERP 数据：Google / Bing / 百度 / 地图 / 购物 / 新闻等。',
      transport: 'http',
      url: 'https://mcp.serpapi.com/{API_KEY}/mcp',
      auth: McpAuthKind.apiKeyInUrl,
      access: McpAccessKind.keyRequired,
      authHint:
          '在 serpapi.com/manage-api-key 获取 API Key，替换 URL 路径中的 {API_KEY}。',
      homepage: 'https://serpapi.com',
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
      access: McpAccessKind.keyRequired,
      authHint: '保存前把 URL 中的 {API_KEY} 替换为你的 Firecrawl API Key。',
      homepage: 'https://firecrawl.dev',
    ),
    McpStoreEntry(
      category: '网页抓取',
      id: 'jina_reader',
      name: 'Jina AI Reader',
      emoji: '📖',
      description: 'Jina 官方：网页正文读取、语义网络搜索、arXiv 检索、截图等 20+ 工具。',
      transport: 'http',
      url: 'https://mcp.jina.ai/v1',
      auth: McpAuthKind.header,
      access: McpAccessKind.keyRequired,
      authHint:
          '在 jina.ai/api-dashboard 获取 API Key，请求头填 Authorization: Bearer <key>。',
      homepage: 'https://jina.ai',
    ),

    // ── 知识库 ─────────────────────────────────────────────
    McpStoreEntry(
      category: '知识库',
      id: 'huggingface',
      name: 'Hugging Face',
      emoji: '🤗',
      description: '搜索 HuggingFace 模型 / 数据集 / Space 及 arXiv 机器学习论文，匿名可用（限速）。',
      transport: 'http',
      url: 'https://huggingface.co/mcp',
      auth: McpAuthKind.none,
      authHint: '匿名免 Key 可用（限速）；可选在请求头加 Authorization: Bearer <HF_TOKEN> 提升额度。',
      homepage: 'https://huggingface.co/mcp',
    ),
    McpStoreEntry(
      category: '知识库',
      id: 'supermemory',
      name: 'Supermemory',
      emoji: '💾',
      description: '跨对话的持久 AI 记忆引擎，可保存 / 搜索 / 检索用户记忆与上下文。',
      transport: 'http',
      url: 'https://mcp.supermemory.ai/mcp',
      auth: McpAuthKind.header,
      access: McpAccessKind.keyRequired,
      authHint:
          '在 app.supermemory.ai 获取 sm_ 开头的 API Key，请求头填 Authorization: Bearer sm_<key>。',
      homepage: 'https://supermemory.ai/mcp/',
    ),

    // ── 账号与工作流（高权限入口，不默认直连）────────────────
    McpStoreEntry(
      category: '账号与工作流',
      id: 'github_remote',
      name: 'GitHub',
      emoji: 'GH',
      description: '官方远程 MCP：读取仓库、Issue、PR、Actions，也可能执行写操作；适合开发者工作流。',
      transport: 'http',
      url: 'https://api.githubcopilot.com/mcp/',
      auth: McpAuthKind.oauth,
      access: McpAccessKind.externalEntry,
      authHint:
          '需要 GitHub OAuth 或 PAT。移动端建议只作为入口展示，配置前请确认 token 权限最小化，并保留工具调用确认。',
      homepage: 'https://github.com/github/github-mcp-server',
    ),
    McpStoreEntry(
      category: '账号与工作流',
      id: 'notion_remote',
      name: 'Notion',
      emoji: 'NO',
      description: '官方 hosted MCP：搜索、读取并可写入 Notion workspace，适合个人知识库与项目文档。',
      transport: 'http',
      url: 'https://mcp.notion.com/mcp',
      auth: McpAuthKind.oauth,
      access: McpAccessKind.externalEntry,
      authHint:
          '需要 Notion OAuth，且可能获得 workspace 读写权限。移动端仅放入口，正式接入前需权限说明和写操作确认。',
      homepage: 'https://developers.notion.com/guides/mcp/overview',
    ),
    McpStoreEntry(
      category: '账号与工作流',
      id: 'stripe_remote',
      name: 'Stripe',
      emoji: 'ST',
      description: '官方远程 MCP：查支付、客户、订阅、退款与 Stripe 文档；商业/运营场景价值高。',
      transport: 'http',
      url: 'https://mcp.stripe.com',
      auth: McpAuthKind.oauth,
      access: McpAccessKind.externalEntry,
      authHint:
          '需要 Stripe OAuth 或 restricted API key。涉及支付和退款，必须保留人工确认，不写入默认直连列表。',
      homepage: 'https://docs.stripe.com/mcp',
    ),
    McpStoreEntry(
      category: '账号与工作流',
      id: 'cloudflare_api',
      name: 'Cloudflare API',
      emoji: 'CF',
      description:
          'Cloudflare 官方产品 MCP 入口集合：Workers、日志、DNS、AI Gateway、GraphQL 等。',
      transport: 'http',
      url: 'https://bindings.mcp.cloudflare.com/mcp',
      auth: McpAuthKind.oauth,
      access: McpAccessKind.externalEntry,
      authHint:
          'Cloudflare 提供多个产品远程 MCP，需要 OAuth/API Token。这里只放官方目录入口，不默认添加高权限端点。',
      homepage:
          'https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/',
    ),

    // ── 数据与金融 ─────────────────────────────────────────
    McpStoreEntry(
      category: '数据与金融',
      id: 'coingecko',
      name: 'CoinGecko',
      emoji: '🦎',
      description: '免鉴权加密行情：币价 / 市值 / 交易对 / 历史数据，覆盖上万币种。',
      transport: 'http',
      url: 'https://mcp.api.coingecko.com/mcp',
      auth: McpAuthKind.none,
      authHint: '公开端点，无需鉴权（限速）；如需更高额度可在 coingecko.com 申请 Pro Key。',
      homepage: 'https://www.coingecko.com',
    ),
    McpStoreEntry(
      category: '数据与金融',
      id: 'coinapi',
      name: 'CoinAPI Market Data',
      emoji: '💹',
      description: '400+ 交易所的实时与历史加密行情（OHLCV / 订单簿 / 成交 / 汇率）。',
      transport: 'http',
      url: 'https://mcp.md.coinapi.io/mcp',
      auth: McpAuthKind.header,
      access: McpAccessKind.keyRequired,
      authHint:
          '在 coinapi.io 免费注册获取 API Key（含 \$25 额度）；请求头改用 X-CoinAPI-Key: <key>（删掉预填的 Authorization 行）。',
      homepage: 'https://www.coinapi.io/mcp',
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
      access: McpAccessKind.keyRequired,
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
      access: McpAccessKind.keyRequired,
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
      all.where((e) => e.directAddable).toList();

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
