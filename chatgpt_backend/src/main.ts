// 必须在任何业务模块导入之前加载 .env，
// 否则 jwt.const.ts 等在导入阶段读取 process.env 的常量会取到 undefined。
import 'dotenv/config';

import { NestFactory, Reflector } from '@nestjs/core';
import { ValidationPipe, ClassSerializerInterceptor } from '@nestjs/common';
import { Logger } from 'nestjs-pino';
import { NestExpressApplication } from '@nestjs/platform-express';
import { json } from 'express';
import { AppModule } from './app.module';
import { AllExceptionsFilter } from './common/all-exceptions.filter';
import { join } from 'path';
import { existsSync, mkdirSync } from 'fs';

async function bootstrap() {
  const origins = (
    process.env.CORS_ORIGINS ?? 'http://localhost:3001,http://localhost:5173'
  )
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    cors: {
      origin: origins,
      credentials: true,
      methods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
    },
    bufferLogs: true,
  });
  app.useLogger(app.get(Logger));
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }));
  app.useGlobalInterceptors(new ClassSerializerInterceptor(app.get(Reflector)));
  app.useGlobalFilters(new AllExceptionsFilter());

  // 加大 JSON body 限制，base64 图片上传需要 ~5MB
  app.use(json({ limit: '5mb' }));

  // 静态文件服务 — 头像等上传资源
  const uploadsDir = join(process.cwd(), 'uploads');
  if (!existsSync(uploadsDir)) mkdirSync(uploadsDir, { recursive: true });
  app.useStaticAssets(uploadsDir, { prefix: '/uploads/' });

  await app.listen(process.env.PORT ?? 3000);
  app
    .get(Logger)
    .log(`Backend running on http://localhost:${process.env.PORT ?? 3000}`);
}
void bootstrap();
