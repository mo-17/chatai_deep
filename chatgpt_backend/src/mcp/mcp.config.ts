/** 后端侧 MCP server 配置（来自环境变量 MCP_SERVERS 的 JSON 数组）。 */
export interface McpServerConfig {
  /** 稳定 id（工具名前缀 mcp__<id>__<tool>，也是 call 路由依据）。 */
  id: string;
  name?: string;
  transport: 'http' | 'stdio';
  enabled?: boolean;
  // http 传输：
  url?: string;
  headers?: Record<string, string>;
  // stdio 传输：
  command?: string;
  args?: string[];
  env?: Record<string, string>;
}

/**
 * 解析 MCP_SERVERS 环境变量。容错：非法 JSON / 缺字段的条目被跳过而非抛错，
 * 避免一个坏配置拖垮整个后端启动。返回 enabled !== false 且字段齐全的条目。
 */
export function parseMcpServers(raw: string | undefined): McpServerConfig[] {
  if (!raw || !raw.trim()) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];

  const out: McpServerConfig[] = [];
  const seen = new Set<string>();
  for (const item of parsed) {
    const cfg = item as McpServerConfig;
    if (!cfg || typeof cfg.id !== 'string' || !cfg.id.trim()) continue;
    if (seen.has(cfg.id)) continue;
    if (cfg.enabled === false) continue;
    if (cfg.transport === 'http') {
      if (typeof cfg.url !== 'string' || !cfg.url.trim()) continue;
    } else if (cfg.transport === 'stdio') {
      if (typeof cfg.command !== 'string' || !cfg.command.trim()) continue;
    } else {
      continue;
    }
    seen.add(cfg.id);
    out.push(cfg);
  }
  return out;
}
