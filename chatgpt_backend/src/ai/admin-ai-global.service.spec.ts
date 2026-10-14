import { BadRequestException, ValidationPipe } from '@nestjs/common';
import { Test, type TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { AdminAiGlobalService } from './admin-ai-global.service';
import { AiGlobalConfig } from './ai-global-config.entity';
import { AiModel } from './ai-model.entity';
import { AiProvider } from './ai-provider.entity';
import { ProviderCacheService } from './provider-cache.service';
import { UpdateGlobalDto } from './dto/update-global.dto';
import { ChatService } from '../chat/chat.service';
import { Conversation } from '../chat/conversation.entity';
import { Message } from '../chat/message.entity';
import { Usage } from '../chat/usage.entity';

// 合成内存仓库返回独立实体，模拟 TypeORM 的读取/保存边界，不打开数据库。
class MemoryRepo<T extends { id: number }> {
  failSave = false;
  constructor(public rows: T[]) {}

  create = jest.fn((body: Partial<T>): T => structuredClone(body) as T);
  findOne = jest.fn(({ where }: { where: Partial<T> }) => {
    const row = this.rows.find((candidate) =>
      Object.entries(where).every(
        ([key, value]) => candidate[key as keyof T] === value,
      ),
    );
    return Promise.resolve(row ? structuredClone(row) : null);
  });
  find = jest.fn(({ where }: { where: Partial<T> }) =>
    Promise.resolve(
      structuredClone(
        this.rows.filter((candidate) =>
          Object.entries(where).every(
            ([key, value]) => candidate[key as keyof T] === value,
          ),
        ),
      ),
    ),
  );
  save = jest.fn((body: T): Promise<T> => {
    if (this.failSave)
      return Promise.reject(new Error('synthetic save failure'));
    const next = structuredClone(body);
    this.rows = [...this.rows.filter((row) => row.id !== body.id), next];
    return Promise.resolve(structuredClone(next));
  });
}

function provider(id: number, code: string, enabled = true): AiProvider {
  return Object.assign(new AiProvider(), {
    id,
    code,
    displayName: code,
    enabled,
    apiKey: 'synthetic-key',
    baseUrl: 'https://synthetic.invalid',
    modelPrefixes: null,
    sortOrder: 0,
  });
}

function model(
  id: number,
  providerId: number,
  modelId: string,
  enabled = true,
): AiModel {
  return Object.assign(new AiModel(), {
    id,
    providerId,
    modelId,
    displayName: modelId,
    enabled,
  });
}

describe('AdminAiGlobalService default pair and cache', () => {
  let module: TestingModule;
  let service: AdminAiGlobalService;
  let chat: ChatService;
  let configs: MemoryRepo<AiGlobalConfig>;
  let providers: MemoryRepo<AiProvider>;
  let models: MemoryRepo<AiModel>;
  let cache: ProviderCacheService;
  let fetchSpy: jest.SpyInstance;

  beforeEach(async () => {
    configs = new MemoryRepo([
      Object.assign(new AiGlobalConfig(), {
        id: 1,
        defaultProviderCode: 'a',
        defaultModelId: 'shared-id',
        catalogPublic: true,
        avatarPath: null,
      }),
    ]);
    providers = new MemoryRepo([
      provider(1, 'a'),
      provider(2, 'b'),
      provider(3, 'disabled', false),
    ]);
    models = new MemoryRepo([
      model(11, 1, 'shared-id'), // A 在 B 前面，不能用全表首条同名记录判断 B。
      model(12, 2, 'shared-id'),
      model(13, 2, 'b-only'),
      model(14, 2, 'disabled-model', false),
      model(15, 3, 'disabled-provider-model'),
    ]);
    cache = new ProviderCacheService();
    module = await Test.createTestingModule({
      providers: [
        AdminAiGlobalService,
        ChatService,
        { provide: ProviderCacheService, useValue: cache },
        { provide: getRepositoryToken(AiGlobalConfig), useValue: configs },
        { provide: getRepositoryToken(AiProvider), useValue: providers },
        { provide: getRepositoryToken(AiModel), useValue: models },
        { provide: getRepositoryToken(Usage), useValue: {} },
        { provide: getRepositoryToken(Conversation), useValue: {} },
        { provide: getRepositoryToken(Message), useValue: {} },
      ],
    }).compile();
    service = module.get(AdminAiGlobalService);
    chat = module.get(ChatService);
    fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
      throw new Error('model/network requests are forbidden in this fixture');
    });
    jest.spyOn(console, 'warn').mockImplementation(() => undefined);
  });

  afterEach(async () => {
    expect(fetchSpy).not.toHaveBeenCalled();
    await module.close();
    jest.restoreAllMocks();
  });

  async function update(raw: Record<string, unknown>) {
    // 使用实际生产 DTO 与 transform/whitelist；null 由业务组合校验拒绝。
    const body = (await new ValidationPipe({
      transform: true,
      whitelist: true,
      forbidNonWhitelisted: true,
    }).transform(raw, {
      type: 'body',
      metatype: UpdateGlobalDto,
    })) as UpdateGlobalDto;
    return service.update(body);
  }

  it('saves enabled B plus its same-name model rather than rejecting A first', async () => {
    const result = await update({
      defaultProviderCode: 'b',
      defaultModelId: 'shared-id',
    });
    expect(result.defaultProviderCode).toBe('b');
    expect(result.defaultModelId).toBe('shared-id');
    expect(configs.save).toHaveBeenCalledTimes(1);
  });

  it('provider-only update validates the existing model in the candidate provider', async () => {
    const result = await update({ defaultProviderCode: 'b' });
    expect(result.defaultModelId).toBe('shared-id');
    expect(result.defaultProviderCode).toBe('b');
  });

  it('model-only update validates against the existing provider', async () => {
    configs.rows[0].defaultProviderCode = 'b';
    expect((await update({ defaultModelId: 'b-only' })).defaultModelId).toBe(
      'b-only',
    );
  });

  it.each([
    ['empty provider', { defaultProviderCode: '' }],
    ['null provider', { defaultProviderCode: null }],
    ['blank provider', { defaultProviderCode: '  ' }],
    ['empty model', { defaultModelId: '' }],
    ['null model', { defaultModelId: null }],
    ['blank model', { defaultModelId: '  ' }],
    ['model from another provider', { defaultModelId: 'b-only' }],
    [
      'disabled provider',
      {
        defaultProviderCode: 'disabled',
        defaultModelId: 'disabled-provider-model',
      },
    ],
    [
      'disabled model',
      { defaultProviderCode: 'b', defaultModelId: 'disabled-model' },
    ],
    ['missing provider', { defaultProviderCode: 'missing' }],
  ])(
    'rejects %s without writing configuration or clearing cache',
    async (_, body) => {
      const before = structuredClone(configs.rows);
      cache.set('model:cached', providers.rows[0]);
      await expect(update(body)).rejects.toBeInstanceOf(BadRequestException);
      expect(configs.rows).toEqual(before);
      expect(configs.save).not.toHaveBeenCalled();
      expect(cache.get('model:cached')?.code).toBe('a');
    },
  );

  it('rejects a provider-only change whose retained model is unavailable there', async () => {
    configs.rows[0].defaultModelId = 'b-only';
    configs.rows[0].defaultProviderCode = 'b';
    await expect(update({ defaultProviderCode: 'a' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    expect(configs.save).not.toHaveBeenCalled();
    expect(configs.rows[0].defaultProviderCode).toBe('b');
  });

  it('rejects model-only changes when the existing provider is disabled', async () => {
    configs.rows[0].defaultProviderCode = 'disabled';
    await expect(
      update({ defaultModelId: 'disabled-provider-model' }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(configs.save).not.toHaveBeenCalled();
  });

  it('unrelated catalogPublic PATCH preserves an old invalid pair and undefined DTO fields', async () => {
    configs.rows[0].defaultProviderCode = 'old-unavailable';
    configs.rows[0].defaultModelId = 'old-unavailable-model';
    const result = await update({ catalogPublic: false });
    expect(result.defaultProviderCode).toBe('old-unavailable');
    expect(result.defaultModelId).toBe('old-unavailable-model');
    expect(result.catalogPublic).toBe(false);
    expect(providers.findOne).not.toHaveBeenCalled();
    expect(models.findOne).not.toHaveBeenCalled();
    expect(configs.save).toHaveBeenCalledTimes(1);
  });

  it('invalid first update does not persist a seed row before validation', async () => {
    configs.rows = [];
    await expect(
      update({ defaultProviderCode: 'missing' }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(configs.save).not.toHaveBeenCalled();
    expect(configs.rows).toEqual([]);
  });

  it('successful first update persists the requested valid pair exactly once', async () => {
    configs.rows = [];
    const result = await update({
      defaultProviderCode: 'b',
      defaultModelId: 'b-only',
    });
    expect(result.id).toBe(1);
    expect(result.defaultProviderCode).toBe('b');
    expect(configs.save).toHaveBeenCalledTimes(1);
  });

  it('successful save immediately changes the real resolver cached fallback', async () => {
    expect((await chat.resolveProvider('unmapped-synthetic-model')).code).toBe(
      'a',
    );
    // 保留请求的 modelId；此次仅更新全局配置，不调用上游。
    await update({ defaultProviderCode: 'b', defaultModelId: 'b-only' });
    expect((await chat.resolveProvider('unmapped-synthetic-model')).code).toBe(
      'b',
    );
    expect(cache.get('model:unmapped-synthetic-model')?.code).toBe('b');
  });

  it('failed save retains both configuration and the cached fallback', async () => {
    expect((await chat.resolveProvider('unmapped-synthetic-model')).code).toBe(
      'a',
    );
    const before = structuredClone(configs.rows);
    configs.failSave = true;
    await expect(
      update({ defaultProviderCode: 'b', defaultModelId: 'b-only' }),
    ).rejects.toThrow('synthetic save failure');
    expect(configs.rows).toEqual(before);
    expect(cache.get('model:unmapped-synthetic-model')?.code).toBe('a');
    expect((await chat.resolveProvider('unmapped-synthetic-model')).code).toBe(
      'a',
    );
  });
});
