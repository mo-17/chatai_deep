import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { Server } from 'node:http';
import { OperationsController } from './operations.controller';
import { OperationsService } from './operations.service';
import { AdminGuard } from '../auth/admin.guard';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
jest.mock('../auth/jwt.const', () => ({
  JWT_SECRET: 'synthetic-test-secret-only-32-characters',
}));

describe('operations access boundary', () => {
  let app: INestApplication;
  const snapshot = jest.fn().mockResolvedValue({ database: { ok: true } });
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [OperationsController],
      providers: [
        AdminGuard,
        { provide: OperationsService, useValue: { snapshot } },
        {
          provide: TokenAuthenticationService,
          useValue: {
            verify: (token: string) =>
              Promise.resolve(
                ['user', 'admin'].includes(token)
                  ? { userId: 1, role: token }
                  : null,
              ),
          },
        },
      ],
    }).compile();
    app = module.createNestApplication();
    await app.init();
  });
  afterAll(async () => {
    await app?.close();
  });
  it('requires admin and disables response caching', async () => {
    const server = app.getHttpServer() as Server;
    await request(server).get('/uapi/admin/operations').expect(401);
    await request(server)
      .get('/uapi/admin/operations')
      .set('Authorization', 'Bearer user')
      .expect(403);
    expect(snapshot).not.toHaveBeenCalled();
    const response = await request(server)
      .get('/uapi/admin/operations')
      .set('Authorization', 'Bearer admin')
      .expect(200);
    expect(response.headers['cache-control']).toBe('no-store');
    expect(
      (response.body as { data: { database: { ok: boolean } } }).data.database
        .ok,
    ).toBe(true);
  });
});
