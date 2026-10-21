import { ExecutionContext, ForbiddenException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { Request } from 'express';
import type { Server } from 'node:http';

type OcrTestRequest = Request & {
  user?: { userId: number; role: string };
};
import { AdminGuard } from '../auth/admin.guard';
import { OcrAdminController } from './ocr-admin.controller';
import { OcrService } from './ocr.service';
jest.mock('../auth/jwt.const', () => ({ JWT_SECRET: 'ocr-admin-test-only' }));

describe('OCR admin authorization and settings boundary', () => {
  let app: INestApplication;
  const relay = jest.fn(() => Promise.resolve({ counts: { completed: 1 } }));
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [OcrAdminController],
      providers: [{ provide: OcrService, useValue: { request: relay } }],
    })
      .overrideGuard(AdminGuard)
      .useValue({
        canActivate(context: ExecutionContext) {
          const req = context.switchToHttp().getRequest<OcrTestRequest>();
          if (req.headers.authorization !== 'admin-test')
            throw new ForbiddenException();
          req.user = { userId: 7, role: 'admin' };
          return true;
        },
      })
      .compile();
    app = module.createNestApplication({ logger: false });
    await app.init();
    await app.listen(0, '127.0.0.1');
  });
  afterAll(() => app.close());
  beforeEach(() => relay.mockClear());
  it('ordinary users cannot read or change OCR settings', async () => {
    await request(app.getHttpServer() as Server)
      .get('/uapi/admin/ocr/overview')
      .set('Authorization', 'user-test')
      .expect(403);
    await request(app.getHttpServer() as Server)
      .patch('/uapi/admin/ocr/settings')
      .send({})
      .expect(403);
    expect(relay).not.toHaveBeenCalled();
  });
  it('uses verified admin owner and validates configuration before relaying', async () => {
    await request(app.getHttpServer() as Server)
      .get('/uapi/admin/ocr/overview')
      .set('Authorization', 'admin-test')
      .expect(200);
    expect(relay).toHaveBeenCalledWith('admin:7', '/admin/overview');
    const settings = {
      ownerHourly: 20,
      globalHourly: 120,
      ownerOverrides: { 'user:12': 0 },
    };
    await request(app.getHttpServer() as Server)
      .patch('/uapi/admin/ocr/settings')
      .set('Authorization', 'admin-test')
      .send(settings)
      .expect(200);
    expect(relay).toHaveBeenLastCalledWith(
      'admin:7',
      '/admin/settings',
      'PUT',
      Buffer.from(JSON.stringify(settings)),
    );
    relay.mockClear();
    for (const body of [
      { ...settings, ownerHourly: -1 },
      { ...settings, globalHourly: 1001 },
      { ...settings, ownerOverrides: { 'user:12': true } },
      { ...settings, arbitrary: 'unsafe' },
    ]) {
      await request(app.getHttpServer() as Server)
        .patch('/uapi/admin/ocr/settings')
        .set('Authorization', 'admin-test')
        .send(body)
        .expect(400);
    }
    expect(relay).not.toHaveBeenCalled();
  });
});
