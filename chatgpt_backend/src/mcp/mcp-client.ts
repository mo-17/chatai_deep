import { spawn, ChildProcessWithoutNullStreams } from 'child_process';

/**
 * 依赖无关的 MCP（Model Context Protocol）客户端。后端作为 MCP Host，
 * 用它连接各 MCP server。刻意不引第三方 SDK：手写 JSON-RPC 2.0，
 * 同时支持两种传输——
 *  - http：Streamable HTTP（移动端也能直连的远程 server）；
 *  - stdio：本地子进程（移动端做不到，正是后端代理（方案 B）的价值所在）。
 */

/** MCP server 暴露的一个工具声明（tools/list 的元素）。 */
export interface McpToolSpec {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

/** 统一的客户端接口：列/调工具、资源、提示词、关闭，以及 server 能力声明。 */
export interface McpClient {
  listTools(): Promise<McpToolSpec[]>;
  callTool(name: string, args: Record<string, unknown>): Promise<string>;
  listResources(): Promise<Record<string, unknown>[]>;
  readResource(uri: string): Promise<string>;
  listPrompts(): Promise<Record<string, unknown>[]>;
  getPrompt(name: string, args: Record<string, unknown>): Promise<string>;
  /** initialize 时 server 声明的能力（resources / prompts / tools）。 */
  readonly capabilities: Record<string, unknown>;
  close(): Promise<void>;
}

/** 从 tools/call 的 result 里提取纯文本内容（content[].text 拼接）。 */
function extractText(result: unknown): string {
  const r = result as { content?: unknown; isError?: boolean } | undefined;
  const content = Array.isArray(r?.content) ? r.content : [];
  const parts: string[] = [];
  for (const c of content) {
    const item = c as { type?: string; text?: string };
    if (item?.type === 'text' && typeof item.text === 'string') {
      parts.push(item.text);
    } else if (item?.text) {
      parts.push(String(item.text));
    } else {
      parts.push(JSON.stringify(c));
    }
  }
  const text = parts.join('\n').trim();
  if (r?.isError) return `工具返回错误：${text || '(无内容)'}`;
  return text || '(工具无文本输出)';
}

const PROTOCOL_VERSION = '2025-06-18';
const CLIENT_INFO = { name: 'chatgpt-backend-mcp-host', version: '1.0.0' };

interface JsonRpcResponse {
  id?: number;
  result?: unknown;
  error?: { code: number; message: string };
}

/** 公共的初始化握手 + 列/调工具逻辑；子类只需实现 [rpc]。 */
abstract class BaseMcpClient implements McpClient {
  protected initialized = false;
  protected nextId = 1;
  capabilities: Record<string, unknown> = {};

  get supportsResources(): boolean {
    return this.capabilities.resources != null;
  }

  get supportsPrompts(): boolean {
    return this.capabilities.prompts != null;
  }

  /** 发送一次 JSON-RPC；通知（无 id）时 isNotification=true，返回 undefined。 */
  protected abstract rpc(
    method: string,
    params?: unknown,
    isNotification?: boolean,
  ): Promise<unknown>;

  abstract close(): Promise<void>;

  protected async ensureInitialized(): Promise<void> {
    if (this.initialized) return;
    const init = (await this.rpc('initialize', {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: CLIENT_INFO,
    })) as { capabilities?: Record<string, unknown> };
    this.capabilities = init?.capabilities ?? {};
    await this.rpc('notifications/initialized', undefined, true);
    this.initialized = true;
  }

