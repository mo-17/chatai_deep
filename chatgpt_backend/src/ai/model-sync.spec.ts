import { Logger, ValidationPipe, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { DataSource, Repository } from 'typeorm';
import request from 'supertest';
import type { Server } from 'node:http';
import { AdminGuard } from '../auth/admin.guard';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { ProviderCacheService } from './provider-cache.service';
import { AdminModelSyncController } from './admin-model-sync.controller';
import { AdminModelSyncService } from './admin-model-sync.service';
import {
  catalogEndpoint,
  catalogPage,
  isCatalogPublicAddress,
  ModelCatalogTransport,
  ModelSyncError,
} from './model-discovery';
import { AllExceptionsFilter } from '../common/all-exceptions.filter';

const principal = { userId: 7, bearer: 'Bearer synthetic-admin-a' };
function provider(id = 1): AiProvider {
  return {
    id,
    code: `provider-${id}`,
    displayName: 'Synthetic',
    baseUrl: 'https://catalog.synthetic.invalid/v1',
    apiKey: 'synthetic-secret',
    enabled: true,
    updateTime: new Date(0),
  } as AiProvider;
}
function gate() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => (release = resolve));
  return { promise, release };
}

describe('model sync: synthetic repositories and actual Nest HTTP only', () => {
  let providers: AiProvider[];
  let models: AiModel[];
  let service: AdminModelSyncService;
  let get: jest.MockedFunction<ModelCatalogTransport['get']>;
  let invalidate: jest.Mock;
  let app: INestApplication;
  let server: Server;
  let transactions: number;
  let networkDuringTransaction: boolean;
  let saveFailure: boolean;
  let locks: unknown[];
  let errorLog: jest.SpyInstance;
  beforeEach(async () => {
    errorLog = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => {});
    providers = [provider(), provider(2)];
    models = [];
    transactions = 0;
    networkDuringTransaction = false;
    saveFailure = false;
    locks = [];
    get = jest.fn(
      (
        _url: URL,
        _headers: Record<string, string>,
        _signal: AbortSignal,
      ): Promise<unknown> => {
        networkDuringTransaction ||= transactions > 0;
        return Promise.resolve({ data: [{ id: 'new-model' }] });
      },
    );
    invalidate = jest.fn();
    let tail = Promise.resolve();
    const dataSource = {
      transaction: async (action: (manager: unknown) => Promise<unknown>) => {
        // 仅内存协作锁；不将此测试称 PostgreSQL 并发/事务证明。
        const previous = tail;
        const next = gate();
        tail = next.promise;
        await previous;
        const saved = structuredClone(models);
        transactions++;
        interface Builder {
          rows: AiModel[];
          ignoreConflicts: boolean;
          insert(): Builder;
          into(entity: typeof AiModel): Builder;
          values(rows: AiModel[]): Builder;
          orIgnore(): Builder;
          returning(fields: string[]): Builder;
          execute(): Promise<{ raw: Array<{ modelId: string }> }>;
        }
        const builder: Builder = {
          rows: [],
          ignoreConflicts: false,
          insert(this: Builder) {
            return this;
          },
          into(this: Builder, entity) {
            expect(entity).toBe(AiModel);
            return this;
          },
          values(this: Builder, rows) {
            this.rows = rows;
            return this;
          },
          orIgnore(this: Builder) {
            this.ignoreConflicts = true;
            return this;
          },
          returning(this: Builder, fields) {
            expect(fields).toEqual(['modelId']);
            return this;
          },
          execute(this: Builder) {
            const raw: Array<{ modelId: string }> = [];
            for (const row of this.rows) {
              const duplicate = models.some(
                (m) =>
                  m.providerId === row.providerId && m.modelId === row.modelId,
              );
              if (duplicate) {
                if (!this.ignoreConflicts)
                  throw Error('synthetic unique constraint');
                continue;
              }
              models.push({ ...row, id: models.length + 1 });
              raw.push({ modelId: row.modelId });
            }
            if (saveFailure) throw Error('synthetic SQL bind secret');
            return Promise.resolve({ raw });
          },
        };
        try {
          return await action({
            findOne: (
              _entity: unknown,
              options: { where: { id: number }; lock: unknown },
            ) => {
              locks.push(options.lock);
              return Promise.resolve(
                providers.find((p) => p.id === options.where.id) ?? null,
              );
            },
            createQueryBuilder: () => builder,
          });
        } catch (e) {
          models = saved;
          throw e;
        } finally {
          transactions--;
          next.release();
        }
      },
    } as unknown as DataSource;
    service = new AdminModelSyncService(
      {
        findOne: ({ where }: { where: { id: number } }) =>
          Promise.resolve(
            structuredClone(providers.find((p) => p.id === where.id) ?? null),
          ),
      } as Repository<AiProvider>,
      {
        find: ({ where }: { where: { providerId: number } }) =>
          Promise.resolve(
            structuredClone(
              models.filter((m) => m.providerId === where.providerId),
            ),
          ),
      } as Repository<AiModel>,
      dataSource,
      { get },
      { invalidate } as unknown as ProviderCacheService,
    );
    const module = await Test.createTestingModule({
      controllers: [AdminModelSyncController],
      providers: [
        { provide: AdminModelSyncService, useValue: service },
        AdminGuard,
        {
          provide: TokenAuthenticationService,
          useValue: {
            verify: (token: string) =>
              Promise.resolve(
                token.startsWith('synthetic-admin-')
                  ? { userId: token.endsWith('-b') ? 8 : 7, role: 'admin' }
                  : token === 'synthetic-user'
                    ? { userId: 7, role: 'user' }
                    : null,
              ),
          },
        },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    app.useGlobalFilters(new AllExceptionsFilter());
    app.useGlobalPipes(
      new ValidationPipe({
        whitelist: true,
        forbidNonWhitelisted: true,
        transform: true,
      }),
    );
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer() as Server;
  });
  afterEach(async () => {
    expect(networkDuringTransaction).toBe(false);
    await app.close();
    jest.restoreAllMocks();
  });
  const url = (action: string, id = 1) =>
    `/uapi/admin/ai/providers/${id}/model-sync/${action}`;
  async function preview() {
    return service.preview(1, principal);
  }

  it('real AdminGuard rejects anonymous and nonadmin before catalog access', async () => {
    await request(server).post(url('preview')).expect(401);
    await request(server)
      .post(url('preview'))
      .set('Authorization', 'Bearer synthetic-user')
      .expect(403);
    expect(get).not.toHaveBeenCalled();
  });
  it('HTTP preview is projected and has zero writes; explicit confirm inserts disabled nondefault rows', async () => {
    get.mockResolvedValue({
      data: [
        {
          id: 'new-model',
          name: 'New model',
          apiKey: 'synthetic-extra-secret',
          price: 9000,
          input_modalities: ['text', 'image'],
          effort: { supported_levels: ['high'] },
          context_window: 1000,
        },
      ],
    });
    const response = await request(server)
      .post(url('preview'))
      .set('Authorization', principal.bearer)
      .expect(201);
    const body = response.body as {
      data: Awaited<ReturnType<AdminModelSyncService['preview']>>;
    };
    expect(JSON.stringify(response.body)).not.toMatch(
      /synthetic.*secret|price|baseUrl/,
    );
    expect(models).toEqual([]);
    expect(body.data.rows[0]).toMatchObject({
      modelId: 'new-model',
      status: 'new',
      supportsVision: true,
      supportsReasoning: true,
      contextWindow: 1000,
    });
    await request(server)
      .post(url('import'))
      .set('Authorization', principal.bearer)
      .send({
        previewId: body.data.previewId,
        modelIds: ['new-model'],
      })
      .expect(201);
    expect(models).toEqual([
      expect.objectContaining({
        providerId: 1,
        modelId: 'new-model',
        enabled: false,
        isDefault: false,
        supportsVision: true,
      }),
    ]);
    expect(models[0]).not.toHaveProperty('inputPrice');
    expect(invalidate).toHaveBeenCalledTimes(1);
    expect(locks).toEqual([{ mode: 'pessimistic_write' }]);
  });
  it('existing manual fields/defaults and absent models are preserved; same ID at another provider is new', async () => {
    models = [
      {
        id: 1,
        providerId: 1,
        modelId: 'keep',
        displayName: 'Manual',
        enabled: true,
        isDefault: true,
        inputPrice: 12,
        supportsVision: true,
      } as AiModel,
      {
        id: 2,
        providerId: 1,
        modelId: 'absent',
        displayName: 'Absent',
        enabled: false,
      } as AiModel,
      {
        id: 3,
        providerId: 2,
        modelId: 'same',
        displayName: 'Other provider',
      } as AiModel,
    ];
    const before = structuredClone(models);
    get.mockResolvedValue({
      data: [
        { id: 'keep', name: 'Upstream', input_modalities: ['text'] },
        { id: 'same' },
      ],
    });
    const p = await preview();
    expect(p.rows[0]).toMatchObject({
      status: 'changed',
    });
    expect(p.rows[0].changes).toEqual(
      expect.arrayContaining(['displayName', 'supportsVision']),
    );
    await expect(
      service.import(1, principal, p.previewId, ['keep']),
    ).rejects.toBeInstanceOf(ModelSyncError);
    await service.import(1, principal, p.previewId, ['same']);
    expect(models.slice(0, 3)).toEqual(before);
    expect(models[3].providerId).toBe(1);
  });
  it('repeated and concurrent explicit import is idempotent under synthetic parent-lock cooperation', async () => {
    const p = await preview();
    const results = await Promise.all([
      service.import(1, principal, p.previewId, ['new-model']),
      service.import(1, principal, p.previewId, ['new-model']),
    ]);
    expect(results.map((r) => r.imported.length).sort()).toEqual([0, 1]);
    expect(models).toHaveLength(1);
    expect(invalidate).toHaveBeenCalledTimes(1);
    expect(
      (await service.import(1, principal, p.previewId, ['new-model'])).skipped,
    ).toEqual(['new-model']);
  });
  it('does not overwrite a model created/edited after preview', async () => {
    const p = await preview();
    const current = {
      id: 1,
      providerId: 1,
      modelId: 'new-model',
      displayName: 'Concurrent manual',
      enabled: true,
      isDefault: true,
      inputPrice: 123,
    } as AiModel;
    models.push(current);
    expect(
      (await service.import(1, principal, p.previewId, ['new-model'])).imported,
    ).toEqual([]);
    expect(models).toEqual([current]);
    expect(invalidate).not.toHaveBeenCalled();
  });
  it('binds preview to original owner and Bearer and provider; unknown IDs cannot be imported', async () => {
    const p = await preview();
    for (const [id, owner, ids] of [
      [1, { userId: 8, bearer: 'Bearer synthetic-admin-b' }, ['new-model']],
      [1, { userId: 7, bearer: 'Bearer synthetic-admin-new' }, ['new-model']],
      [2, principal, ['new-model']],
      [1, principal, ['injected']],
    ] as const)
      await expect(
        service.import(id, owner, p.previewId, [...ids]),
      ).rejects.toBeInstanceOf(ModelSyncError);
    expect(models).toEqual([]);
  });
  it.each(['apiKey', 'baseUrl', 'code', 'updateTime'] as const)(
    'rejects changed provider %s and deletion before import',
    async (key) => {
      const p = await preview();
      Object.assign(providers[0], {
        [key]: key === 'updateTime' ? new Date(1) : 'changed',
      });
      await expect(
        service.import(1, principal, p.previewId, ['new-model']),
      ).rejects.toThrow('服务商配置已变化');
      expect(models).toEqual([]);
    },
  );
  it('expiry, malformed DTO and empty/duplicate selections write nothing', async () => {
    const p = await preview();
    for (const body of [
      { previewId: p.previewId, modelIds: [] },
      { previewId: p.previewId, modelIds: ['new-model', 'new-model'] },
      {
        previewId: p.previewId,
        modelIds: ['new-model'],
        baseUrl: 'https://attacker.invalid',
      },
      { previewId: 'bad', modelIds: ['new-model'] },
    ])
      await request(server)
        .post(url('import'))
        .set('Authorization', principal.bearer)
        .send(body)
        .expect(400);
    const clock = jest.spyOn(Date, 'now').mockReturnValue(p.expiresAt);
    await expect(
      service.import(1, principal, p.previewId, ['new-model']),
    ).rejects.toThrow('预览已过期');
    clock.mockRestore();
    expect(models).toEqual([]);
  });
  it('failed commit path rolls back synthetic writes and does not invalidate cache or expose SQL', async () => {
    const p = await preview();
    saveFailure = true;
    const response = await request(server)
      .post(url('import'))
      .set('Authorization', principal.bearer)
      .send({ previewId: p.previewId, modelIds: ['new-model'] })
      .expect(503);
    expect(response.body).toMatchObject({
      safeCode: 'model_sync_import_unknown',
    });
    expect(JSON.stringify(response.body)).not.toContain('SQL');
    expect(models).toEqual([]);
    expect(invalidate).not.toHaveBeenCalled();
  });
  it('empty discovery is a read-only successful preview; malformed or duplicate rows cannot create a partial preview', async () => {
    get.mockResolvedValueOnce({ data: [] });
    expect((await preview()).rows).toEqual([]);
    for (const data of [
      { data: [{ id: 'valid' }, { id: ' ' }] },
      { data: [{ id: 'a' }, { id: 'a' }] },
      { data: null },
      { data: [{ id: 'a' }], has_more: true },
    ]) {
      get.mockResolvedValueOnce(data);
      await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    }
    expect(models).toEqual([]);
  });
  it('uses bounded native pagination, keeps credentials only in correct headers and never consumes supplied URL fields', async () => {
    providers[0].baseUrl = 'https://api.anthropic.com';
    get
      .mockResolvedValueOnce({
        data: [{ id: 'claude-a', display_name: 'A' }],
        has_more: true,
        last_id: 'cursor/?unsafe=x',
      })
      .mockResolvedValueOnce({
        data: [{ id: 'claude-b' }],
        has_more: false,
        next: 'https://attacker.invalid',
      });
    const p = await preview();
    expect(p.rows).toHaveLength(2);
    expect(get.mock.calls[1][0].origin).toBe('https://api.anthropic.com');
    expect(get.mock.calls[1][0].searchParams.get('after_id')).toBe(
      'cursor/?unsafe=x',
    );
    expect(get.mock.calls[0][1]).toEqual({
      'x-api-key': 'synthetic-secret',
      'anthropic-version': '2023-06-01',
    });
    providers[0].baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';
    get.mockReset();
    get
      .mockResolvedValueOnce({
        models: [
          {
            name: 'models/embed',
            supportedGenerationMethods: ['embedContent'],
          },
          {
            name: 'models/gemini-a',
            supportedGenerationMethods: ['generateContent'],
          },
        ],
        nextPageToken: 'next/?',
      })
      .mockResolvedValueOnce({ models: [] });
    expect((await preview()).rows.map((m) => m.modelId)).toEqual(['gemini-a']);
    expect(get.mock.calls[1][0].pathname).toBe('/v1beta/models');
    expect(get.mock.calls[1][0].searchParams.get('pageToken')).toBe('next/?');
    expect(get.mock.calls[0][1]).toEqual({
      'x-goog-api-key': 'synthetic-secret',
    });
  });
  it('bounds simultaneous discovery and fails closed after shutdown', async () => {
    const held = gate();
    get.mockImplementation(async () => {
      await held.promise;
      return { data: [] };
    });
    const first = preview();
    await new Promise((resolve) => setImmediate(resolve));
    await expect(preview()).rejects.toThrow('模型预览正在进行');
    service.onModuleDestroy();
    held.release();
    await expect(first).rejects.toBeInstanceOf(ModelSyncError);
    await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    expect(models).toEqual([]);
  });
  it('unknown transport errors are generic without upstream body or synthetic credential', async () => {
    get.mockRejectedValue(
      Error('SQL https://credential.invalid synthetic-secret token=private'),
    );
    const result = await request(server)
      .post(url('preview'))
      .set('Authorization', principal.bearer)
      .expect(400);
    expect(result.body).toEqual({
      code: -1,
      statusCode: 400,
      message: '模型目录获取失败，请检查服务商配置后重新预览',
      safeCode: 'model_sync_failed',
    });
    expect(JSON.stringify(errorLog.mock.calls)).not.toMatch(
      /SQL|credential\.invalid|synthetic-secret|token=private/,
    );
  });
  it('actual global+local filter boundary sanitizes unknown exception and query even for router aliases', async () => {
    jest
      .spyOn(service, 'preview')
      .mockRejectedValue(Error('SQL bind synthetic-secret token=private'));
    for (const route of [
      '/uapi/admin/ai/providers/1/model-sync/preview/',
      '/UAPI/ADMIN/AI/PROVIDERS/1/MODEL-SYNC/PREVIEW',
    ]) {
      const result = await request(server)
        .post(route + '?code=synthetic-query-private')
        .set('Authorization', principal.bearer)
        .expect(500);
      expect(result.body).toMatchObject({
        safeCode: 'model_sync_failed',
        message: '模型目录获取失败，请检查服务商配置后重新预览',
      });
      expect(JSON.stringify(result.body)).not.toMatch(
        /synthetic-secret|SQL|token=private|synthetic-query-private/,
      );
    }
    expect(JSON.stringify(errorLog.mock.calls)).not.toMatch(
      /synthetic-secret|SQL|token=private|synthetic-query-private/,
    );
    expect(get).not.toHaveBeenCalled();
  });
  it('total 12s discovery deadline aborts pending transport and leaves zero writes/previews', async () => {
    jest.useFakeTimers();
    try {
      get.mockImplementation(
        (_url: URL, _headers: unknown, signal: AbortSignal) =>
          new Promise((_resolve, reject) =>
            signal.addEventListener(
              'abort',
              () => reject(Error('synthetic timeout secret')),
              { once: true },
            ),
          ),
      );
      const pending = expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
      await jest.advanceTimersByTimeAsync(12001);
      await pending;
      expect(models).toEqual([]);
      expect(invalidate).not.toHaveBeenCalled();
      get.mockResolvedValue({ data: [] });
      expect((await preview()).rows).toEqual([]);
    } finally {
      jest.useRealTimers();
    }
  });
  it('repeated cursor, page bound, malformed later page and reflected credentials never yield a partial preview', async () => {
    providers[0].baseUrl = 'https://api.anthropic.com';
    get.mockResolvedValue({ data: [], has_more: true, last_id: 'repeat' });
    await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    expect(get).toHaveBeenCalledTimes(2);
    get.mockReset();
    let page = 0;
    get.mockImplementation(() =>
      Promise.resolve({
        data: [],
        has_more: true,
        last_id: 'cursor-' + ++page,
      }),
    );
    await expect(preview()).rejects.toThrow('安全限制');
    expect(get).toHaveBeenCalledTimes(10);
    get.mockReset();
    get
      .mockResolvedValueOnce({
        data: [{ id: 'a' }],
        has_more: true,
        last_id: 'next',
      })
      .mockResolvedValueOnce({ data: 'invalid', has_more: false });
    await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    get.mockResolvedValue({
      data: [],
      has_more: true,
      last_id: 'synthetic-secret',
    });
    await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    providers[0].baseUrl = 'https://catalog.synthetic.invalid/v1';
    get.mockResolvedValue({ data: [{ id: 'a', name: 'synthetic-secret' }] });
    await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    expect(models).toEqual([]);
  });
  it('quoted/backslash synthetic credential reflection is rejected without JSON escape bypass', async () => {
    providers[0].apiKey = 'synthetic-"quoted\\secret';
    get.mockResolvedValue({
      data: [{ id: 'model', description: 'echo ' + providers[0].apiKey }],
    });
    await expect(preview()).rejects.toBeInstanceOf(ModelSyncError);
    expect(models).toEqual([]);
  });
  it('bounds aggregate discovered rows and active requests without writing partial results', async () => {
    get.mockResolvedValue({
      data: Array.from({ length: 1001 }, (_, i) => ({ id: 'm' + i })),
    });
    await expect(preview()).rejects.toThrow('安全限制');
    const held = gate();
    get.mockImplementation(async () => {
      await held.promise;
      return { data: [] };
    });
    const first = service.preview(1, principal);
    const second = service.preview(2, principal);
    await new Promise((resolve) => setImmediate(resolve));
    await expect(
      service.preview(1, { userId: 8, bearer: 'Bearer synthetic-other' }),
    ).rejects.toThrow('模型预览正在进行');
    held.release();
    await Promise.all([first, second]);
    expect(models).toEqual([]);
  });
});

describe('directory adapter and public-address boundaries', () => {
  it.each([
    '127.0.0.1',
    '10.1.2.3',
    '169.254.169.254',
    '100.64.0.1',
    '192.168.1.1',
    '0.0.0.0',
    '198.18.0.1',
    '203.0.113.1',
    '224.1.1.1',
    '::1',
    '::ffff:8.8.8.8',
    'fc00::1',
    'fe80::1',
    '2001:db8::1',
  ])('rejects private/reserved address %s', (address) =>
    expect(isCatalogPublicAddress(address)).toBe(false),
  );
  it('permits ordinary global IPv4 and IPv6 only', () => {
    expect(isCatalogPublicAddress('8.8.8.8')).toBe(true);
    expect(isCatalogPublicAddress('2001:4860:4860::8888')).toBe(true);
  });
  it.each([
    'http://api.deepseek.com',
    'https://user:secret@api.deepseek.com',
    'https://api.deepseek.com?key=secret',
    'https://api.deepseek.com#fragment',
    'https://api.deepseek.com:8443',
    'https://api.deepseek.com\n',
  ])('rejects unsafe configured address without sending %s', (raw) =>
    expect(() => catalogEndpoint(raw)).toThrow(ModelSyncError),
  );
  it('uses configured OpenAI-compatible path with original exact model identifiers and no guessed capabilities/prices', () => {
    expect(catalogEndpoint('https://api.deepseek.com').url.href).toBe(
      'https://api.deepseek.com/models',
    );
    expect(catalogEndpoint('https://api.openai.com/v1/').url.href).toBe(
      'https://api.openai.com/v1/models',
    );
    expect(
      catalogPage(
        { data: [{ id: ' exact model ', price: 100, apiKey: 'ignore' }] },
        'openai',
      ).models,
    ).toEqual([
      {
        modelId: ' exact model ',
        displayName: ' exact model ',
        contextWindow: undefined,
        maxOutputTokens: undefined,
      },
    ]);
  });
  it('explicit source metadata adds known bits but does not infer PDF/tool/price from a model name', () => {
    const m = catalogPage(
      {
        data: [
          {
            id: 'vision-pdf-tools-reasoner',
            input_modalities: ['text', 'image'],
            effort: { supported_levels: [] },
            context_window: 2048,
            max_output_tokens: 512,
          },
        ],
      },
      'openai',
    ).models[0];
    expect(m).toMatchObject({
      supportsVision: true,
      contextWindow: 2048,
      maxOutputTokens: 512,
    });
    expect(m.supportsPdf).toBeUndefined();
    expect(m.supportsTool).toBeUndefined();
    expect(m.supportsReasoning).toBeUndefined();
    expect(m).not.toHaveProperty('inputPrice');
  });
});
