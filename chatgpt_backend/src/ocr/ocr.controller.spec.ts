import { ExecutionContext, UnauthorizedException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { JwtGuard } from '../auth/jwt.guard';
import { OcrController, OcrUploadInterceptor } from './ocr.controller';
import { OcrService } from './ocr.service';
import { createJsonBodyParser } from '../common/json-body-parser';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { Request } from 'express';
import type { Server } from 'node:http';

type OcrTestRequest = Request & {
  user?: { userId: number; role: string };
};

jest.mock('../auth/jwt.const', () => ({ JWT_SECRET: 'ocr-tests-only' }));

describe('authenticated OCR upload contract', () => {
  let app: INestApplication;
  const relay = jest.fn(() =>
    Promise.resolve({ id: 'a'.repeat(32), state: 'queued' }),
  );
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [OcrController],
      providers: [
        OcrUploadInterceptor,
        { provide: OcrService, useValue: { request: relay } },
      ],
    })
      .overrideGuard(JwtGuard)
      .useValue({
        canActivate(context: ExecutionContext) {
          const req = context.switchToHttp().getRequest<OcrTestRequest>();
          if (!req.headers.authorization) throw new UnauthorizedException();
          req.user = {
            userId: req.headers.authorization === 'two' ? 2 : 1,
            role: 'user',
          };
          return true;
        },
      })
      .compile();
    app = module.createNestApplication({ bodyParser: false, logger: false });
    app.use(createJsonBodyParser());
    await app.init();
    await app.listen(0, '127.0.0.1');
  });
  beforeEach(() => relay.mockClear());
  afterAll(() => app.close());
  const path = '/uapi/ocr/jobs/' + 'a'.repeat(32);
  it('rejects unauthenticated uploads before relaying', async () => {
    await request(app.getHttpServer() as Server)
      .post(path + '?kind=pdf')
      .set('Content-Type', 'application/octet-stream')
      .send(Buffer.from('%PDF-fixture'))
      .expect(401);
    expect(relay).not.toHaveBeenCalled();
  });
  it('uses verified owner and preserves requested PDF page numbers', async () => {
    await request(app.getHttpServer() as Server)
      .post(path + '?kind=pdf&pages=2,5')
      .set('Authorization', 'two')
      .set('Content-Type', 'application/octet-stream')
      .send(Buffer.from('%PDF-fixture'))
      .expect(201);
    expect(relay).toHaveBeenCalledWith(
      'user:2',
      '/jobs/' + 'a'.repeat(32) + '?kind=pdf&pages=2%2C5',
      'PUT',
      Buffer.from('%PDF-fixture'),
    );
  });
  it('rejects oversized files and invalid page selections', async () => {
    await request(app.getHttpServer() as Server)
      .post(path + '?kind=image')
      .set('Authorization', 'one')
      .set('Content-Type', 'application/octet-stream')
      .send(Buffer.alloc(8 * 1024 * 1024 + 1))
      .expect(413);
    await request(app.getHttpServer() as Server)
      .post(path + '?kind=pdf&pages=21')
      .set('Authorization', 'one')
      .set('Content-Type', 'application/octet-stream')
      .send(Buffer.from('%PDF-x'))
      .expect(400);
    expect(relay).not.toHaveBeenCalled();
  });
  it('forwards an explicit preview request and rejects malformed flags', async () => {
    await request(app.getHttpServer() as Server)
      .post(path + '?kind=pdf&preview=true')
      .set('Authorization', 'one')
      .set('Content-Type', 'application/octet-stream')
      .send(Buffer.from('%PDF-fixture'))
      .expect(201);
    expect(relay).toHaveBeenCalledWith(
      'user:1',
      '/jobs/' + 'a'.repeat(32) + '?kind=pdf&preview=true',
      'PUT',
      Buffer.from('%PDF-fixture'),
    );
    relay.mockClear();
    for (const suffix of [
      'preview=false',
      'preview=',
      'preview=true&preview=true',
    ]) {
      await request(app.getHttpServer() as Server)
        .post(path + '?kind=pdf&' + suffix)
        .set('Authorization', 'one')
        .set('Content-Type', 'application/octet-stream')
        .send(Buffer.from('%PDF-fixture'))
        .expect(400);
    }
    expect(relay).not.toHaveBeenCalled();
  });
  it('never treats JSON as a file and rejects unsafe job ids', async () => {
    await request(app.getHttpServer() as Server)
      .post(path + '?kind=image')
      .set('Authorization', 'one')
      .send({ data: 'x' })
      .expect(400);
    await request(app.getHttpServer() as Server)
      .get('/uapi/ocr/jobs/not-valid')
      .set('Authorization', 'one')
      .expect(400);
    expect(relay).not.toHaveBeenCalled();
  });
  it('polls and deletes only within the authenticated owner', async () => {
    await request(app.getHttpServer() as Server)
      .get(path)
      .set('Authorization', 'two')
      .expect(200)
      .expect('Cache-Control', 'no-store');
    await request(app.getHttpServer() as Server)
      .delete(path)
      .set('Authorization', 'two')
      .expect(200);
    expect(relay.mock.calls).toEqual([
      ['user:2', '/jobs/' + 'a'.repeat(32)],
      ['user:2', '/jobs/' + 'a'.repeat(32), 'DELETE'],
    ]);
  });
});
