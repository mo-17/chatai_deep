import { parseMcpServers } from './mcp.config';
import { HttpMcpClient } from './mcp-client';

describe('parseMcpServers', () => {
  it('空 / 非法 JSON → 空数组', () => {
    expect(parseMcpServers(undefined)).toEqual([]);
    expect(parseMcpServers('')).toEqual([]);
    expect(parseMcpServers('not json')).toEqual([]);
    expect(parseMcpServers('{}')).toEqual([]); // 非数组
  });

  it('保留合法 http / stdio 条目，丢弃缺字段 / 重复 / 禁用', () => {
    const raw = JSON.stringify([
      { id: 'a', transport: 'http', url: 'https://a/mcp' },
      { id: 'b', transport: 'stdio', command: 'npx', args: ['-y', 'x'] },
      { id: 'a', transport: 'http', url: 'https://dup/mcp' }, // 重复 id
      { id: 'c', transport: 'http' }, // http 缺 url
      { id: 'd', transport: 'stdio' }, // stdio 缺 command
      { id: 'e', transport: 'http', url: 'https://e/mcp', enabled: false },
      { transport: 'http', url: 'https://noid/mcp' }, // 缺 id
      { id: 'f', transport: 'weird', url: 'x' }, // 未知 transport
    ]);
    const out = parseMcpServers(raw);
    expect(out.map((s) => s.id)).toEqual(['a', 'b']);
    expect(out[0].url).toBe('https://a/mcp'); // 取首个，重复被忽略
  });
});

describe('HttpMcpClient (mock fetch)', () => {
  const realFetch = globalThis.fetch;
  let lastCallArgs: unknown;

  function makeResp(
    body: unknown,
    { contentType = 'application/json', sessionId = '' } = {},
  ) {
    const headers = new Map<string, string>([['content-type', contentType]]);
    if (sessionId) headers.set('mcp-session-id', sessionId);
    return {
      ok: true,
      status: 200,
      headers: { get: (k: string) => headers.get(k.toLowerCase()) ?? null },
      text: () =>
        Promise.resolve(typeof body === 'string' ? body : JSON.stringify(body)),
      json: () => Promise.resolve(body),
    };
  }

  beforeEach(() => {
    lastCallArgs = undefined;
    globalThis.fetch = jest.fn((_url: unknown, init: unknown) => {
      const req = JSON.parse((init as { body: string }).body) as {
        id?: number;
        method: string;
        params?: { arguments?: unknown };
      };
      if (req.id == null) return makeResp('', { contentType: 'text/plain' }); // 通知
      switch (req.method) {
        case 'initialize':
          return makeResp(
            { jsonrpc: '2.0', id: req.id, result: { capabilities: {} } },
            { sessionId: 'sess-9' },
          );
        case 'tools/list':
          return makeResp({
            jsonrpc: '2.0',
            id: req.id,
            result: {
              tools: [
                {
                  name: 'echo',
                  description: 'e',
                  inputSchema: { type: 'object' },
                },
              ],
            },
          });
        case 'tools/call':
          lastCallArgs = req.params?.arguments;
          return makeResp({
            jsonrpc: '2.0',
            id: req.id,
            result: { content: [{ type: 'text', text: 'pong' }] },
          });
        default:
          return makeResp({ jsonrpc: '2.0', id: req.id, result: {} });
      }
    }) as unknown as typeof fetch;
  });

  afterAll(() => {
    globalThis.fetch = realFetch;
  });

  it('listTools 走完 initialize 握手并返回工具', async () => {
    const c = new HttpMcpClient('https://x/mcp');
    const tools = await c.listTools();
    expect(tools.map((t) => t.name)).toEqual(['echo']);
  });

  it('callTool 透传参数并提取文本结果', async () => {
    const c = new HttpMcpClient('https://x/mcp');
    const out = await c.callTool('echo', { text: 'hi' });
    expect(out).toBe('pong');
    expect(lastCallArgs).toEqual({ text: 'hi' });
  });

  it('SSE 响应也能解析', async () => {
    globalThis.fetch = jest.fn((_url: unknown, init: unknown) => {
      const req = JSON.parse((init as { body: string }).body) as {
        id?: number;
        method: string;
      };
      if (req.id == null) return makeResp('', { contentType: 'text/plain' });
      const payload =
        req.method === 'tools/list'
          ? {
              jsonrpc: '2.0',
              id: req.id,
              result: { tools: [{ name: 'fromSse', inputSchema: {} }] },
            }
          : { jsonrpc: '2.0', id: req.id, result: { capabilities: {} } };
      return makeResp(`event: message\ndata: ${JSON.stringify(payload)}\n\n`, {
        contentType: 'text/event-stream',
      });
    }) as unknown as typeof fetch;
    const c = new HttpMcpClient('https://x/mcp');
    const tools = await c.listTools();
    expect(tools).toHaveLength(1);
    expect(tools[0].name).toBe('fromSse');
  });
});
