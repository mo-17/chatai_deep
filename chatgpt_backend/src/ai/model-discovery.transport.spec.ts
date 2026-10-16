import { EventEmitter } from 'node:events';
import dns from 'node:dns/promises';
import https from 'node:https';
import type { IncomingMessage, ClientRequest } from 'node:http';
import { ModelCatalogTransport, ModelSyncError } from './model-discovery';

// 实际生产 transport，DNS/HTTPS socket 对象注入；不宣称真实 TLS/外部端点证据。
describe('catalog transport DNS pinning, no redirects and bounded cleanup', () => {
  let lookup: jest.SpyInstance;
  let send: jest.SpyInstance;
  let req: EventEmitter & { end: jest.Mock; destroy: jest.Mock };
  let res: EventEmitter & {
    statusCode: number;
    headers: Record<string, string>;
    destroy: jest.Mock;
  };
  let options: https.RequestOptions;
  let body: string | null;
  beforeEach(() => {
    lookup = jest
      .spyOn(
        dns as unknown as {
          lookup: (
            hostname: string,
            options: { all: true; verbatim: true },
          ) => Promise<Array<{ address: string; family: number }>>;
        },
        'lookup',
      )
      .mockResolvedValue([{ address: '8.8.8.8', family: 4 }]);
    body = '{"data":[]}';
    req = Object.assign(new EventEmitter(), {
      end: jest.fn(),
      destroy: jest.fn(),
    });
    res = Object.assign(new EventEmitter(), {
      statusCode: 200,
      headers: { 'content-type': 'application/json' },
      destroy: jest.fn(),
    });
    send = jest
      .spyOn(https, 'request')
      .mockImplementation(
        (
          url: URL,
          opts: https.RequestOptions,
          callback: (res: IncomingMessage) => void,
        ) => {
          options = opts;
          req.end.mockImplementation(() => {
            queueMicrotask(() => {
              callback(res as unknown as IncomingMessage);
              if (body !== null) {
                res.emit('data', Buffer.from(body));
                res.emit('end');
              }
            });
          });
          opts.signal?.addEventListener(
            'abort',
            () => {
              req.destroy();
              req.emit('error', Error('synthetic abort'));
            },
            { once: true },
          );
          return req as unknown as ClientRequest;
        },
      );
  });
  afterEach(() => jest.restoreAllMocks());
  const read = (signal = new AbortController().signal) =>
    new ModelCatalogTransport().get(
      new URL('https://catalog.synthetic.invalid/v1/models'),
      { Authorization: 'Bearer synthetic-private' },
      signal,
    );
  it('checks all DNS results, pins the public socket address, uses GET and destroys completed request', async () => {
    expect(await read()).toEqual({ data: [] });
    expect(send).toHaveBeenCalledTimes(1);
    expect(options).toMatchObject({
      method: 'GET',
      agent: false,
      family: 4,
      maxHeaderSize: 16384,
      headers: { Authorization: 'Bearer synthetic-private' },
    });
    const callback = jest.fn();
    options.lookup!('catalog.synthetic.invalid', {}, callback);
    expect(callback).toHaveBeenCalledWith(null, '8.8.8.8', 4);
    expect(req.destroy).toHaveBeenCalled();
    expect(options).not.toHaveProperty('rejectUnauthorized', false);
  });
  it('mixed public/private DNS is rejected before any credential-bearing socket', async () => {
    lookup.mockResolvedValue([
      { address: '8.8.8.8', family: 4 },
      { address: '127.0.0.1', family: 4 },
    ]);
    await expect(read()).rejects.toThrow('安全目录地址');
    expect(send).not.toHaveBeenCalled();
  });
  it('302 is never followed even if its body looks like a successful catalog', async () => {
    res.statusCode = 302;
    res.headers.location = 'https://elsewhere.invalid/models';
    await expect(read()).rejects.toBeInstanceOf(ModelSyncError);
    expect(send).toHaveBeenCalledTimes(1);
    expect(req.destroy).toHaveBeenCalled();
    expect(res.destroy).toHaveBeenCalled();
  });
  it('oversized and malformed responses fail without returning partial data', async () => {
    body = 'x'.repeat(1024 * 1024 + 1);
    await expect(read()).rejects.toThrow('安全限制');
    expect(req.destroy).toHaveBeenCalled();
    body = 'synthetic SQL/token-not-json';
    await expect(read()).rejects.toThrow('模型目录获取失败');
  });
  it('abort closes an in-flight body request; late DNS after cancellation opens no socket', async () => {
    body = null;
    const abort = new AbortController();
    const pending = read(abort.signal);
    await new Promise((resolve) => setImmediate(resolve));
    abort.abort();
    await expect(pending).rejects.toBeInstanceOf(ModelSyncError);
    expect(req.destroy).toHaveBeenCalled();
    send.mockClear();
    let release!: (value: unknown) => void;
    lookup.mockReturnValue(new Promise((resolve) => (release = resolve)));
    const second = new AbortController();
    const waiting = read(second.signal);
    second.abort();
    await expect(waiting).rejects.toBeInstanceOf(ModelSyncError);
    release([{ address: '8.8.8.8', family: 4 }]);
    await new Promise((resolve) => setImmediate(resolve));
    expect(send).not.toHaveBeenCalled();
  });
});
