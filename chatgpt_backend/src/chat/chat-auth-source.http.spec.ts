import {
  Controller,
  Get,
  Post,
  HttpException,
  Logger,
  UseGuards,
  type INestApplication,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import request from 'supertest';
import * as jwt from 'jsonwebtoken';
import type { Server } from 'node:http';
import { JwtGuard } from '../auth/jwt.guard';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { JWT_SECRET } from '../auth/jwt.const';
import { User } from '../user/user.entity';
import { AllExceptionsFilter } from '../common/all-exceptions.filter';
import { SafeUpstreamException } from './upstream-error';

@Controller('uapi')
@UseGuards(JwtGuard)
class SyntheticRoutes {
  @Get('chat/completions')
  upstream() {
    throw new SafeUpstreamException({
      statusCode: 401,
      safeCode: 'authentication_error',
    });
  }
  @Post('chat/completions')
  ordinaryUnauthorizedStatus() {
    throw new HttpException('synthetic-secret-token-code', 401);
  }
  @Get('chat/completions/stream')
  stream() {
    throw new SafeUpstreamException({
      statusCode: 409,
      safeCode: 'model_unavailable',
    });
  }
  @Get('ai/model-selection')
  unknown() {
    throw Error('SQL bind password=synthetic-secret-token-code');
  }
}

describe('R4b production filter authentication source actual HTTP', () => {
  let app: INestApplication;
  const resources: Array<{ closed: boolean }> = [];
  const signed = jwt.sign({ userId: 7, tokenVersion: 0 }, JWT_SECRET, {
    expiresIn: 120,
  });
  let logger: jest.SpyInstance;
  beforeEach(async () => {
    logger = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
    const module = await Test.createTestingModule({
      controllers: [SyntheticRoutes],
      providers: [
        JwtGuard,
        TokenAuthenticationService,
        {
          provide: getRepositoryToken(User),
          useValue: {
            findOne: () =>
              Promise.resolve({
                id: 7,
                role: 'admin',
                userName: 'synthetic',
                banned: false,
                tokenVersion: 0,
              }),
          },
        },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    app.useGlobalFilters(new AllExceptionsFilter());
    await app.listen(0, '127.0.0.1');
  });
  afterEach(async () => {
    const server = app.getHttpServer() as Server;
    await app.close();
    resources.push({ closed: !server.listening });
    logger.mockRestore();
  });
  afterAll(() => {
    expect(resources.every((r) => r.closed)).toBe(true);
    console.info(
      'R4b HTTP owned resources',
      JSON.stringify(resources),
      'synthetic model POST0',
    );
  });
  for (const path of [
    '/uapi/chat/completions',
    '/UAPI/CHAT/COMPLETIONS/STREAM/',
    '/uapi/ai/model-selection/',
  ])
    it(
      'real JwtGuard failure identifies session auth only at ' + path,
      async () => {
        const res = await request(app.getHttpServer() as Server)
          .get(path + '?modelId=synthetic-secret-token-code')
          .expect(401);
        const body = res.body as { authError?: boolean; safeCode?: string };
        expect(body.authError).toBe(true);
        expect(body.safeCode).toBe('authentication_error');
        expect(JSON.stringify(res.body)).not.toContain('synthetic-secret');
        expect(JSON.stringify(logger.mock.calls)).not.toContain(
          'synthetic-secret',
        );
      },
    );
  it('upstream 401 never acquires a session-auth marker', async () => {
    const res = await request(app.getHttpServer() as Server)
      .get('/uapi/chat/completions')
      .set('Authorization', 'Bearer ' + signed)
      .expect(401);
    expect((res.body as { authError?: boolean }).authError).toBeUndefined();
    expect((res.body as { safeCode: string }).safeCode).toBe(
      'authentication_error',
    );
  });
  it('ordinary service HttpException 401 is not a session guard failure', async () => {
    const res = await request(app.getHttpServer() as Server)
      .post('/uapi/chat/completions')
      .set('Authorization', 'Bearer ' + signed)
      .expect(401);
    expect((res.body as { authError?: boolean }).authError).toBeUndefined();
    expect(JSON.stringify(res.body)).not.toContain('synthetic-secret');
    expect(JSON.stringify(logger.mock.calls)).not.toContain('synthetic-secret');
  });
  it('configuration error is finite and does not mark a login failure', async () => {
    const res = await request(app.getHttpServer() as Server)
      .get('/uapi/chat/completions/stream')
      .set('Authorization', 'Bearer ' + signed)
      .expect(409);
    expect((res.body as { authError?: boolean }).authError).toBeUndefined();
    expect((res.body as { safeCode: string }).safeCode).toBe(
      'model_unavailable',
    );
  });
  it('unknown error and query values are hidden at actual alias route', async () => {
    const res = await request(app.getHttpServer() as Server)
      .get('/UAPI/AI/MODEL-SELECTION/?modelId=synthetic-secret-token-code')
      .set('Authorization', 'Bearer ' + signed)
      .expect(500);
    expect((res.body as { authError?: boolean }).authError).toBeUndefined();
    expect(JSON.stringify(res.body)).not.toContain('synthetic-secret');
    expect(JSON.stringify(logger.mock.calls)).not.toContain('synthetic-secret');
  });
});
