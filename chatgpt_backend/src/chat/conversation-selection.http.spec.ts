import { AccessService } from '../access/access.service';
import { Logger, ValidationPipe, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import type { EntityManager, ObjectLiteral } from 'typeorm';
import request from 'supertest';
import * as jwt from 'jsonwebtoken';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { ChatController } from './chat.controller';
import { ChatService } from './chat.service';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { Usage } from './usage.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import { User } from '../user/user.entity';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { JWT_SECRET } from '../auth/jwt.const';
import { AllExceptionsFilter } from '../common/all-exceptions.filter';

type Envelope = {
  code: number;
  data: Conversation | Conversation[] | null;
  safeCode?: string;
  message?: string;
};
function matches(row: ObjectLiteral, where: ObjectLiteral) {
  return Object.entries(where).every(([key, value]) => row[key] === value);
}
const clone = <T>(value: T): T => structuredClone(value);

describe('R2a conversation selection actual guarded HTTP, synthetic repositories', () => {
  let app: INestApplication;
  let server: Server | undefined;
  let activeResource: { port: number; closed: boolean } | undefined;
  let service: ChatService;
  let fetchSpy: jest.SpyInstance;
  let rows: Conversation[];
  let providers: AiProvider[];
  let models: AiModel[];
  let nextId: number;
  const resources: Array<{ port: number; closed: boolean }> = [];
  const token = (id = 17) =>
    jwt.sign({ userId: id, tokenVersion: 0 }, JWT_SECRET, { expiresIn: 120 });
  const legacy = () =>
    Object.assign(new Conversation(), {
      id: 1,
      userId: 17,
      title: 'history',
      model: 'deleted',
      providerCode: 'deleted-provider',
      createdAt: new Date(1000),
      updatedAt: new Date(2000),
    });

  beforeEach(async () => {
    server = undefined;
    activeResource = undefined;
    rows = [legacy()];
    nextId = 2;
    providers = ['alpha', 'beta', ' exact provider '].map((code, index) =>
      Object.assign(new AiProvider(), {
        id: index + 1,
        code,
        enabled: true,
        apiKey: 'synthetic-private-key',
        baseUrl: 'https://synthetic-provider.invalid/v1',
      }),
    );
    models = providers.map((provider) =>
      Object.assign(new AiModel(), {
        providerId: provider.id,
        modelId: provider.id === 3 ? ' exact model ' : 'same',
        enabled: true,
      }),
    );
    const convRepo = {
      create: (data: Partial<Conversation>) =>
        Object.assign(new Conversation(), data),
      save: (row: Conversation) => {
        const saved = Object.assign(new Conversation(), clone(row), {
          id: nextId++,
          createdAt: new Date(3000),
          updatedAt: new Date(3000),
        });
        rows.push(saved);
        return Promise.resolve(clone(saved));
      },
      find: ({ where, select }: { where: ObjectLiteral; select: string[] }) =>
        Promise.resolve(
          rows
            .filter((row) => matches(row, where))
            .map((row) =>
              Object.fromEntries(
                select.map((key) => [key, row[key as keyof Conversation]]),
              ),
            ),
        ),
      findOne: ({ where }: { where: ObjectLiteral }) =>
        Promise.resolve(clone(rows.find((row) => matches(row, where)) ?? null)),
      update: (where: ObjectLiteral, changes: Partial<Conversation>) => {
        const found = rows.find((row) => matches(row, where));
        if (found) Object.assign(found, clone(changes));
        return Promise.resolve({ affected: found ? 1 : 0 });
      },
    };
    const providerRepo = {
      findOne: ({ where }: { where: ObjectLiteral }) =>
        Promise.resolve(
          clone(providers.find((row) => matches(row, where)) ?? null),
        ),
    };
    const modelRepo = {
      find: ({ where }: { where: ObjectLiteral }) =>
        Promise.resolve(clone(models.filter((row) => matches(row, where)))),
      findOne: ({ where }: { where: ObjectLiteral }) =>
        Promise.resolve(
          clone(models.find((row) => matches(row, where)) ?? null),
        ),
      manager: {
        transaction: (
          _isolation: string,
          action: (manager: EntityManager) => unknown,
        ) =>
          action({
            getRepository: (entity: unknown) =>
              entity === AiProvider ? providerRepo : modelRepo,
          } as EntityManager),
      },
    };
    const module = await Test.createTestingModule({
      controllers: [ChatController],
      providers: [
        ChatService,
        {
          provide: AccessService,
          useValue: {
            admit: (_id: number, body: unknown) =>
              Promise.resolve({ id: null, body }),
            finish: async () => {},
          },
        },
        ProviderCacheService,
        TokenAuthenticationService,
        { provide: getRepositoryToken(Conversation), useValue: convRepo },
        { provide: getRepositoryToken(Message), useValue: {} },
        { provide: getRepositoryToken(Usage), useValue: {} },
        { provide: getRepositoryToken(AiProvider), useValue: providerRepo },
        { provide: getRepositoryToken(AiModel), useValue: modelRepo },
        { provide: getRepositoryToken(AiGlobalConfig), useValue: {} },
        {
          provide: getRepositoryToken(User),
          useValue: {
            findOne: ({ where }: { where: { id: number } }) =>
              Promise.resolve({
                id: where.id,
                role: where.id === 19 ? 'user' : 'admin',
                banned: where.id === 20,
                tokenVersion: 0,
                userName: 'synthetic',
              }),
          },
        },
      ],
    }).compile();
    service = module.get(ChatService);
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
      throw new Error('model calls forbidden in conversation CRUD');
    });
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer() as Server;
    activeResource = {
      port: (server.address() as AddressInfo).port,
      closed: false,
    };
    resources.push(activeResource);
  });
  afterEach(async () => {
    expect(fetchSpy).not.toHaveBeenCalled();
    await app.close();
    if (activeResource && server) activeResource.closed = !server.listening;
    jest.restoreAllMocks();
  });
  afterAll(() => {
    console.info('R2a HTTP owned listeners cleanup', JSON.stringify(resources));
    expect(resources.every((row) => row.closed)).toBe(true);
  });
  const create = (body: ObjectLiteral, id = 17) =>
    request(server!)
      .post('/uapi/chat/conversations')
      .set('Authorization', `Bearer ${token(id)}`)
      .send(body);
  const patch = (body: ObjectLiteral, id = 17, target = 1) =>
    request(server!)
      .patch(`/uapi/chat/conversations/${target}`)
      .set('Authorization', `Bearer ${token(id)}`)
      .send(body);

  it('explicit same-model alpha/beta persist separately and list projects only safe fields', async () => {
    for (const providerCode of ['alpha', 'beta']) {
      const response = await create({ model: 'same', providerCode });
      expect(response.status).toBe(200);
      expect((response.body as Envelope).data).toMatchObject({
        model: 'same',
        providerCode,
      });
    }
    const list = await request(server!)
      .get('/uapi/chat/conversations')
      .set('Authorization', `Bearer ${token()}`);
    expect(list.status).toBe(200);
    expect((list.body as Envelope).data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ model: 'same', providerCode: 'alpha' }),
        expect.objectContaining({ model: 'same', providerCode: 'beta' }),
      ]),
    );
    expect(JSON.stringify(list.body)).not.toMatch(
      /synthetic-private-key|synthetic-provider|userId/,
    );
  });
  it('legacy creation keeps NULL even for ambiguous or missing model and does not resolve', async () => {
    const resolve = jest.spyOn(service, 'resolveProvider');
    for (const model of ['same', 'missing']) {
      const response = await create({ model });
      expect(response.status).toBe(200);
      expect((response.body as Envelope).data).toMatchObject({
        model,
        providerCode: null,
      });
    }
    expect(resolve).not.toHaveBeenCalled();
  });
  it('valid nonblank identifiers are preserved verbatim', async () => {
    const response = await create({
      model: ' exact model ',
      providerCode: ' exact provider ',
    });
    expect(response.status).toBe(200);
    expect((response.body as Envelope).data).toMatchObject({
      model: ' exact model ',
      providerCode: ' exact provider ',
    });
  });
  it.each([
    {},
    { model: '' },
    { model: ' \t ' },
    { model: null },
    { model: 7 },
    { model: 'same', providerCode: null },
    { model: 'same', providerCode: ' ' },
    { model: 'same', providerCode: 7 },
    { model: 'same', providerCode: ['alpha'] },
  ])('invalid create %j has no write', async (body) => {
    const before = clone(rows);
    const response = await create(body);
    expect(response.status).toBe(400);
    expect(rows).toEqual(before);
  });
  it.each([
    'disabled-provider',
    'disabled-model',
    'deleted-model',
    'missing-key',
  ])(
    'explicit unavailable %s cannot use another provider or save',
    async (reason) => {
      if (reason === 'disabled-provider') providers[0].enabled = false;
      if (reason === 'disabled-model') models[0].enabled = false;
      if (reason === 'deleted-model') models.shift();
      if (reason === 'missing-key') providers[0].apiKey = '';
      const before = clone(rows);
      const response = await create({ model: 'same', providerCode: 'alpha' });
      expect(response.status).toBe(409);
      expect((response.body as Envelope).safeCode).toMatch(
        /^(model|provider)_unavailable$/,
      );
      expect(JSON.stringify(response.body)).not.toMatch(
        /synthetic-private-key|synthetic-provider/,
      );
      expect(rows).toEqual(before);
    },
  );
  it('title-only preserves unavailable historical selection and avoids resolver', async () => {
    const resolve = jest.spyOn(service, 'resolveProvider');
    const original = clone(rows[0]);
    const response = await patch({ title: 'renamed' });
    expect(response.status).toBe(200);
    expect(rows[0]).toEqual({ ...original, title: 'renamed' });
    expect(resolve).not.toHaveBeenCalled();
  });
  it('explicit selection PATCH updates just submitted columns and no global/default', async () => {
    const before = clone(rows[0]);
    const response = await patch({
      model: 'same',
      providerCode: 'beta',
      userId: 18,
      apiKey: 'synthetic-forged',
    });
    expect(response.status).toBe(200);
    expect(rows[0]).toEqual({ ...before, model: 'same', providerCode: 'beta' });
    expect(providers.every((row) => row.enabled)).toBe(true);
    expect(JSON.stringify(response.body)).not.toContain('synthetic-forged');
  });
  it.each([
    { model: 'same' },
    { providerCode: 'beta' },
    { model: 'same', providerCode: null },
  ])('partial/NULL PATCH %j does not write', async (body) => {
    const before = clone(rows);
    expect((await patch(body)).status).toBe(400);
    expect(rows).toEqual(before);
  });
  it('another admin cannot change owner selection or list it', async () => {
    const before = clone(rows);
    const resolve = jest.spyOn(service, 'resolveProvider');
    expect(
      (await patch({ model: 'same', providerCode: 'alpha' }, 18)).status,
    ).toBe(404);
    expect(resolve).not.toHaveBeenCalled();
    expect(rows).toEqual(before);
    const list = await request(server!)
      .get('/uapi/chat/conversations')
      .set('Authorization', `Bearer ${token(18)}`);
    expect((list.body as Envelope).data).toEqual([]);
  });
  it('missing conversation cannot be recreated by PATCH', async () => {
    expect((await patch({ title: 'missing' }, 17, 999)).status).toBe(404);
    expect(rows).toHaveLength(1);
  });
  it.each([
    [19, 403],
    [20, 401],
  ])('real AdminGuard rejects principal %s with %s', async (id, status) => {
    expect(
      (await create({ model: 'same', providerCode: 'alpha' }, id)).status,
    ).toBe(status);
    expect(rows).toHaveLength(1);
  });
  it('real JWT verifier rejects missing and unsigned token', async () => {
    for (const authorization of ['', 'Bearer synthetic-invalid']) {
      const result = await request(server!)
        .post('/uapi/chat/conversations')
        .set('Authorization', authorization)
        .send({ model: 'same', providerCode: 'alpha' });
      expect(result.status).toBe(401);
    }
    expect(rows).toHaveLength(1);
  });
});
