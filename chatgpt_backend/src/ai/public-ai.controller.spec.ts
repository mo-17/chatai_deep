import {
  UnauthorizedException,
  type ExecutionContext,
  type INestApplication,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import request from 'supertest';
import type { Server } from 'node:http';
import { PublicAiController } from './public-ai.controller';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { AiGlobalConfig } from './ai-global-config.entity';
import { JwtGuard } from '../auth/jwt.guard';

type Row = Record<string, unknown>;
type Options = { where?: Row; select?: string[] };
interface Catalog {
  code: number;
  data: {
    providers: Array<{ code: string; displayName: string }>;
    models: Array<Row & { modelId: string; providerCode: string }>;
    default: { providerCode: string; modelId: string };
    avatarUrl: string | null;
  };
}

// 合成 find 保留实际 where/select 语义；不连接数据库或读真实配置。
function find(rows: Row[], options?: Options): Promise<Row[]> {
  const selected = rows.filter((row) =>
    Object.entries(options?.where ?? {}).every(
      ([key, value]) => row[key] === value,
    ),
  );
  return Promise.resolve(
    selected.map((row) =>
      options?.select
        ? Object.fromEntries(options.select.map((key) => [key, row[key]]))
        : structuredClone(row),
    ),
  );
}
function provider(id: number, code: string, enabled: boolean): Row {
  return {
    id,
    code,
    displayName: code.toUpperCase(),
    enabled,
    apiKey: 'synthetic-private-key',
    baseUrl: 'https://synthetic.invalid',
  };
}
function model(
  id: number,
  providerId: number,
  modelId: string,
  enabled: boolean,
): Row {
  return {
    id,
    providerId,
    modelId,
    displayName: modelId,
    description: 'fixture description',
    enabled,
    isDefault: false,
    sortOrder: id,
    supportsVision: true,
    supportsTool: false,
    supportsReasoning: true,
    supportsPdf: false,
    inputPrice: 900,
  };
}

describe('public catalog enabled provider/model HTTP contract', () => {
  let app: INestApplication;
  let server: Server;
  let providers: Row[];
  let models: Row[];
  let global: Row | null;
  let providerFind: jest.Mock;
  let modelFind: jest.Mock;
  let globalFind: jest.Mock;
  let fetchSpy: jest.SpyInstance;

  beforeEach(async () => {
    providers = [
      provider(1, 'alpha', true),
      provider(2, 'beta', true),
      provider(3, 'disabled', false),
    ];
    models = [
      model(11, 1, 'shared-id', true),
      model(12, 2, 'shared-id', true),
      model(13, 3, 'disabled-only', true),
      model(14, 1, 'disabled-model', false),
      model(15, 999, 'orphan', true),
    ];
    global = {
      id: 1,
      catalogPublic: true,
      defaultProviderCode: 'disabled',
      defaultModelId: 'disabled-only',
      avatarPath: 'fixture.png',
    };
    providerFind = jest.fn((options?: Options) => find(providers, options));
    modelFind = jest.fn((options?: Options) => find(models, options));
    globalFind = jest.fn(() => Promise.resolve(structuredClone(global)));
    const module = await Test.createTestingModule({
      controllers: [PublicAiController],
      providers: [
        {
          provide: getRepositoryToken(AiProvider),
          useValue: { find: providerFind },
        },
        { provide: getRepositoryToken(AiModel), useValue: { find: modelFind } },
        {
          provide: getRepositoryToken(AiGlobalConfig),
          useValue: { findOne: globalFind },
        },
      ],
    })
      .overrideGuard(JwtGuard)
      .useValue({
        canActivate(context: ExecutionContext) {
          const req = context
            .switchToHttp()
            .getRequest<{ headers: Record<string, string> }>();
          if (req.headers.authorization !== 'Bearer synthetic-catalog-fixture')
            throw new UnauthorizedException();
          return true;
        },
      })
      .compile();
    app = module.createNestApplication({ logger: false });
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer() as Server;
    fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
      throw new Error('model or external calls forbidden');
    });
  });
  afterEach(async () => {
    expect(fetchSpy).not.toHaveBeenCalled();
    await app.close();
    jest.restoreAllMocks();
  });
  async function catalog(): Promise<Catalog> {
    const response = await request(server)
      .get('/uapi/ai/catalog')
      .set('Authorization', 'Bearer synthetic-catalog-fixture')
      .expect(200);
    return response.body as Catalog;
  }

  it('excludes enabled models owned by a disabled or missing provider and disabled models', async () => {
    const result = await catalog();
    expect(result.data.models.map((m) => [m.providerCode, m.modelId])).toEqual([
      ['alpha', 'shared-id'],
      ['beta', 'shared-id'],
    ]);
    expect(result.data.providers).toEqual([
      { code: 'alpha', displayName: 'ALPHA' },
      { code: 'beta', displayName: 'BETA' },
    ]);
  });
  it('preserves same modelId under two enabled providers without choosing a routing priority', async () => {
    models = [model(11, 1, 'shared-id', true), model(12, 2, 'shared-id', true)];
    expect((await catalog()).data.models.map((m) => m.providerCode)).toEqual([
      'alpha',
      'beta',
    ]);
  });
  it('keeps the exact safe response envelope, capability fields, default and avatar', async () => {
    models = [model(11, 1, 'shared-id', true)];
    const result = await catalog();
    expect(result).toEqual({
      code: 0,
      data: {
        providers: [
          { code: 'alpha', displayName: 'ALPHA' },
          { code: 'beta', displayName: 'BETA' },
        ],
        models: [
          {
            modelId: 'shared-id',
            displayName: 'shared-id',
            description: 'fixture description',
            providerCode: 'alpha',
            isDefault: false,
            sortOrder: 11,
            supportsVision: true,
            supportsTool: false,
            supportsReasoning: true,
            supportsPdf: false,
          },
        ],
        default: { providerCode: 'disabled', modelId: 'disabled-only' },
        avatarUrl: '/uploads/avatars/fixture.png',
      },
    });
    expect(JSON.stringify(result)).not.toContain('synthetic-private-key');
  });
  it('returns successful empty models/providers when every provider is disabled, without replacing defaults', async () => {
    providers.forEach((p) => {
      p.enabled = false;
    });
    const result = await catalog();
    expect(result.code).toBe(0);
    expect(result.data.providers).toEqual([]);
    expect(result.data.models).toEqual([]);
    expect(result.data.default).toEqual({
      providerCode: 'disabled',
      modelId: 'disabled-only',
    });
  });
  it('keeps enabled providers and envelope when no enabled model exists', async () => {
    models.forEach((m) => {
      m.enabled = false;
    });
    const result = await catalog();
    expect(result.code).toBe(0);
    expect(result.data.models).toEqual([]);
    expect(result.data.providers).toHaveLength(2);
    expect(Object.keys(result.data).sort()).toEqual([
      'avatarUrl',
      'default',
      'models',
      'providers',
    ]);
  });
  it('a second GET returns the changed enabled snapshot rather than the old response', async () => {
    models = [model(11, 1, 'shared-id', true), model(12, 2, 'shared-id', true)];
    const first = await catalog();
    expect(first.data.models).toHaveLength(2);
    providers[0].enabled = false;
    const second = await catalog();
    expect(second.data.models.map((m) => m.providerCode)).toEqual(['beta']);
    expect(first.data.models).toHaveLength(2);
  });
  it('catalogPublic=false stays forbidden and reads no provider/model rows', async () => {
    global!.catalogPublic = false;
    await request(server)
      .get('/uapi/ai/catalog')
      .set('Authorization', 'Bearer synthetic-catalog-fixture')
      .expect(403);
    expect(providerFind).not.toHaveBeenCalled();
    expect(modelFind).not.toHaveBeenCalled();
  });
  it('missing synthetic identity stays guarded with no repository reads', async () => {
    await request(server).get('/uapi/ai/catalog').expect(401);
    expect(globalFind).not.toHaveBeenCalled();
    expect(providerFind).not.toHaveBeenCalled();
    expect(modelFind).not.toHaveBeenCalled();
  });
});
