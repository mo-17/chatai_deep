import { Logger, ValidationPipe, type INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import request from 'supertest';
import * as jwt from 'jsonwebtoken';
import type { Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { ModelSelectionController } from '../ai/model-selection.controller';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { User } from '../user/user.entity';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { JWT_SECRET } from '../auth/jwt.const';
import { ChatController } from './chat.controller';
import { ChatService } from './chat.service';
import { AllExceptionsFilter } from '../common/all-exceptions.filter';

const aliases = [
  '/uapi/ai/model-selection/',
  '/UAPI/AI/MODEL-SELECTION',
  '/uapi/chat/completions/',
  '/UAPI/CHAT/COMPLETIONS',
  '/uapi/chat/completions/stream/',
  '/UAPI/CHAT/COMPLETIONS/STREAM',
];
describe('R1 matched Express aliases retain safe errors over real owned HTTP', () => {
  let app: INestApplication;
  let server: Server;
  let log: jest.SpyInstance;
  let fetchSpy: jest.SpyInstance;
  let resolve: jest.Mock;
  const resources: Array<{ port: number; closed: boolean }> = [];
  const token = jwt.sign(
    { userId: 17, userName: 'synthetic', tokenVersion: 0 },
    JWT_SECRET,
    { expiresIn: 120 },
  );
  const failure = new Error(
    'SELECT SQL bind synthetic-secret synthetic-code synthetic-token password',
  );
  beforeEach(async () => {
    resolve = jest.fn().mockRejectedValue(failure);
    const module = await Test.createTestingModule({
      controllers: [ModelSelectionController, ChatController],
      providers: [
        TokenAuthenticationService,
        {
          provide: ChatService,
          useValue: {
            resolveProvider: resolve,
            complete: resolve,
            completeStream: resolve,
          },
        },
        {
          provide: getRepositoryToken(AiGlobalConfig),
          useValue: {
            findOne: jest.fn().mockResolvedValue({ catalogPublic: true }),
          },
        },
        {
          provide: getRepositoryToken(User),
          useValue: {
            findOne: jest.fn().mockResolvedValue({
              id: 17,
              role: 'admin',
              userName: 'synthetic',
              tokenVersion: 0,
              banned: false,
            }),
          },
        },
      ],
    }).compile();
    app = module.createNestApplication();
    app.useGlobalPipes(
      new ValidationPipe({ whitelist: true, transform: true }),
    );
    app.useGlobalFilters(new AllExceptionsFilter());
    log = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
    fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation(() => {
      throw new Error('model calls forbidden');
    });
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer() as Server;
    resources.push({
      port: (server.address() as AddressInfo).port,
      closed: false,
    });
  });
  afterEach(async () => {
    expect(fetchSpy).not.toHaveBeenCalled();
    await app.close();
    resources[resources.length - 1].closed = !server.listening;
    jest.restoreAllMocks();
  });
  afterAll(() => {
    console.info('R1 alias owned HTTP cleanup', JSON.stringify(resources));
    expect(resources.every((resource) => resource.closed)).toBe(true);
  });
  async function call(path: string, invalid = false) {
    const base = request(server);
    const response = /model-selection/i.test(path)
      ? await base
          .get(path)
          .set('Authorization', `Bearer ${token}`)
          .query({
            modelId: 'same',
            providerCode: invalid
              ? ['synthetic-secret', 'synthetic-code']
              : 'alpha',
            token: 'synthetic-query-token',
          })
      : await base
          .post(path + '?token=synthetic-query-token')
          .set('Authorization', `Bearer ${token}`)
          .send({
            model: 'same',
            messages: [],
            providerCode: invalid ? { value: 'synthetic-secret' } : 'alpha',
          });
    return {
      status: response.status,
      body: response.body as { safeCode?: string; message?: string },
    };
  }
  it.each(aliases)('%s masks unknown errors and query values', async (path) => {
    const result = await call(path);
    expect(resolve).toHaveBeenCalledTimes(1);
    expect(result.status).toBe(/stream/i.test(path) ? 502 : 500);
    expect(JSON.stringify(result.body)).not.toMatch(
      /\bSELECT\b|\bSQL\b|synthetic-secret|synthetic-code|synthetic-token|password/,
    );
    expect(JSON.stringify(log.mock.calls)).not.toMatch(
      /\bSELECT\b|\bSQL\b|synthetic-secret|synthetic-code|synthetic-token|synthetic-query-token|password/,
    );
    expect(result.body.safeCode).toBe(
      /stream/i.test(path) ? 'request_failed' : 'server_error',
    );
  });
  it.each(aliases)(
    '%s validation uses the fixed safeCode contract',
    async (path) => {
      const result = await call(path, true);
      expect(result.status).toBe(400);
      expect(result.body).toMatchObject({
        safeCode: 'invalid_request',
        message: '请求参数无效',
      });
      expect(JSON.stringify(result.body)).not.toMatch(
        /synthetic-secret|synthetic-code|synthetic-query-token/,
      );
      expect(JSON.stringify(log.mock.calls)).not.toMatch(
        /synthetic-secret|synthetic-code|synthetic-query-token/,
      );
      expect(resolve).not.toHaveBeenCalled();
    },
  );
});
