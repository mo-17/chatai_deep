export interface McpServer {
  id: number;
  code: string;
  name: string;
  transport: 'http' | 'stdio';
  url: string;
  /** 读取时值被脱敏为 '***'（仅保留 key）。 */
  headers: Record<string, string>;
  command: string;
  args: string[];
  /** 读取时值被脱敏为 '***'（仅保留 key）。 */
  env: Record<string, string>;
  enabled: boolean;
  sortOrder: number;
  createTime?: string;
  updateTime?: string;
}

export interface McpServerInput {
  code: string;
  name?: string;
  transport: 'http' | 'stdio';
  url?: string;
  headers?: Record<string, string>;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  enabled?: boolean;
  sortOrder?: number;
}

export interface McpTestResult {
  ok: boolean;
  toolCount?: number;
  tools?: string[];
  capabilities?: Record<string, unknown>;
  error?: string;
}
