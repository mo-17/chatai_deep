import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { EventEmitter } from 'node:events';
import { createServer, type Server } from 'node:http';
import { join } from 'node:path';
import type { AddressInfo } from 'node:net';
import {
  Logger,
  ValidationPipe,
  type INestApplication,
  type Type,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import * as jwt from 'jsonwebtoken';
import request from 'supertest';
import type { Response as ExpressResponse } from 'express';
import type { Repository } from 'typeorm';
import { AiModel } from '../ai/ai-model.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import { AdminAiProviderService } from '../ai/admin-ai-provider.service';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { JWT_SECRET } from '../auth/jwt.const';
import { User } from '../user/user.entity';
import { AllExceptionsFilter } from '../common/all-exceptions.filter';
import { ChatController } from './chat.controller';
import { ChatService, type CompletionBody } from './chat.service';
import { Usage } from './usage.entity';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { SafeUpstreamException } from './upstream-error';

type Row = Record<string, unknown>;
class MemoryRepo {
  rows: Row[] = [];
  failure?: Error;
  find = jest.fn(({ where }: { where?: Row } = {}) => {
    if (this.failure) return Promise.reject(this.failure);
    return Promise.resolve(
      this.rows
        .filter((row) =>
          Object.entries(where ?? {}).every(([k, v]) => row[k] === v),
        )
        .map((row) => structuredClone(row)),
    );
  });
  findOne = jest.fn(
    async (options: { where: Row }) => (await this.find(options))[0] ?? null,
  );
  save = jest.fn((row: Row) => Promise.resolve(row));
}
interface Call {
  provider: string;
  authorization: string | undefined;
  body: Row;
}
const loadModule = createRequire(__filename);
// 红轮新入口不存在时不注册替身：实际旧 Nest 只能返回 404。
function selectionControllers(): Type[] {
  const path = join(__dirname, '../ai/model-selection.controller.ts');
  if (!existsSync(path)) return [];
  const module = loadModule(path) as { ModelSelectionController: Type };
  return [module.ModelSelectionController];
}
class OpenResponse extends EventEmitter {
  headersSent = true;
  destroyed = false;
  writableEnded = false;
  chunks: string[] = [];
  write(chunk: string) {
    this.chunks.push(chunk);
    return true;
  }
  end() {
    this.writableEnded = true;
  }
}

describe('R1 exact provider/model routing using owned loopback HTTP', () => {
  let app: INestApplication;
  let service: ChatService;
  let providers: MemoryRepo;
  let models: MemoryRepo;
  let global: MemoryRepo;
  let cache: ProviderCacheService;
  let usage: MemoryRepo;
  const upstreams: Server[] = [];
  const urls: string[] = [];
  const calls: Call[] = [];
  const resources: Array<{ kind: string; port: number; closed: boolean }> = [];
  let applicationResource: { kind: string; port: number; closed: boolean };
  const token = jwt.sign(
    { userId: 17, userName: 'synthetic', tokenVersion: 0 },
    JWT_SECRET,
    { expiresIn: 120 },
  );
  let logs: jest.SpyInstance;

  beforeAll(async () => {
    for (const provider of ['alpha', 'beta']) {
      const server = createServer((req, res) => {
        let raw = '';
        req.on('data', (chunk: Buffer) => {
          raw += chunk.toString();
        });
        req.on('end', () => {
          const body = JSON.parse(raw) as Row;
          calls.push({
            provider,
            authorization: req.headers.authorization,
            body,
          });
          res.setHeader('Connection', 'close');
          if (body.stream) {
            res.setHeader('Content-Type', 'text/event-stream');
            res.end(
              `data: ${JSON.stringify({ choices: [{ delta: { content: provider } }], usage: { total_tokens: 1 } })}\n\ndata: [DONE]\n\n`,
            );
          } else {
            res.setHeader('Content-Type', 'application/json');
            res.end(
              JSON.stringify({
                choices: [{ message: { content: provider } }],
                usage: { total_tokens: 1 },
              }),
            );
          }
        });
      });
      await new Promise<void>((resolve) =>
        server.listen(0, '127.0.0.1', resolve),
      );
      upstreams.push(server);
      resources.push({
        kind: provider,
        port: (server.address() as AddressInfo).port,
        closed: false,
      });
      urls.push(
        `http://127.0.0.1:${(server.address() as AddressInfo).port}/v1`,
      );
    }
  });
  afterAll(async () => {
    for (const [index, server] of upstreams.entries()) {
      server.closeAllConnections();
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
      resources[index].closed = !server.listening;
    }
    console.info('R1 owned loopback cleanup', JSON.stringify(resources));
    expect(resources.every((resource) => resource.closed)).toBe(true);
  });
  beforeEach(async () => {
    calls.length = 0;
    providers = new MemoryRepo();
    models = new MemoryRepo();
    global = new MemoryRepo();
    usage = new MemoryRepo();
    cache = new ProviderCacheService();
    providers.rows = ['alpha', 'beta'].map((code, i) => ({
      id: i + 1,
      code,
      enabled: true,
      apiKey: `synthetic-${code}-key`,
      baseUrl: urls[i],
      modelPrefixes: 'same,deepseek-',
      displayName: code,
      sortOrder: i,
    }));
    models.rows = [
      { id: 1, providerId: 1, modelId: 'same', enabled: true, isDefault: true },
      { id: 2, providerId: 2, modelId: 'same', enabled: true, isDefault: true },
    ];
    global.rows = [
      {
        id: 1,
        catalogPublic: true,
        defaultProviderCode: 'alpha',
        defaultModelId: 'same',
      },
    ];
    const users = new MemoryRepo();
    users.rows = [
      {
        id: 17,
        userName: 'synthetic',
        banned: false,
        tokenVersion: 0,
        role: 'admin',
      },
    ];
    const syntheticTransactions = {
      transaction: (_isolation: string, run: (manager: unknown) => unknown) =>
        run({
          getRepository: (entity: unknown) =>
            entity === AiProvider ? providers : models,
        }),
    };
    Object.assign(models, { manager: syntheticTransactions });
    const module = await Test.createTestingModule({
      controllers: [ChatController, ...selectionControllers()],
      providers: [
        ChatService,
        TokenAuthenticationService,
        { provide: ProviderCacheService, useValue: cache },
        { provide: getRepositoryToken(AiProvider), useValue: providers },
        { provide: getRepositoryToken(AiModel), useValue: models },
        { provide: getRepositoryToken(AiGlobalConfig), useValue: global },
        { provide: getRepositoryToken(User), useValue: users },
        { provide: getRepositoryToken(Usage), useValue: usage },
        {
          provide: getRepositoryToken(Conversation),
          useValue: new MemoryRepo(),
        },
        { provide: getRepositoryToken(Message), useValue: new MemoryRepo() },
      ],
    }).compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    logs = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
    await app.listen(0, '127.0.0.1');
    applicationResource = {
      kind: 'Nest',
      port: ((app.getHttpServer() as Server).address() as AddressInfo).port,
      closed: false,
    };
    resources.push(applicationResource);
    service = module.get(ChatService);
  });
  afterEach(async () => {
    const server = app?.getHttpServer() as Server | undefined;
    await app?.close();
    if (server) applicationResource.closed = !server.listening;
    logs?.mockRestore();
    jest.restoreAllMocks();
  });

  const payload = (providerCode?: unknown, model = 'same') => ({
    model,
    messages: [{ role: 'user', content: 'synthetic prompt' }],
    ...(providerCode === undefined ? {} : { providerCode }),
  });
  interface Result {
    status: number;
    text: string;
    body: {
      message: string;
      safeCode: string;
      data: { content: string; providerCode: string; modelId: string };
    };
  }
  const post = async (stream: boolean, body: Row): Promise<Result> => {
    const result = await request(app.getHttpServer() as Server)
      .post(`/uapi/chat/completions${stream ? '/stream' : ''}`)
      .set('Authorization', `Bearer ${token}`)
      .send(body);
    return {
      status: result.status,
      text: result.text,
      body: result.body as Result['body'],
    };
  };
  const probe = async (query: Row): Promise<Result> => {
    const result = await request(app.getHttpServer() as Server)
      .get('/uapi/ai/model-selection')
      .set('Authorization', `Bearer ${token}`)
      .query(query);
    return {
      status: result.status,
      text: result.text,
      body: result.body as Result['body'],
    };
  };
  async function rejectEverywhere(
    modelId: string,
    providerCode: string | undefined,
    safeCode: string,
  ) {
    const q = {
      modelId,
      ...(providerCode === undefined ? {} : { providerCode }),
    };
    const results = [
      await post(false, payload(providerCode, modelId)),
      await post(true, payload(providerCode, modelId)),
      await probe(q),
    ];
    for (const result of results) {
      expect(result.status).toBe(409);
      expect(result.body).toMatchObject({ safeCode, statusCode: 409 });
      expect(JSON.stringify(result.body)).not.toMatch(
        /synthetic-.*-key|baseUrl|SELECT|password/,
      );
      expect(result.body).not.toHaveProperty('retryAfterSeconds');
    }
    expect(results[0].body).toEqual(results[1].body);
    expect(results[1].body).toEqual(results[2].body);
    expect(calls).toHaveLength(0);
    expect(usage.save).not.toHaveBeenCalled();
  }
  it.each(['alpha', 'beta'])(
    'explicit same model sends only to %s for normal and stream requests',
    async (code) => {
      const normal = await post(false, payload(code));
      expect(normal.status).toBe(200);
      expect(normal.body.data.content).toBe(code);
      const stream = await post(true, payload(code));
      expect(stream.status).toBe(200);
      expect(stream.text).toContain(`"content":"${code}"`);
      expect(calls).toHaveLength(2);
      for (const call of calls) {
        expect(call.provider).toBe(code);
        expect(call.authorization).toBe(`Bearer synthetic-${code}-key`);
        expect(call.body.model).toBe('same');
        expect(call.body).not.toHaveProperty('providerCode');
      }
      expect(
        usage.save.mock.calls.every(
          ([row]: [Row]) => row.provider === code && row.model === 'same',
        ),
      ).toBe(true);
    },
  );
  it('legacy unique selection resolves and sends to its actual owner', async () => {
    models.rows = [models.rows[1]];
    expect((await post(false, payload())).body.data.content).toBe('beta');
    expect((await probe({ modelId: 'same' })).body).toEqual({
      code: 0,
      data: { providerCode: 'beta', modelId: 'same' },
    });
    expect(calls).toHaveLength(1);
  });
  it('legacy duplicate models remain ambiguous including disabled candidates', async () => {
    models.rows[1].enabled = false;
    providers.rows[1].enabled = false;
    await rejectEverywhere('same', undefined, 'model_ambiguous');
  });
  it('legacy orphan candidate also prevents unique-owner inference', async () => {
    providers.rows.pop();
    await rejectEverywhere('same', undefined, 'model_ambiguous');
  });
  it.each(['missing', 'disabled', 'orphan', 'provider-disabled', 'key'])(
    'legacy unique %s selection is unavailable',
    async (kind) => {
      models.rows = [models.rows[0]];
      if (kind === 'missing') models.rows = [];
      if (kind === 'disabled') models.rows[0].enabled = false;
      if (kind === 'orphan') providers.rows = [];
      if (kind === 'provider-disabled') providers.rows[0].enabled = false;
      if (kind === 'key') providers.rows[0].apiKey = ' ';
      await rejectEverywhere('same', undefined, 'model_unavailable');
    },
  );
  it.each(['missing', 'disabled', 'key'])(
    'explicit provider %s never falls back',
    async (kind) => {
      if (kind === 'missing') providers.rows.shift();
      if (kind === 'disabled') providers.rows[0].enabled = false;
      if (kind === 'key') providers.rows[0].apiKey = '';
      await rejectEverywhere('same', 'alpha', 'provider_unavailable');
    },
  );
  it.each(['missing', 'disabled', 'wrong-owner'])(
    'explicit model %s never falls back',
    async (kind) => {
      if (kind === 'missing') models.rows.shift();
      if (kind === 'disabled') models.rows[0].enabled = false;
      if (kind === 'wrong-owner') models.rows[0].providerId = 2;
      await rejectEverywhere('same', 'alpha', 'model_unavailable');
    },
  );
  it.each(['deepseek-unknown', 'unknown'])(
    'prefix/global defaults never rescue %s',
    async (modelId) => {
      await rejectEverywhere(modelId, undefined, 'model_unavailable');
    },
  );
  it('legacy cache cannot bypass new ambiguity or a disabled exact selection', async () => {
    models.rows = [models.rows[0]];
    expect((await post(false, payload())).status).toBe(200);
    cache.set('model:same', providers.rows[0] as unknown as AiProvider);
    models.rows.push({ id: 2, providerId: 2, modelId: 'same', enabled: false });
    calls.length = 0;
    usage.save.mockClear();
    await rejectEverywhere('same', undefined, 'model_ambiguous');
    providers.rows[0].enabled = false;
    await rejectEverywhere('same', 'alpha', 'provider_unavailable');
  });
  it.each([null, '', ' ', 4, ['alpha'], { code: 'alpha' }])(
    'present invalid providerCode %j is 400, never legacy',
    async (code) => {
      models.rows = [models.rows[0]];
      for (const stream of [false, true])
        expect((await post(stream, payload(code))).status).toBe(400);
      expect(calls).toHaveLength(0);
    },
  );
  it.each(['', ' '])('blank model %j is 400', async (model) => {
    for (const stream of [false, true])
      expect((await post(stream, payload('alpha', model))).status).toBe(400);
    expect(
      (await probe({ modelId: model, providerCode: 'alpha' })).status,
    ).toBe(400);
    expect(calls).toHaveLength(0);
  });
  it('missing model and repeated provider query values are invalid', async () => {
    for (const stream of [false, true])
      expect(
        (await post(stream, { providerCode: 'alpha', messages: [] })).status,
      ).toBe(400);
    expect((await probe({ providerCode: 'alpha' })).status).toBe(400);
    expect(
      (await probe({ modelId: 'same', providerCode: ['alpha', 'beta'] }))
        .status,
    ).toBe(400);
    expect(calls).toHaveLength(0);
  });
  it('identifiers are matched exactly without silently trimming', async () => {
    await rejectEverywhere('same', ' alpha ', 'provider_unavailable');
    await rejectEverywhere(' same ', 'alpha', 'model_unavailable');
  });
  it('production AiModule registers the dedicated selection controller', () => {
    const module = loadModule(join(__dirname, '../ai/ai.module.ts')) as {
      AiModule: Type;
    };
    const controllers = Reflect.getMetadata(
      'controllers',
      module.AiModule,
    ) as Type[];
    expect(controllers.map((controller) => controller.name)).toContain(
      'ModelSelectionController',
    );
  });
  it('probe returns only the requested pair and never calls a model', async () => {
    const result = await probe({ providerCode: 'beta', modelId: 'same' });
    expect(result.status).toBe(200);
    expect(result.body).toEqual({
      code: 0,
      data: { providerCode: 'beta', modelId: 'same' },
    });
    expect(calls).toHaveLength(0);
    expect(usage.save).not.toHaveBeenCalled();
  });
  it('probe requires actual JWT guard authentication', async () => {
    const server = app.getHttpServer() as Server;
    expect(
      (
        await request(server)
          .get('/uapi/ai/model-selection')
          .query({ modelId: 'same' })
      ).status,
    ).toBe(401);
    expect(
      (
        await request(server)
          .get('/uapi/ai/model-selection')
          .set('Authorization', 'Bearer guest-mode')
          .query({ modelId: 'same' })
      ).status,
    ).toBe(401);
    expect(calls).toHaveLength(0);
    expect(models.find).not.toHaveBeenCalled();
  });
  it('closed catalog rejects probe with 403 but does not block explicit completion', async () => {
    global.rows[0].catalogPublic = false;
    const result = await probe({ providerCode: 'alpha', modelId: 'same' });
    expect(result.status).toBe(403);
    expect(result.body.message).toContain('模型清单暂不对外开放');
    expect(models.find).not.toHaveBeenCalled();
    expect(calls).toHaveLength(0);
    expect((await post(false, payload('beta'))).status).toBe(200);
    expect(calls[0].provider).toBe('beta');
  });
  it('probe success grants no permission to send after model disable', async () => {
    expect(
      (await probe({ providerCode: 'alpha', modelId: 'same' })).status,
    ).toBe(200);
    models.rows[0].enabled = false;
    expect((await post(false, payload('alpha'))).body.safeCode).toBe(
      'model_unavailable',
    );
    expect(calls).toHaveLength(0);
  });
  it('configuration errors retain their safe classification after SSE headers', async () => {
    const exception = new SafeUpstreamException({
      statusCode: 409,
      safeCode: 'model_ambiguous',
    });
    const spy = jest
      .spyOn(service, 'completeStream')
      .mockRejectedValue(exception);
    const res = new OpenResponse();
    const req = Object.assign(new EventEmitter(), {
      user: { userId: 17 },
      aborted: false,
    });
    await new ChatController(service).completionsStream(
      req as never,
      payload('alpha') as CompletionBody,
      res as unknown as ExpressResponse,
    );
    expect(res.chunks.join('')).toContain('"safeCode":"model_ambiguous"');
    expect(res.chunks.join('')).toContain('多个服务商');
    expect(res.writableEnded).toBe(true);
    expect(calls).toHaveLength(0);
    spy.mockRestore();
  });
  it('unknown SQL/network errors and supplied values remain hidden in response and logs', async () => {
    models.failure = new Error(
      'SELECT bind synthetic-secret password synthetic-token code=synthetic-code',
    );
    const result = await post(false, payload('alpha'));
    expect(result.status).toBe(500);
    expect(JSON.stringify(result.body)).not.toMatch(
      /SELECT|synthetic-secret|synthetic-token|synthetic-code|password/,
    );
    const selection = await probe({
      modelId: 'same',
      providerCode: 'alpha',
      token: 'synthetic-query-token',
    });
    expect(selection.status).toBe(500);
    expect(JSON.stringify(logs.mock.calls)).not.toMatch(
      /SELECT|synthetic-secret|synthetic-token|synthetic-code|synthetic-query-token|password/,
    );
    expect(calls).toHaveLength(0);
  });
  it.each(['none', 'disabled', 'duplicates'])(
    'connection test refuses %s provider defaults without transport',
    async (kind) => {
      if (kind === 'none') {
        models.rows[0].isDefault = false;
        providers.rows[0].code = 'deepseek';
      }
      if (kind === 'disabled') models.rows[0].enabled = false;
      if (kind === 'duplicates')
        models.rows.push({
          id: 3,
          providerId: 1,
          modelId: 'other',
          enabled: true,
          isDefault: true,
        });
      const send = jest.spyOn(service, 'callUpstream').mockResolvedValue({});
      const admin = new AdminAiProviderService(
        providers as unknown as Repository<AiProvider>,
        models as unknown as Repository<AiModel>,
        {
          transaction: (
            _isolation: string,
            run: (manager: unknown) => unknown,
          ) =>
            run({
              getRepository: (entity: unknown) =>
                entity === AiProvider ? providers : models,
            }),
        } as never,
        service,
        cache,
      );
      await expect(admin.testConnection(1)).rejects.toThrow('默认模型');
      expect(send).not.toHaveBeenCalled();
      send.mockRestore();
    },
  );
  it.each(['disabled', 'key'])(
    'connection test rejects provider %s before transport',
    async (kind) => {
      if (kind === 'disabled') providers.rows[0].enabled = false;
      if (kind === 'key') providers.rows[0].apiKey = ' ';
      const send = jest.spyOn(service, 'callUpstream').mockResolvedValue({});
      const admin = new AdminAiProviderService(
        providers as unknown as Repository<AiProvider>,
        models as unknown as Repository<AiModel>,
        {
          transaction: (
            _isolation: string,
            run: (manager: unknown) => unknown,
          ) =>
            run({
              getRepository: (entity: unknown) =>
                entity === AiProvider ? providers : models,
            }),
        } as never,
        service,
        cache,
      );
      await expect(admin.testConnection(1)).rejects.toMatchObject({
        statusCode: 409,
        safeCode: 'provider_unavailable',
      });
      expect(send).not.toHaveBeenCalled();
      send.mockRestore();
    },
  );
  it('connection test uses only its explicit valid per-provider default', async () => {
    const send = jest
      .spyOn(service, 'callUpstream')
      .mockResolvedValue({ choices: [{ message: { content: 'synthetic' } }] });
    const admin = new AdminAiProviderService(
      providers as unknown as Repository<AiProvider>,
      models as unknown as Repository<AiModel>,
      {
        transaction: (_isolation: string, run: (manager: unknown) => unknown) =>
          run({
            getRepository: (entity: unknown) =>
              entity === AiProvider ? providers : models,
          }),
      } as never,
      service,
      cache,
    );
    expect((await admin.testConnection(1)).ok).toBe(true);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0].code).toBe('alpha');
    expect(send.mock.calls[0][1].model).toBe('same');
    send.mockRestore();
  });
});