  async listTools(): Promise<McpToolSpec[]> {
    await this.ensureInitialized();
    const res = (await this.rpc('tools/list', {})) as { tools?: unknown[] };
    const tools = Array.isArray(res?.tools) ? res.tools : [];
    return tools.map((t) => {
      const tool = t as McpToolSpec;
      return {
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
      };
    });
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<string> {
    await this.ensureInitialized();
    const res = await this.rpc('tools/call', { name, arguments: args ?? {} });
    return extractText(res);
  }

  async listResources(): Promise<Record<string, unknown>[]> {
    await this.ensureInitialized();
    const res = (await this.rpc('resources/list', {})) as {
      resources?: unknown[];
    };
    return (Array.isArray(res?.resources) ? res.resources : []).map(
      (r) => r as Record<string, unknown>,
    );
  }

  async readResource(uri: string): Promise<string> {
    await this.ensureInitialized();
    const res = (await this.rpc('resources/read', { uri })) as {
      contents?: unknown[];
    };
    const contents = Array.isArray(res?.contents) ? res.contents : [];
    const parts: string[] = [];
    for (const c of contents) {
      const item = c as { text?: string; blob?: string; mimeType?: string };
      if (typeof item?.text === 'string') parts.push(item.text);
      else if (item?.blob)
        parts.push(
          `(二进制内容，已省略：${item.mimeType ?? 'application/octet-stream'})`,
        );
    }
    const text = parts.join('\n').trim();
    return text || '(资源无文本内容)';
  }

  async listPrompts(): Promise<Record<string, unknown>[]> {
    await this.ensureInitialized();
    const res = (await this.rpc('prompts/list', {})) as { prompts?: unknown[] };
    return (Array.isArray(res?.prompts) ? res.prompts : []).map(
      (p) => p as Record<string, unknown>,
    );
  }

  async getPrompt(
    name: string,
    args: Record<string, unknown>,
  ): Promise<string> {
    await this.ensureInitialized();
    const res = (await this.rpc('prompts/get', {
      name,
      arguments: args ?? {},
    })) as { messages?: unknown[] };
    const messages = Array.isArray(res?.messages) ? res.messages : [];
    const parts: string[] = [];
    for (const m of messages) {
      const msg = m as { role?: string; content?: { text?: string } | string };
      const content = msg?.content;
      const text =
        typeof content === 'object' && content
          ? String(content.text ?? '')
          : String(content ?? '');
      parts.push(`[${msg?.role ?? ''}] ${text}`);
    }
    const text = parts.join('\n').trim();
    return text || '(提示词无内容)';
  }
}

/** Streamable HTTP 传输：每次 POST 一个 JSON-RPC，响应可能是 JSON 或 SSE。 */
export class HttpMcpClient extends BaseMcpClient {
  private sessionId?: string;

  constructor(
    private readonly url: string,
    private readonly headers: Record<string, string> = {},
    private readonly timeoutMs = 30_000,
  ) {
    super();
  }

  protected async rpc(
    method: string,
    params?: unknown,
    isNotification = false,
  ): Promise<unknown> {
    const id = isNotification ? undefined : this.nextId++;
    const body = isNotification
      ? { jsonrpc: '2.0', method, params }
      : { jsonrpc: '2.0', id, method, params };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    let resp: Response;
    try {
      resp = await fetch(this.url, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          accept: 'application/json, text/event-stream',
          'mcp-protocol-version': PROTOCOL_VERSION,
          ...(this.sessionId ? { 'mcp-session-id': this.sessionId } : {}),
          ...this.headers,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }

    const sid = resp.headers.get('mcp-session-id');
    if (sid) this.sessionId = sid;

    if (isNotification) return undefined; // 202 Accepted，无响应体
    if (!resp.ok) {
      const text = await resp.text().catch(() => '');
      throw new Error(`MCP HTTP ${resp.status}: ${text.slice(0, 300)}`);
    }

    const ct = resp.headers.get('content-type') ?? '';
    const json = ct.includes('text/event-stream')
      ? this.parseSse(await resp.text(), id)
      : ((await resp.json()) as JsonRpcResponse);

    if (json?.error) {
      throw new Error(`MCP error ${json.error.code}: ${json.error.message}`);
    }
    return json?.result;
  }

  /** 从 SSE 文本里挑出与本次请求 id 匹配的 JSON-RPC 响应。 */
  private parseSse(text: string, id?: number): JsonRpcResponse {
    let fallback: JsonRpcResponse | undefined;
    for (const block of text.split(/\n\n/)) {
      const dataLines = block
        .split('\n')
        .filter((l) => l.startsWith('data:'))
        .map((l) => l.slice(5).trim());
      if (dataLines.length === 0) continue;
      try {
        const obj = JSON.parse(dataLines.join('\n')) as JsonRpcResponse;
        if (obj.id === id) return obj;
        if (obj.result !== undefined || obj.error) fallback ??= obj;
      } catch {
        // 忽略无法解析的事件
      }
    }
    if (fallback) return fallback;
    throw new Error('MCP SSE 响应里没有匹配的结果');
  }

  // eslint-disable-next-line @typescript-eslint/require-await
  async close(): Promise<void> {
    this.initialized = false;
  }
}

/** stdio 传输：拉起子进程，行分隔 JSON-RPC 走 stdin/stdout。 */
export class StdioMcpClient extends BaseMcpClient {
  private proc?: ChildProcessWithoutNullStreams;
  private buf = '';
  private readonly pending = new Map<
    number,
    { resolve: (v: unknown) => void; reject: (e: Error) => void }
  >();

