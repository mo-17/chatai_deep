import { EventEmitter } from 'node:events';
import type { Response } from 'express';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { ChatController } from './chat.controller';
import { ChatService } from './chat.service';
import type { CompletionBodyDto } from './dto/completion-body.dto';

jest.mock('../auth/jwt.guard', () => ({
  JwtGuard: class JwtGuard {},
}));

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: unknown) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: Deferred<T>['resolve'];
  let reject!: Deferred<T>['reject'];
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

class TestRequest extends EventEmitter {
  readonly user = { userId: 7, userName: 'tester', role: 'user' as const };
  aborted = false;
}

class TestResponse extends EventEmitter {
  headersSent = false;
  destroyed = false;
  writableEnded = false;
  statusCode = 200;
  readonly headers = new Map<string, string>();
  readonly chunks: string[] = [];
  jsonBody: unknown;

  status(code: number) {
    this.statusCode = code;
    return this;
  }

  setHeader(name: string, value: string) {
    this.headers.set(name.toLowerCase(), value);
    return this;
  }

  json(body: unknown) {
    this.jsonBody = body;
    this.headersSent = true;
    this.writableEnded = true;
    return this;
  }

  write(chunk: string) {
    this.chunks.push(chunk);
    this.headersSent = true;
    return true;
  }

  end() {
    this.writableEnded = true;
    return this;
  }
}

const body = {
  model: 'test-model',
  messages: [],
  request_profile: 'translation',
  reasoning_policy: 'off_if_supported',
} as CompletionBodyDto;

function setup(implementation: (...args: unknown[]) => Promise<void>): {
  controller: ChatController;
  completeStream: jest.SpiedFunction<ChatService['completeStream']>;
} {
  const service = Object.create(ChatService.prototype) as ChatService;
  const completeStream = jest
    .spyOn(service, 'completeStream')
    .mockImplementation(implementation as never);
  return { controller: new ChatController(service), completeStream };
}

function request(): AuthenticatedRequest {
  return new TestRequest() as unknown as AuthenticatedRequest;
}

function response(): Response & TestResponse {
  return new TestResponse() as unknown as Response & TestResponse;
}

describe('ChatController completionsStream lifecycle', () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('turns req aborted into the client signal and removes both listeners', async () => {
    let clientSignal: AbortSignal | undefined;
    const { controller, completeStream } = setup(async (...args) => {
      clientSignal = args[3] as AbortSignal | undefined;
      if (!clientSignal) return;
      await new Promise<void>((resolve) => {
        clientSignal!.addEventListener('abort', () => resolve(), {
          once: true,
        });
      });
    });
    const req = request();
    const res = response();

    const completion = controller.completionsStream(req, body, res);
    await Promise.resolve();
    (req as unknown as EventEmitter).emit('aborted');
    await completion;

    expect(completeStream).toHaveBeenCalledTimes(1);
    expect(clientSignal?.aborted).toBe(true);
    expect((req as unknown as EventEmitter).listenerCount('aborted')).toBe(0);
    expect(res.listenerCount('close')).toBe(0);
  });

  it('turns res close into the client signal and removes both listeners', async () => {
    let clientSignal: AbortSignal | undefined;
    const { controller } = setup(async (...args) => {
      clientSignal = args[3] as AbortSignal | undefined;
      if (!clientSignal) return;
      await new Promise<void>((resolve) => {
        clientSignal!.addEventListener('abort', () => resolve(), {
          once: true,
        });
      });
    });
    const req = request();
    const res = response();

    const completion = controller.completionsStream(req, body, res);
    await Promise.resolve();
    res.destroyed = true;
    res.emit('close');
    await completion;

    expect(clientSignal?.aborted).toBe(true);
    expect((req as unknown as EventEmitter).listenerCount('aborted')).toBe(0);
    expect(res.listenerCount('close')).toBe(0);
  });

  it('installs listeners only for the request lifetime', async () => {
    const gate = deferred<void>();
    const { controller } = setup(async () => gate.promise);
    const req = request();
    const res = response();

    const completion = controller.completionsStream(req, body, res);
    await Promise.resolve();
    expect((req as unknown as EventEmitter).listenerCount('aborted')).toBe(1);
    expect(res.listenerCount('close')).toBe(1);

    gate.resolve(undefined);
    await completion;
    expect((req as unknown as EventEmitter).listenerCount('aborted')).toBe(0);
    expect(res.listenerCount('close')).toBe(0);
  });

  it('does not write an error after the response is destroyed', async () => {
    const gate = deferred<void>();
    const { controller } = setup(async () => {
      await gate.promise;
      throw new Error('SECRET upstream body at https://provider.example/v1');
    });
    const req = request();
    const res = response();
    const status = jest.spyOn(res, 'status');
    const json = jest.spyOn(res, 'json');
    const write = jest.spyOn(res, 'write');
    const end = jest.spyOn(res, 'end');

    const completion = controller.completionsStream(req, body, res);
    await Promise.resolve();
    res.destroyed = true;
    res.emit('close');
    gate.resolve(undefined);
    await completion;

    expect(status).not.toHaveBeenCalled();
    expect(json).not.toHaveBeenCalled();
    expect(write).not.toHaveBeenCalled();
    expect(end).not.toHaveBeenCalled();
  });

  it('returns an allowlisted HTTP failure payload and Retry-After', async () => {
    const failure = Object.assign(new Error('must never be exposed'), {
      statusCode: 429,
      safeCode: 'rate_limited',
      retryAfterSeconds: 12,
    });
    const { controller } = setup(() => Promise.reject(failure));
    const req = request();
    const res = response();

    await controller.completionsStream(req, body, res);

    expect(res.statusCode).toBe(429);
    expect(res.headers.get('retry-after')).toBe('12');
    expect(res.jsonBody).toEqual({
      code: 'upstream_error',
      safeCode: 'rate_limited',
      statusCode: 429,
      retryAfterSeconds: 12,
      message: '上游请求受限',
    });
    expect(JSON.stringify(res.jsonBody)).not.toContain('must never be exposed');
  });

  it('writes only an allowlisted SSE failure after headers were sent', async () => {
    const failure = Object.assign(new Error('SECRET provider message'), {
      statusCode: 400,
      safeCode: 'unsupported_parameter',
    });
    const { controller } = setup(() => Promise.reject(failure));
    const req = request();
    const res = response();
    res.headersSent = true;

    await controller.completionsStream(req, body, res);

    expect(res.chunks).toEqual([
      'event: error\ndata: {"code":"upstream_error","safeCode":"unsupported_parameter","statusCode":400,"message":"上游不支持请求参数"}\n\n',
    ]);
    expect(res.writableEnded).toBe(true);
    expect(res.chunks.join('')).not.toContain('SECRET provider message');
  });
});
