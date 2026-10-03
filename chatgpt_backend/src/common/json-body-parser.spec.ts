import { Body, Controller, Post } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import { AllExceptionsFilter } from './all-exceptions.filter';
import { chatJsonBodyLimit, createJsonBodyParser } from './json-body-parser';

@Controller()
class PayloadController {
  @Post([
    'uapi/chat/completions',
    'uapi/chat/completions/stream',
    'uapi/chat/completions/extra',
    'uapi/admin/ai/global/avatar',
  ])
  accept(@Body() body: { value?: string }) {
    return { length: body.value?.length ?? 0 };
  }
}

describe('route-scoped JSON body limits', () => {
  let app: NestExpressApplication;

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [PayloadController],
    }).compile();
    app = module.createNestApplication<NestExpressApplication>({
      bodyParser: false,
      logger: false,
    });
    app.use(createJsonBodyParser());
    app.useGlobalFilters(new AllExceptionsFilter());
    await app.init();
    await app.listen(0, '127.0.0.1');
  });

  afterAll(async () => {
    await app.close();
  });

  it.each([
    '/uapi/chat/completions',
    '/uapi/chat/completions/stream/?source=mobile',
  ])('accepts image-size JSON on %s', async (path) => {
    const value = 'x'.repeat(6 * 1024 * 1024);
    const result = await request(app.getHttpServer())
      .post(path)
      .send({ value })
      .expect(201);
    expect(result.body).toEqual({ length: value.length });
  });

  it.each(['/uapi/admin/ai/global/avatar', '/uapi/chat/completions/extra'])(
    'preserves the 5 MiB bound on %s',
    async (path) => {
      const result = await request(app.getHttpServer())
        .post(path)
        .send({ value: 'x'.repeat(6 * 1024 * 1024) })
        .expect(413);
      expect(result.body).toMatchObject({
        code: -1,
        message: '请求内容过大，请减少附件后重试',
      });
    },
  );

  it('rejects a chat JSON body above 48 MiB', async () => {
    await request(app.getHttpServer())
      .post('/uapi/chat/completions/stream')
      .send({ value: 'x'.repeat(chatJsonBodyLimit) })
      .expect(413);
  });
});