  constructor(
    private readonly command: string,
    private readonly args: string[] = [],
    private readonly env: Record<string, string> = {},
    private readonly timeoutMs = 30_000,
  ) {
    super();
  }

  private ensureProc(): ChildProcessWithoutNullStreams {
    if (this.proc) return this.proc;
    const proc = spawn(this.command, this.args, {
      env: { ...process.env, ...this.env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    proc.stdout.on('data', (d: Buffer) => this.onData(d));
    proc.on('exit', (code) => {
      const err = new Error(`MCP stdio 进程退出 (code=${code})`);
      for (const { reject } of this.pending.values()) reject(err);
      this.pending.clear();
      this.proc = undefined;
      this.initialized = false;
    });
    proc.on('error', (e) => {
      for (const { reject } of this.pending.values()) reject(e);
      this.pending.clear();
    });
    this.proc = proc;
    return proc;
  }

  private onData(chunk: Buffer): void {
    this.buf += chunk.toString();
    let idx: number;
    while ((idx = this.buf.indexOf('\n')) >= 0) {
      const line = this.buf.slice(0, idx).trim();
      this.buf = this.buf.slice(idx + 1);
      if (!line) continue;
      let msg: JsonRpcResponse;
      try {
        msg = JSON.parse(line) as JsonRpcResponse;
      } catch {
        continue; // 非 JSON 行（部分 server 会往 stdout 打日志）
      }
      if (msg.id == null) continue; // 通知/服务端请求，本客户端不处理
      const waiter = this.pending.get(msg.id);
      if (!waiter) continue;
      this.pending.delete(msg.id);
      if (msg.error) {
        waiter.reject(
          new Error(`MCP error ${msg.error.code}: ${msg.error.message}`),
        );
      } else {
        waiter.resolve(msg.result);
      }
    }
  }

  protected rpc(
    method: string,
    params?: unknown,
    isNotification = false,
  ): Promise<unknown> {
    const proc = this.ensureProc();
    const id = isNotification ? undefined : this.nextId++;
    const body = isNotification
      ? { jsonrpc: '2.0', method, params }
      : { jsonrpc: '2.0', id, method, params };
    proc.stdin.write(JSON.stringify(body) + '\n');
    if (isNotification || id == null) return Promise.resolve(undefined);

    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) {
          reject(new Error(`MCP stdio 调用 "${method}" 超时`));
        }
      }, this.timeoutMs);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
    });
  }

  // eslint-disable-next-line @typescript-eslint/require-await
  async close(): Promise<void> {
    this.proc?.kill();
    this.proc = undefined;
    this.initialized = false;
  }
}
