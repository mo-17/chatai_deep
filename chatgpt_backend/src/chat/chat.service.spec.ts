import { EventEmitter } from 'node:events';
import type { Response as ExpressResponse } from 'express';
import type { ObjectLiteral, Repository } from 'typeorm';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import { ChatService, type CompletionBody } from './chat.service';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { Usage } from './usage.entity';

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T | PromiseLike<T>) => void;
  reject: (reason?: unknown) => void;
};

type Settled<T> = { error: unknown } | { value: T };

type SafeFailure = Error & {
  statusCode?: number;
  safeCode?: string;
  retryAfterSeconds?: number;
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

async function settle<T>(promise: Promise<T>): Promise<Settled<T>> {
  try {
    const value = await promise;
    return { value };
  } catch (error) {
    return { error };
  }
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await Promise.resolve();
  }
  throw new Error('test condition was not reached');
}

class TestResponse extends EventEmitter {
  headersSent = false;
  destroyed = false;
  writableEnded = false;
  statusCode = 200;
  readonly headers = new Map<string, string>();
  readonly chunks: string[] = [];
  abortClientOnEnd: AbortController | undefined;

  status(code: number) {
    this.statusCode = code;
    return this;
  }

  setHeader(name: string, value: string) {
    this.headers.set(name.toLowerCase(), value);
    return this;
  }

  flushHeaders() {
    this.headersSent = true;
  }

  write(chunk: string) {
    this.chunks.push(chunk);
    this.headersSent = true;
    return true;
  }

  end() {
    this.writableEnded = true;
    this.abortClientOnEnd?.abort();
    return this;
  }

  closeFromClient() {
    this.destroyed = true;
    this.emit('close');
  }
}

function provider(overrides: Partial<AiProvider> = {}): AiProvider {
  return Object.assign(new AiProvider(), {
    id: 11,
    code: 'deepseek',
    displayName: 'DeepSeek',
    apiKey: 'provider-key',
    baseUrl: 'https://provider.example/v1',
    modelPrefixes: 'deepseek-',
    enabled: true,
    sortOrder: 0,
    createTime: new Date(0),
    updateTime: new Date(0),
    ...overrides,
  });
}

function repository<T extends ObjectLiteral>(
  members: Partial<Repository<T>> = {},
): Repository<T> {
  return members as Repository<T>;
}

function createService(selectedProvider = provider()) {
  const usageSave = jest.fn().mockResolvedValue(undefined);
  const usageRepo = repository<Usage>({ save: usageSave });
  const resolvedModel = Object.assign(new AiModel(), {
    providerId: selectedProvider.id,
    enabled: true,
  });
  const modelRepo = repository<AiModel>({
    find: jest.fn().mockResolvedValue([resolvedModel]),
    findOne: jest.fn().mockResolvedValue(resolvedModel),
  });
  const providerRepo = repository<AiProvider>({
    findOne: jest.fn().mockResolvedValue(selectedProvider),
  });
  Object.assign(modelRepo, {
    manager: {
      transaction: (_isolation: string, run: (manager: unknown) => unknown) =>
        run({
          getRepository: (entity: unknown) =>
            entity === AiProvider ? providerRepo : modelRepo,
        }),
    },
  });
  const service = new ChatService(
    usageRepo,
    repository<Conversation>(),
    repository<Message>(),
    providerRepo,
    modelRepo,
    repository<AiGlobalConfig>(),
    new ProviderCacheService(),
    {
      admit: (_id: number, body: unknown) =>
        Promise.resolve({ id: null, body }),
      finish: async () => {},
    } as never,
  );
  return { service, usageSave };
}

function response(): ExpressResponse & TestResponse {
  return new TestResponse() as unknown as ExpressResponse & TestResponse;
}

function requestBody(
  overrides: Record<string, unknown> = {},
): CompletionBody & Record<string, unknown> {
  return {
    model: 'deepseek-v4-flash',
    messages: [{ role: 'user', content: 'hello' }],
    request_profile: 'translation',
    reasoning_policy: 'off_if_supported',
    ...overrides,
  };
}

function completeStream(
  service: ChatService,
  userId: number,
  body: CompletionBody,
  res: ExpressResponse,
  clientSignal: AbortSignal,
): Promise<void> {
  return (
    service.completeStream as unknown as (
      userId: number,
      body: CompletionBody,
      res: ExpressResponse,
      clientSignal: AbortSignal,
    ) => Promise<void>
  )(userId, body, res, clientSignal);
}

