// MCP 服务商店目录（admin 端）。与 Flutter 端
// `chatgpt_app_core/lib/data/builtin_mcp_servers.dart` 保持同一份内容——改一边时
// 另一边一并更新。后端宿主支持 stdio，故 admin 商店同时收录远程 HTTP 与本地 stdio。
// 远程 server 均经联网核实公开可用；stdio 为 MCP 官方 reference server。

export type McpAuthKind = 'none' | 'header' | 'apiKeyInUrl' | 'oauth';

export interface McpStoreEntry {
  category: string;
  /** 稳定 code：后端 server 的 code（工具名前缀的一部分）。 */
  id: string;
  name: string;
  emoji: string;
  description: string;
  transport: 'http' | 'stdio';
  /** http 端点；apiKeyInUrl 型含 {API_KEY} 占位。 */
  url?: string;
  command?: string;
  args?: string[];
  auth: McpAuthKind;
  /** 配置提示（填什么 token / 替换什么占位）。 */
  authHint?: string;
  homepage?: string;
}

export const MCP_STORE: McpStoreEntry[] = [
  // ── 文档检索 ──
  {
    category: '文档检索',
    id: 'context7',
    name: 'Context7',
    emoji: '📚',
    description: '按版本拉取主流框架/库的实时官方文档与示例，消除模型幻觉 API。',
    transport: 'http',
    url: 'https://mcp.context7.com/mcp',
    auth: 'none',
    authHint: '公开可用；如需更高额度可在请求头加 Context7 API Key。',
    homepage: 'https://context7.com',
  },
  {
    category: '文档检索',
    id: 'deepwiki',
    name: 'DeepWiki',
    emoji: '🧭',
    description: '对任意 GitHub 公开仓库提问，返回其文档与源码层面的解答。',
    transport: 'http',
    url: 'https://mcp.deepwiki.com/mcp',
    auth: 'none',
    homepage: 'https://deepwiki.com',
  },
  {
    category: '文档检索',
    id: 'microsoft_learn',
    name: 'Microsoft Learn',
    emoji: '📘',
    description: '搜索微软官方 / Azure 技术文档，返回高质量内容片段（标题 / URL / 摘录）。',
    transport: 'http',
    url: 'https://learn.microsoft.com/api/mcp',
    auth: 'none',
    authHint: '微软官方公开端点，无需鉴权。',
    homepage: 'https://learn.microsoft.com',
  },
  {
    category: '文档检索',
    id: 'scholar_sidekick',
    name: 'Scholar Sidekick',
    emoji: '🎓',
    description: '解析 DOI/PMID/arXiv 等学术标识，格式化引用、查撤稿与开放获取情况。',
    transport: 'http',
    url: 'https://scholar-sidekick.com/api/mcp',
    auth: 'none',
    authHint: '匿名可用（限速）。',
    homepage: 'https://scholar-sidekick.com/mcp',
  },
  {
    category: '文档检索',
    id: 'aws_knowledge',
    name: 'AWS Knowledge',
    emoji: '📗',
    description: '搜索 AWS 官方文档 / API 参考 / 博客与最新公告，返回权威内容片段；匿名可用。',
    transport: 'http',
    url: 'https://knowledge-mcp.global.api.aws/mcp',
    auth: 'none',
    authHint: 'AWS 官方公开端点，无需鉴权。',
    homepage: 'https://docs.aws.amazon.com',
  },
  {
    category: '文档检索',
    id: 'cloudflare_docs',
    name: 'Cloudflare Docs',
    emoji: '📙',
    description: '搜索 Cloudflare 官方开发者文档，返回相关内容片段；匿名可用。',
    transport: 'http',
    url: 'https://docs.mcp.cloudflare.com/mcp',
    auth: 'none',
    authHint: 'Cloudflare 官方公开端点，无需鉴权。',
    homepage: 'https://developers.cloudflare.com',
  },
  // ── 搜索 ──
  {
    category: '搜索',
    id: 'exa',
    name: 'Exa Search',
    emoji: '🔎',
    description: '实时语义网络搜索与正文抓取，支持时间 / 站点过滤；匿名即可用（限速）。',
    transport: 'http',
    url: 'https://mcp.exa.ai/mcp',
    auth: 'none',
    authHint: '匿名免 Key 可用（限速）；如需更高额度可在 exa.ai 注册后在请求头加 API Key。',
    homepage: 'https://exa.ai',
  },
  {
    category: '搜索',
    id: 'keenable',
    name: 'Keenable Search',
    emoji: '🔍',
    description: '免费公开的网络搜索，返回相关网页摘要与链接，支持日期 / 站点过滤，无需注册。',
    transport: 'http',
    url: 'https://api.keenable.ai/mcp',
    auth: 'none',
    homepage: 'https://keenable.ai',
  },
  {
    category: '搜索',
    id: 'tavily',
    name: 'Tavily Search',
    emoji: '🌊',
    description: '生产级实时联网搜索与内容提取（search / extract / map / crawl）。',
    transport: 'http',
    url: 'https://mcp.tavily.com/mcp/?tavilyApiKey={API_KEY}',
    auth: 'apiKeyInUrl',
    authHint:
      '在 app.tavily.com 免费注册获取 tvly- 开头的 API Key（每月 1000 次免费），替换 URL 中的 {API_KEY}。',
    homepage: 'https://tavily.com',
  },
  {
    category: '搜索',
    id: 'kagi',
    name: 'Kagi Search',
    emoji: '🦝',
    description: 'Kagi 高质量无广告搜索，支持网页 / 新闻 / 视频 / 播客 / 图片多种结果。',
    transport: 'http',
    url: 'https://mcp.kagi.com/mcp',
    auth: 'header',
    authHint:
      '在 kagi.com/settings?p=api 生成 API Token，请求头填 Authorization: Bearer <token>。',
    homepage: 'https://kagi.com',
  },
  {
    category: '搜索',
    id: 'serpapi',
    name: 'SerpApi',
    emoji: '🔭',
    description: '多引擎 SERP 数据：Google / Bing / 百度 / 地图 / 购物 / 新闻等结构化搜索结果。',
    transport: 'http',
    url: 'https://mcp.serpapi.com/{API_KEY}/mcp',
    auth: 'apiKeyInUrl',
    authHint: '在 serpapi.com/manage-api-key 获取 API Key，替换 URL 路径中的 {API_KEY}。',
    homepage: 'https://serpapi.com',
  },
  // ── 代码与仓库 ──
  {
    category: '代码与仓库',
    id: 'gitmcp',
    name: 'GitMCP',
    emoji: '🐙',
    description:
      '把任意 GitHub 仓库变成 MCP 文档源。URL 里把 {owner}/{repo} 换成目标仓库。',
    transport: 'http',
    url: 'https://gitmcp.io/{owner}/{repo}',
    auth: 'none',
    authHint: '无需鉴权；保存前请把 URL 中的 {owner}/{repo} 替换为实际仓库。',
    homepage: 'https://gitmcp.io',
  },
  // ── 网页抓取 ──
  {
    category: '网页抓取',
    id: 'firecrawl',
    name: 'Firecrawl',
    emoji: '🔥',
    description: 'LLM 驱动的网页抓取与结构化数据提取。',
    transport: 'http',
    url: 'https://mcp.firecrawl.dev/{API_KEY}/mcp',
    auth: 'apiKeyInUrl',
    authHint: '保存前把 URL 中的 {API_KEY} 替换为你的 Firecrawl API Key。',
    homepage: 'https://firecrawl.dev',
  },
  {
    category: '网页抓取',
    id: 'jina_reader',
    name: 'Jina AI Reader',
    emoji: '📖',
    description: 'Jina 官方：网页正文读取、语义网络搜索、arXiv 检索、截图等 20+ 工具。',
    transport: 'http',
    url: 'https://mcp.jina.ai/v1',
    auth: 'header',
    authHint:
      '在 jina.ai/api-dashboard 获取 API Key，请求头填 Authorization: Bearer <key>。',
    homepage: 'https://jina.ai',
  },
  // ── 知识库 ──
  {
    category: '知识库',
    id: 'huggingface',
    name: 'Hugging Face',
    emoji: '🤗',
    description: '搜索 HuggingFace 模型 / 数据集 / Space 及 arXiv 机器学习论文，匿名可用（限速）。',
    transport: 'http',
    url: 'https://huggingface.co/mcp',
    auth: 'none',
    authHint: '匿名免 Key 可用（限速）；可选在请求头加 Authorization: Bearer <HF_TOKEN> 提升额度。',
    homepage: 'https://huggingface.co/mcp',
  },
  {
    category: '知识库',
    id: 'supermemory',
    name: 'Supermemory',
    emoji: '💾',
    description: '跨对话的持久 AI 记忆引擎，可保存 / 搜索 / 检索用户记忆与上下文。',
    transport: 'http',
    url: 'https://mcp.supermemory.ai/mcp',
    auth: 'header',
    authHint:
      '在 app.supermemory.ai 获取 sm_ 开头的 API Key，请求头填 Authorization: Bearer sm_<key>。',
    homepage: 'https://supermemory.ai/mcp/',
  },
  // ── 数据与金融 ──
  {
    category: '数据与金融',
    id: 'coingecko',
    name: 'CoinGecko',
    emoji: '🦎',
    description: '免鉴权加密行情：币价 / 市值 / 交易对 / 历史数据，覆盖上万币种。',
    transport: 'http',
    url: 'https://mcp.api.coingecko.com/mcp',
    auth: 'none',
    authHint: '公开端点，无需鉴权（限速）；如需更高额度可在 coingecko.com 申请 Pro Key。',
    homepage: 'https://www.coingecko.com',
  },
  {
    category: '数据与金融',
    id: 'coinapi',
    name: 'CoinAPI Market Data',
    emoji: '💹',
    description: '400+ 交易所的实时与历史加密行情（OHLCV / 订单簿 / 成交 / 汇率）。',
    transport: 'http',
    url: 'https://mcp.md.coinapi.io/mcp',
    auth: 'header',
    authHint:
      '在 coinapi.io 免费注册获取 API Key（含 $25 额度）；请求头改用 X-CoinAPI-Key: <key>（删掉预填的 Authorization 行）。',
    homepage: 'https://www.coinapi.io/mcp',
  },
  // ── 自动化 ──
  {
    category: '自动化',
    id: 'apify',
    name: 'Apify Actors',
    emoji: '🕷️',
    description: '4000+ 网页抓取 / 自动化 Actor，按需调用。',
    transport: 'http',
    url: 'https://mcp.apify.com',
    auth: 'header',
    authHint: '在请求头填 Authorization: Bearer <你的 Apify Token>。',
    homepage: 'https://apify.com',
  },
  {
    category: '自动化',
    id: 'tally',
    name: 'Tally Forms',
    emoji: '📝',
    description: '用自然语言创建与管理 Tally 表单。',
    transport: 'http',
    url: 'https://api.tally.so/mcp',
    auth: 'header',
    authHint: '在请求头填 Authorization: Bearer <你的 Tally Token>。',
    homepage: 'https://tally.so',
  },
  // ── 实用工具 ──
  {
    category: '实用工具',
    id: 'roundtable',
    name: 'Roundtable',
    emoji: '🧠',
    description: '多模型「圆桌」头脑风暴，内置十余个协作工具。',
    transport: 'http',
    url: 'https://mcp.roundtable.now/mcp',
    auth: 'none',
    homepage: 'https://roundtable.now',
  },
  // ── 官方·本地（stdio）──
  {
    category: '官方·本地（stdio）',
    id: 'everything',
    name: 'Everything（官方示例）',
    emoji: '🧪',
    description:
      'MCP 官方测试/示例 server，集齐 tools / resources / prompts，适合验证联通。',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-everything'],
    auth: 'none',
    authHint: '需后端宿主装有 Node（npx）。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
  {
    category: '官方·本地（stdio）',
    id: 'filesystem',
    name: 'Filesystem（官方）',
    emoji: '📁',
    description: '受控的本地文件读写，需在 args 末尾追加允许访问的目录。',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-filesystem', '/允许访问的目录'],
    auth: 'none',
    authHint: '需 Node（npx）；把 args 末尾替换为后端可访问的真实目录。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
  {
    category: '官方·本地（stdio）',
    id: 'memory',
    name: 'Memory（官方）',
    emoji: '🧩',
    description: '基于知识图谱的持久记忆 server。',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-memory'],
    auth: 'none',
    authHint: '需 Node（npx）。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
  {
    category: '官方·本地（stdio）',
    id: 'sequentialthinking',
    name: 'Sequential Thinking（官方）',
    emoji: '🔗',
    description: '把复杂问题拆成可反思的思考序列。',
    transport: 'stdio',
    command: 'npx',
    args: ['-y', '@modelcontextprotocol/server-sequentialthinking'],
    auth: 'none',
    authHint: '需 Node（npx）。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
  {
    category: '官方·本地（stdio）',
    id: 'fetch',
    name: 'Fetch（官方）',
    emoji: '🌐',
    description: '抓取网页并转成适合 LLM 的 Markdown。',
    transport: 'stdio',
    command: 'uvx',
    args: ['mcp-server-fetch'],
    auth: 'none',
    authHint: '需后端宿主装有 uv（uvx）。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
  {
    category: '官方·本地（stdio）',
    id: 'git',
    name: 'Git（官方）',
    emoji: '🌿',
    description: '读取、检索、操作本地 Git 仓库。',
    transport: 'stdio',
    command: 'uvx',
    args: ['mcp-server-git'],
    auth: 'none',
    authHint: '需 uv（uvx）。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
  {
    category: '官方·本地（stdio）',
    id: 'time',
    name: 'Time（官方）',
    emoji: '🕐',
    description: '时间与时区换算。',
    transport: 'stdio',
    command: 'uvx',
    args: ['mcp-server-time'],
    auth: 'none',
    authHint: '需 uv（uvx）。',
    homepage: 'https://github.com/modelcontextprotocol/servers',
  },
];

/** 按分类分组（保持收录顺序）。 */
export function mcpStoreGrouped(): Record<string, McpStoreEntry[]> {
  const out: Record<string, McpStoreEntry[]> = {};
  for (const e of MCP_STORE) {
    (out[e.category] ??= []).push(e);
  }
  return out;
}

const AUTH_BADGE: Record<McpAuthKind, { label: string; color: string }> = {
  none: { label: '免鉴权', color: 'success' },
  header: { label: '需令牌', color: 'warning' },
  apiKeyInUrl: { label: '需 Key', color: 'warning' },
  oauth: { label: '需 OAuth', color: 'danger' },
};

export function authBadge(auth: McpAuthKind) {
  return AUTH_BADGE[auth];
}