function installFetch(responseFactory: () => Promise<Response> | Response) {
  let requestInit: RequestInit | undefined;
  const mock = jest.fn(
    (_input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      requestInit = init;
      return Promise.resolve(responseFactory());
    },
  ) as jest.MockedFunction<typeof fetch>;
  global.fetch = mock;
  return {
    get requestInit() {
      return requestInit;
    },
  };
}

function jsonRequestBody(requestInit: RequestInit | undefined) {
  if (typeof requestInit?.body !== 'string') {
    throw new Error('expected fetch body to be a JSON string');
  }
  return JSON.parse(requestInit.body) as Record<string, unknown>;
}

function installPendingStreamFetch() {
  const reads: Array<Deferred<ReadableStreamReadResult<Uint8Array>>> = [];
  let activeRead: Deferred<ReadableStreamReadResult<Uint8Array>> | undefined;
  let upstreamSignal: AbortSignal | undefined;
  const reader = {
    read: jest.fn(() => {
      activeRead = deferred<ReadableStreamReadResult<Uint8Array>>();
      reads.push(activeRead);
      return activeRead.promise;
    }),
    cancel: jest.fn(() => Promise.resolve(undefined)),
    releaseLock: jest.fn(),
  };
  const mock = jest.fn(
    (_input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      upstreamSignal = init?.signal ?? undefined;
      upstreamSignal?.addEventListener(
        'abort',
        () => activeRead?.reject(new DOMException('aborted', 'AbortError')),
        { once: true },
      );
      return Promise.resolve({
        ok: true,
        status: 200,
        headers: new Headers(),
        body: { getReader: () => reader },
      } as unknown as Response);
    },
  ) as jest.MockedFunction<typeof fetch>;
  global.fetch = mock;
  return {
    reads,
    reader,
    get upstreamSignal() {
      return upstreamSignal;
    },
  };
}

const originalFetch = global.fetch;

describe('ChatService upstream transport', () => {
  beforeEach(() => {
    jest.spyOn(console, 'log').mockImplementation(() => undefined);
  });

  afterEach(() => {
    global.fetch = originalFetch;
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it.each(['low', 'high', 'max'] as const)(
    'sends selected effort %s identically in streaming and ordinary requests',
    async (effort) => {
      const { service } = createService();
      const body = requestBody({
        model: 'deepseek-flash',
        request_profile: 'standard',
        reasoning_policy: 'provider_default',
        reasoning_effort: effort,
        tools: [{ type: 'function' }],
        messages: [
          {
            role: 'assistant',
            content: 'old',
            reasoning_content: 'old thought',
          },
          { role: 'user', content: 'continue' },
        ],
      });
      const original = JSON.stringify(body);
      const ordinaryFetch = installFetch(
        () => new Response(JSON.stringify({ choices: [] })),
      );
      await service.complete(7, body);
      const ordinaryBody = jsonRequestBody(ordinaryFetch.requestInit);
      expect(ordinaryBody).toMatchObject({
        messages: body.messages,
        thinking: { type: 'enabled' },
        reasoning_effort: effort,
      });
      expect(ordinaryBody).not.toHaveProperty('reasoning_policy');

      const streamFetch = installFetch(() => new Response('data: [DONE]\n\n'));
      await service.completeStream(7, body, response());
      expect(jsonRequestBody(streamFetch.requestInit)).toEqual({
        ...ordinaryBody,
        stream: true,
        stream_options: { include_usage: true },
      });
      expect(JSON.stringify(body)).toBe(original);
    },
  );

  it.each(['low', 'high', 'max'] as const)(
    'switches ordinary off replies to %s without changing stored history',
    async (effort) => {
      const { service } = createService();
      const offFetch = installFetch(
        () =>
          new Response(
            JSON.stringify({
              choices: [{ message: { content: 'off answer' } }],
            }),
          ),
      );
      await service.complete(7, requestBody());
      expect(jsonRequestBody(offFetch.requestInit).thinking).toEqual({
        type: 'disabled',
      });

      const messages = [
        { role: 'user', content: 'hello' },
        { role: 'assistant', content: 'off answer' },
        { role: 'assistant', content: 'another answer', tool_calls: [] },
        {
          role: 'assistant',
          content: 'old thought',
          reasoning_content: 'kept',
        },
        { role: 'user', content: 'continue with tools' },
      ];
      const body = requestBody({
        request_profile: 'standard',
        reasoning_policy: 'provider_default',
        reasoning_effort: effort,
        tools: [{ type: 'function' }],
        messages,
      });
      const original = JSON.stringify(body);
      const expectedMessages = messages.map((message) =>
        message.role === 'assistant' && message.reasoning_content === undefined
          ? { ...message, reasoning_content: '' }
          : message,
      );
      const ordinaryFetch = installFetch(
        () => new Response(JSON.stringify({ choices: [] })),
      );
      await service.complete(7, body);
      const ordinaryBody = jsonRequestBody(ordinaryFetch.requestInit);
      expect(ordinaryBody).toMatchObject({
        thinking: { type: 'enabled' },
        reasoning_effort: effort,
        messages: expectedMessages,
      });

      const streamFetch = installFetch(() => new Response('data: [DONE]\n\n'));
      await service.completeStream(7, body, response());
      expect(jsonRequestBody(streamFetch.requestInit)).toEqual({
        ...ordinaryBody,
        stream: true,
        stream_options: { include_usage: true },
      });
      expect(JSON.stringify(body)).toBe(original);
      expect(messages[1]).not.toHaveProperty('reasoning_content');
    },
  );

  it('omits selected effort when the explicit policy disables thinking', async () => {
    const { service } = createService();
    const body = requestBody({
      reasoning_effort: 'max',
      tools: [{ type: 'function' }],
      messages: [
        { role: 'assistant', content: 'ordinary off reply' },
        { role: 'user', content: 'continue' },
      ],
    });
    const ordinaryFetch = installFetch(
      () => new Response(JSON.stringify({ choices: [] })),
    );
    await service.complete(7, body);
    const ordinaryBody = jsonRequestBody(ordinaryFetch.requestInit);
    expect(ordinaryBody.thinking).toEqual({ type: 'disabled' });
    expect(ordinaryBody).not.toHaveProperty('reasoning_effort');
    expect(ordinaryBody.messages).toEqual(body.messages);

    const streamFetch = installFetch(() => new Response('data: [DONE]\n\n'));
    await service.completeStream(7, body, response());
    expect(jsonRequestBody(streamFetch.requestInit).thinking).toEqual({
      type: 'disabled',
    });
    expect(jsonRequestBody(streamFetch.requestInit)).not.toHaveProperty(
      'reasoning_effort',
    );
  });

  it('drops selected effort for legacy tool history in both transport modes', async () => {
    const { service } = createService();
    const body = requestBody({
      reasoning_policy: 'provider_default',
      reasoning_effort: 'max',
      messages: [
        { role: 'user', content: 'calculate' },
        { role: 'assistant', content: 'ordinary off reply' },
        { role: 'assistant', content: null, tool_calls: [{ id: 'c' }] },
        { role: 'tool', tool_call_id: 'c', content: '42' },
      ],
    });
    const original = JSON.stringify(body);
    const ordinaryFetch = installFetch(
      () => new Response(JSON.stringify({ choices: [] })),
    );
    await service.complete(7, body);
    const ordinaryBody = jsonRequestBody(ordinaryFetch.requestInit);
    expect(ordinaryBody.thinking).toEqual({ type: 'disabled' });
    expect(ordinaryBody).not.toHaveProperty('reasoning_effort');
    expect(ordinaryBody.messages).toEqual([
      body.messages[0],
      { ...body.messages[1], reasoning_content: '' },
      body.messages[2],
      body.messages[3],
    ]);

    const streamFetch = installFetch(() => new Response('data: [DONE]\n\n'));
    await service.completeStream(7, body, response());
    expect(jsonRequestBody(streamFetch.requestInit)).toEqual({
      ...ordinaryBody,
      stream: true,
      stream_options: { include_usage: true },
    });
    expect(JSON.stringify(body)).toBe(original);
  });

  it.each([
    'deepseek-flash',
    'deepseek-v4-flash',
    'deepseek-v4-flash-vision-exp',
    'deepseek-v4-pro',
  ])(
    'disables thinking for %s legacy history with tools and preserves image parts',
    async (model) => {
      const { service } = createService();
      const installedFetch = installFetch(
        () =>
          new Response(
            JSON.stringify({ choices: [{ message: { content: 'ok' } }] }),
          ),
      );
      const messages = [
        { role: 'assistant', content: 'legacy answer' },
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Describe the image and calculate its area' },
            {
              type: 'image_url',
              image_url: { url: 'data:image/png;base64,AAAA' },
            },
          ],
        },
      ];
      const tools = [{ type: 'function', function: { name: 'calculator' } }];

      await service.complete(
        7,
        requestBody({
          model,
          messages,
          tools,
          reasoning_policy: 'provider_default',
        }),
      );

      expect(jsonRequestBody(installedFetch.requestInit)).toMatchObject({
        model,
        messages,
        tools,
        thinking: { type: 'disabled' },
      });
    },
  );

  it.each(['deepseek-flash', 'deepseek-v4-pro'])(
    'keeps default thinking for a fresh %s tool request',
    async (model) => {
      const { service } = createService();
      const installedFetch = installFetch(
        () => new Response(JSON.stringify({ choices: [] })),
      );
      await service.complete(
        7,
        requestBody({
          model,
          tools: [{ type: 'function' }],
          reasoning_policy: 'provider_default',
        }),
      );
      expect(jsonRequestBody(installedFetch.requestInit)).not.toHaveProperty(
        'thinking',
      );
      expect(jsonRequestBody(installedFetch.requestInit)).not.toHaveProperty(
        'reasoning_effort',
      );
    },
  );

  it.each(['deepseek-flash', 'deepseek-v4-pro'])(
    'replays complete %s reasoning in streaming and ordinary completions',
    async (model) => {
      const { service } = createService();
      const messages = [
        {
          role: 'assistant',
          content: 'original answer',
          reasoning_content: 'original thought',
        },
        { role: 'user', content: 'calculate' },
        {
          role: 'assistant',
          content: '',
          reasoning_content: 'call calculator',
          tool_calls: [{ id: 'c' }],
        },
        { role: 'tool', tool_call_id: 'c', content: '42' },
        { role: 'assistant', content: '42', reasoning_content: '' },
      ];
      const body = requestBody({
        model,
        messages,
        tools: [{ type: 'function' }],
        reasoning_policy: 'provider_default',
      });
      const original = JSON.stringify(body);
      const ordinaryFetch = installFetch(
        () => new Response(JSON.stringify({ choices: [] })),
      );
      await service.complete(7, body);
      expect(jsonRequestBody(ordinaryFetch.requestInit).messages).toEqual(
        messages,
      );
      expect(jsonRequestBody(ordinaryFetch.requestInit)).not.toHaveProperty(
        'thinking',
      );
      const streamFetch = installFetch(() => new Response('data: [DONE]\n\n'));
      await service.completeStream(7, body, response());
      expect(jsonRequestBody(streamFetch.requestInit).messages).toEqual(
        messages,
      );
      expect(jsonRequestBody(streamFetch.requestInit)).not.toHaveProperty(
        'thinking',
      );
      expect(JSON.stringify(body)).toBe(original);
    },
  );

  it.each(['deepseek-flash', 'deepseek-v4-pro'])(
    'falls back for %s when an ordinary historical assistant is missing reasoning',
    async (model) => {
      const { service } = createService();
      const installedFetch = installFetch(
        () => new Response(JSON.stringify({ choices: [] })),
      );
      await service.complete(
        7,
        requestBody({
          model,
          reasoning_policy: 'provider_default',
          tools: [{ type: 'function' }],
          messages: [
            { role: 'assistant', content: 'legacy ordinary answer' },
            { role: 'user', content: 'continue' },
            {
              role: 'assistant',
              content: '',
              reasoning_content: 'valid tool thought',
              tool_calls: [{ id: 'c' }],
            },
            { role: 'tool', tool_call_id: 'c', content: '42' },
          ],
        }),
      );
      expect(jsonRequestBody(installedFetch.requestInit).thinking).toEqual({
        type: 'disabled',
      });
    },
  );

  it.each([
    { code: 'openai', model: 'gpt-4o' },
    { code: 'custom', model: 'deepseek-flash' },
    { code: 'openrouter', model: 'deepseek-v4-pro' },
    { code: 'deepseek', model: 'deepseek-reasoner' },
  ])(
    'strips reasoning for final route $code/$model without changing source',
    async ({ code, model }) => {
      const { service } = createService(provider({ code }));
      const messages = [
        {
          role: 'assistant',
          content: 'old',
          reasoning_content: 'preserve locally',
          tool_calls: [{ id: 'c' }],
        },
        { role: 'tool', tool_call_id: 'c', content: '42' },
      ];
      const body = requestBody({
        model,
        messages,
        reasoning_policy: 'provider_default',
        reasoning_effort: 'max',
      });
      const original = JSON.stringify(body);
      const ordinaryFetch = installFetch(
        () => new Response(JSON.stringify({ choices: [] })),
      );
      await service.complete(7, body);
      const stripped = messages.map((message) => {
        const copy: Record<string, unknown> = { ...message };
        delete copy.reasoning_content;
        return copy;
      });
      expect(jsonRequestBody(ordinaryFetch.requestInit).messages).toEqual(
        stripped,
      );
      expect(jsonRequestBody(ordinaryFetch.requestInit)).not.toHaveProperty(
        'reasoning_effort',
      );
      expect(jsonRequestBody(ordinaryFetch.requestInit)).not.toHaveProperty(
        'thinking',
      );
      const streamFetch = installFetch(() => new Response('data: [DONE]\n\n'));
      await service.completeStream(7, body, response());
      expect(jsonRequestBody(streamFetch.requestInit).messages).toEqual(
        stripped,
      );
      expect(jsonRequestBody(streamFetch.requestInit)).not.toHaveProperty(
        'reasoning_effort',
      );
      expect(jsonRequestBody(streamFetch.requestInit)).not.toHaveProperty(
        'thinking',
      );
      expect(JSON.stringify(body)).toBe(original);
    },
  );

  it('disables thinking in the Flash stream final round with historic tool calls', async () => {
    const { service } = createService();
    const installedFetch = installFetch(() => new Response('data: [DONE]\n\n'));
    const messages = [
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: null, tool_calls: [{ id: 'call_1' }] },
      { role: 'tool', tool_call_id: 'call_1', content: '42' },
    ];

    await service.completeStream(
      7,
      requestBody({
        model: 'deepseek-flash',
        messages,
        reasoning_policy: 'provider_default',
      }),
      response(),
    );

    expect(jsonRequestBody(installedFetch.requestInit)).toMatchObject({
      messages,
      thinking: { type: 'disabled' },
      stream: true,
    });
  });

  it.each([
    { selected: provider(), model: 'deepseek-flash', tools: [] },
    {
      selected: provider(),
      model: 'deepseek-v4-pro',
      tools: [{ type: 'function' }],
    },
    {
      selected: provider({ code: 'custom' }),
      model: 'deepseek-flash',
      tools: [{ type: 'function' }],
    },
  ])(
    'keeps default thinking outside trusted Flash tool requests',
    async ({ selected, model, tools }) => {
      const { service } = createService(selected);
      const installedFetch = installFetch(
        () =>
          new Response(
            JSON.stringify({ choices: [{ message: { content: 'ok' } }] }),
          ),
      );

      await service.complete(
        7,
        requestBody({
          model,
          tools,
          reasoning_policy: 'provider_default',
        }),
      );

      expect(jsonRequestBody(installedFetch.requestInit)).not.toHaveProperty(
        'thinking',
      );
    },
  );

  it('strips semantic and raw lifecycle fields from non-stream upstream body', async () => {
    const { service } = createService(
      provider({ code: 'custom_1', displayName: 'Custom' }),
    );
    const installedFetch = installFetch(
      () =>
        new Response(
          JSON.stringify({
            choices: [{ message: { content: 'ok' } }],
            model: 'deepseek-v4-flash',
          }),
          { status: 200 },
        ),
    );
    const body = requestBody({
      max_tokens: 2048,
      deadline_ms: 300_000,
      idle_timeout_ms: 60_000,
      cancel_token: 'SECRET cancel token',
      provider_code: 'deepseek',
    });

    await service.complete(7, body);

    const upstreamBody = jsonRequestBody(installedFetch.requestInit);
    expect(upstreamBody).toEqual({
      model: 'deepseek-v4-flash',
      messages: [{ role: 'user', content: 'hello' }],
      max_tokens: 2048,
    });
    expect(upstreamBody).not.toHaveProperty('request_profile');
    expect(upstreamBody).not.toHaveProperty('reasoning_policy');
    expect(upstreamBody).not.toHaveProperty('deadline_ms');
    expect(upstreamBody).not.toHaveProperty('cancel_token');
    expect(upstreamBody).not.toHaveProperty('thinking');
  });

  it('strips semantics, applies trusted-provider reasoning, and relays normal SSE once', async () => {
    const { service, usageSave } = createService();
    const sse = [
      'data: {"choices":[{"delta":{"reasoning_content":"plan"}}]}',
      '',
      'data: {"choices":[{"delta":{"content":"answer"}}]}',
      '',
      'data: {"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}',
      '',
      'data: [DONE]',
      '',
    ].join('\n');
    const installedFetch = installFetch(
      () => new Response(sse, { status: 200 }),
    );
    const res = response();
    const client = new AbortController();
    res.abortClientOnEnd = client;
    const body = requestBody({
      deadline_ms: 1,
      cancel_token: 'SECRET',
    });

    await completeStream(service, 7, body, res, client.signal);

    const upstreamBody = jsonRequestBody(installedFetch.requestInit);
    expect(upstreamBody).toEqual({
      model: 'deepseek-v4-flash',
      messages: [{ role: 'user', content: 'hello' }],
      thinking: { type: 'disabled' },
      stream: true,
      stream_options: { include_usage: true },
    });
    const output = res.chunks.join('');
    expect(output).toContain('reasoning_content');
    expect(output).toContain('"content":"answer"');
    expect(output).toContain('"usage"');
    expect(output.match(/data: \[DONE\]/g)).toHaveLength(1);
    expect(output).not.toContain('SECRET');
    expect(res.writableEnded).toBe(true);
    expect(usageSave).toHaveBeenCalledWith({
      userId: 7,
      provider: 'deepseek',
      model: 'deepseek-v4-flash',
      promptTokens: 2,
      completionTokens: 3,
      totalTokens: 5,
    });
  });

  it('treats upstream DONE as terminal even if the provider keeps the socket open', async () => {
    jest.useFakeTimers();
    const { service } = createService();
    const pending = installPendingStreamFetch();
    const client = new AbortController();
    const res = response();
    let settled = false;

    const completion = completeStream(
      service,
      7,
      requestBody(),
      res,
      client.signal,
    ).finally(() => {
      settled = true;
    });
    await waitFor(() => pending.reads.length === 1);

    pending.reads[0].resolve({
      done: false,
      value: new TextEncoder().encode('data: [DONE]\n\n'),
    });
    await waitFor(() => settled || pending.reads.length === 2);
    const settledAtDone = settled;
    if (!settledAtDone) client.abort();
    await settle(completion);

    expect(settledAtDone).toBe(true);
    expect(res.chunks.join('').match(/data: \[DONE\]/g)).toHaveLength(1);
    expect(res.writableEnded).toBe(true);
    expect(pending.reader.cancel).toHaveBeenCalledTimes(1);
    expect(jest.getTimerCount()).toBe(0);
  });

  it.each([
    [
      400,
      { error: { code: 'unknown_parameter' } },
      'unsupported_reasoning_control',
    ],
    [
      400,
      { error: { type: 'unsupported_parameter' } },
      'unsupported_reasoning_control',
    ],
    [
      400,
      { error: { message: 'unknown parameter: thinking' } },
      'invalid_request',
    ],
    [401, { error: { message: 'SECRET auth detail' } }, 'authentication_error'],
    [403, { error: { message: 'SECRET auth detail' } }, 'authentication_error'],
    [429, { error: { message: 'SECRET rate detail' } }, 'rate_limited'],
    [503, { error: { message: 'SECRET server detail' } }, 'server_error'],
    [418, { error: { message: 'SECRET teapot detail' } }, 'request_failed'],
  ])(
    'maps upstream HTTP %s to safe code %s without forwarding its message',
    async (statusCode, payload, expectedCode) => {
      jest.useFakeTimers();
      const { service } = createService();
      installFetch(
        () =>
          new Response(JSON.stringify(payload), {
            status: statusCode,
          }),
      );

      const result = await settle(service.complete(7, requestBody()));

      expect(result).toHaveProperty('error');
      const error = (result as { error: SafeFailure }).error;
      expect(error.statusCode).toBe(statusCode);
      expect(error.safeCode).toBe(expectedCode);
      expect(String(error)).not.toContain('SECRET');
      expect(String(error)).not.toContain('unknown parameter: thinking');
      expect(jest.getTimerCount()).toBe(0);
    },
  );

  it('keeps an explicit parameter code when no reasoning field was attached', async () => {
    const { service } = createService(
      provider({ code: 'custom_1', displayName: 'Custom' }),
    );
    installFetch(
      () =>
        new Response(
          JSON.stringify({
            error: {
              code: 'unknown_parameter',
              message: 'SECRET unrelated upstream parameter',
            },
          }),
          { status: 400 },
        ),
    );

    const result = await settle(service.complete(7, requestBody()));
    const error = (result as { error: SafeFailure }).error;

    expect(error.statusCode).toBe(400);
    expect(error.safeCode).toBe('unknown_parameter');
    expect(String(error)).not.toContain('SECRET');
  });

  it.each([
    ['0', 1],
    ['12', 12],
    ['999', 120],
    ['-1', undefined],
    ['1.5', undefined],
    ['+2', undefined],
    ['Wed, 21 Oct 2015 07:28:00 GMT', undefined],
  ])(
    'parses decimal Retry-After %s safely as %s seconds',
    async (header, expectedSeconds) => {
      const { service } = createService();
      installFetch(
        () =>
          new Response('{"error":{"message":"SECRET"}}', {
            status: 429,
            headers: { 'Retry-After': header },
          }),
      );

      const result = await settle(service.complete(7, requestBody()));
      const error = (result as { error: SafeFailure }).error;

      expect(error.retryAfterSeconds).toBe(expectedSeconds);
      expect(error.safeCode).toBe('rate_limited');
    },
  );

  it('scrubs network error messages and full URLs from logs and failures', async () => {
    const { service } = createService();
    const secret =
      'SECRET response body from https://provider.example/v1/chat/completions';
    const fetchMock = jest.fn(
      (
        _input: string | URL | Request,
        _init?: RequestInit,
      ): Promise<Response> => Promise.reject(new Error(secret)),
    ) as jest.MockedFunction<typeof fetch>;
    global.fetch = fetchMock;
    const warn = jest
      .spyOn(console, 'warn')
      .mockImplementation(() => undefined);
    const errorLog = jest
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);

    const result = await settle(service.complete(7, requestBody()));
    const failure = (result as { error: SafeFailure }).error;

    expect(failure.safeCode).toBe('request_failed');
    expect(String(failure)).not.toContain(secret);
    expect(JSON.stringify(failure)).not.toContain(secret);
    expect(
      JSON.stringify([warn.mock.calls, errorLog.mock.calls]),
    ).not.toContain(secret);
  });

  it('converts an explicit upstream SSE Thinking incompatibility to safe metadata', async () => {
    const { service } = createService();
    const sse = [
      'event: error',
      'data: {"statusCode":400,"retryAfterSeconds":0,"error":{"type":"unsupported_parameter","message":"SECRET upstream detail"}}',
      '',
    ].join('\n');
    installFetch(() => new Response(sse, { status: 200 }));
    const res = response();

    const result = await settle(
      completeStream(
        service,
        7,
        requestBody(),
        res,
        new AbortController().signal,
      ),
    );

    const error = (result as { error: SafeFailure }).error;
    expect(error.statusCode).toBe(400);
    expect(error.safeCode).toBe('unsupported_reasoning_control');
    expect(error.retryAfterSeconds).toBe(1);
    expect(res.chunks.join('')).not.toContain('SECRET upstream detail');
    expect(res.chunks.join('')).not.toContain('data: [DONE]');
  });

  it('keeps an SSE parameter code when reasoning policy attached no fields', async () => {
    const { service } = createService();
    const sse = [
      'event: error',
      'data: {"statusCode":400,"error":{"type":"unsupported_parameter","message":"SECRET unrelated upstream parameter"}}',
      '',
    ].join('\n');
    installFetch(() => new Response(sse, { status: 200 }));
    const res = response();

    const result = await settle(
      completeStream(
        service,
        7,
        requestBody({ reasoning_policy: 'provider_default' }),
        res,
        new AbortController().signal,
      ),
    );

    const error = (result as { error: SafeFailure }).error;
    expect(error.statusCode).toBe(400);
    expect(error.safeCode).toBe('unsupported_parameter');
    expect(res.chunks.join('')).not.toContain('SECRET');
  });

  it('does not infer reasoning-control fallback without explicit SSE status 400', async () => {
    const { service } = createService();
    const sse = [
      'event: error',
      'data: {"error":{"type":"unsupported_parameter","message":"SECRET missing status"}}',
      '',
    ].join('\n');
    installFetch(() => new Response(sse, { status: 200 }));
    const res = response();

    const result = await settle(
      completeStream(
        service,
        7,
        requestBody(),
        res,
        new AbortController().signal,
      ),
    );

    const error = (result as { error: SafeFailure }).error;
    expect(error.statusCode).toBe(502);
    expect(error.safeCode).toBe('server_error');
    expect(res.chunks.join('')).not.toContain('SECRET');
  });

  it('treats client abort as silent and releases reader, listener, and timers', async () => {
    jest.useFakeTimers();
    const { service } = createService();
    const pending = installPendingStreamFetch();
    const client = new AbortController();
    const addListener = jest.spyOn(client.signal, 'addEventListener');
    const removeListener = jest.spyOn(client.signal, 'removeEventListener');
    const res = response();

    const completion = completeStream(
      service,
      7,
      requestBody(),
      res,
      client.signal,
    );
    await waitFor(() => pending.reads.length === 1);

    client.abort();
    await Promise.resolve();
    const abortedByClient = pending.upstreamSignal?.aborted === true;
    if (!abortedByClient) res.closeFromClient();
    const result = await settle(completion);

    expect(result).toEqual({ value: undefined });
    expect(abortedByClient).toBe(true);
    expect(res.chunks.join('')).not.toContain('data: [DONE]');
    expect(pending.reader.cancel).toHaveBeenCalledTimes(1);
    expect(pending.reader.releaseLock).toHaveBeenCalledTimes(1);
    const abortListener = addListener.mock.calls.find(
      ([event]) => event === 'abort',
    )?.[1];
    expect(abortListener).toEqual(expect.any(Function));
    expect(removeListener).toHaveBeenCalledWith('abort', abortListener);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('preserves first-event timeout kind at the translation deadline', async () => {
    jest.useFakeTimers();
    const { service } = createService();
    const pending = installPendingStreamFetch();
    const res = response();

    const completion = completeStream(
      service,
      7,
      requestBody(),
      res,
      new AbortController().signal,
    );
    await waitFor(() => pending.reads.length === 1);

    jest.advanceTimersByTime(44_999);
    expect(pending.upstreamSignal?.aborted).toBe(false);
    jest.advanceTimersByTime(1);
    await Promise.resolve();
    const abortedAtDeadline = pending.upstreamSignal?.aborted === true;
    if (!abortedAtDeadline) res.closeFromClient();
    const result = await settle(completion);

    expect(abortedAtDeadline).toBe(true);
    const error = (result as { error: SafeFailure }).error;
    expect(error.statusCode).toBe(504);
    expect(error.safeCode).toBe('first_event_timeout');
    expect(res.chunks.join('')).not.toContain('data: [DONE]');
    expect(pending.reader.cancel).toHaveBeenCalledTimes(1);
    expect(pending.reader.releaseLock).toHaveBeenCalledTimes(1);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('resets the translation idle timer for every upstream byte chunk', async () => {
    jest.useFakeTimers();
    const { service } = createService();
    const pending = installPendingStreamFetch();
    const res = response();
    const completion = completeStream(
      service,
      7,
      requestBody(),
      res,
      new AbortController().signal,
    );
    await waitFor(() => pending.reads.length === 1);

    pending.reads[0].resolve({ done: false, value: new Uint8Array([58]) });
    await waitFor(() => pending.reads.length === 2);
    jest.advanceTimersByTime(59_000);
    pending.reads[1].resolve({ done: false, value: new Uint8Array([58]) });
    await waitFor(() => pending.reads.length === 3);

    jest.advanceTimersByTime(59_999);
    expect(pending.upstreamSignal?.aborted).toBe(false);
    jest.advanceTimersByTime(1);
    await Promise.resolve();
    const abortedAtIdle = pending.upstreamSignal?.aborted === true;
    if (!abortedAtIdle) res.closeFromClient();
    const result = await settle(completion);

    expect(abortedAtIdle).toBe(true);
    const error = (result as { error: SafeFailure }).error;
    expect(error.statusCode).toBe(504);
    expect(error.safeCode).toBe('idle_timeout');
    expect(res.chunks.join('')).not.toContain('data: [DONE]');
    expect(jest.getTimerCount()).toBe(0);
  });

  it('preserves total timeout kind for the standard profile deadline', async () => {
    jest.useFakeTimers();
    const { service } = createService();
    const pending = installPendingStreamFetch();
    const res = response();
    const completion = completeStream(
      service,
      7,
      requestBody({ request_profile: 'standard' }),
      res,
      new AbortController().signal,
    );
    await waitFor(() => pending.reads.length === 1);

    jest.advanceTimersByTime(59_999);
    expect(pending.upstreamSignal?.aborted).toBe(false);
    jest.advanceTimersByTime(1);
    await Promise.resolve();
    const abortedAtTotal = pending.upstreamSignal?.aborted === true;
    if (!abortedAtTotal) res.closeFromClient();
    const result = await settle(completion);

    expect(abortedAtTotal).toBe(true);
    const error = (result as { error: SafeFailure }).error;
    expect(error.statusCode).toBe(504);
    expect(error.safeCode).toBe('total_timeout');
    expect(res.chunks.join('')).not.toContain('data: [DONE]');
    expect(jest.getTimerCount()).toBe(0);
  });
});
