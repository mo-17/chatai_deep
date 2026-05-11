import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import { LoggerModule } from 'nestjs-pino';
import { UserModule } from './user/user.module';
import { NoticeModule } from './notice/notice.module';
import { UpdateModule } from './update/update.module';
import { TestModule } from './test/test.module';
import { ChatModule } from './chat/chat.module';
import { AdminModule } from './admin/admin.module';
import { AiModule } from './ai/ai.module';
import { HealthModule } from './health/health.module';
import { AuthModule } from './auth/auth.module';
import {
  VerificationCode,
  SmtpProvider,
  AuthSettings,
  EmailTemplate,
} from '@auth-kit';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    LoggerModule.forRoot({
      pinoHttp: {
        level: process.env.LOG_LEVEL ?? 'info',
        transport:
          process.env.NODE_ENV === 'production'
            ? undefined
            : {
                target: 'pino-pretty',
                options: { colorize: true, translateTime: 'HH:MM:ss.l' },
              },
        redact: {
          paths: [
            'req.headers.authorization',
            '*.password',
            '*.apiKey',
            '*.code',
            'res.headers["set-cookie"]',
          ],
          censor: '[REDACTED]',
        },
        serializers: {
          req: (req: { method: string; url: string; id: unknown }) => ({
            method: req.method,
            url: req.url,
            id: req.id,
          }),
        },
      },
    }),
    ThrottlerModule.forRoot([{ ttl: 60_000, limit: 10 }]),
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (cfg: ConfigService) => ({
        type: 'postgres',
        host: cfg.get<string>('DB_HOST', 'localhost'),
        port: cfg.get<number>('DB_PORT', 5432),
        username: cfg.get<string>('DB_USER', 'huangzhibin'),
        password: cfg.get<string>('DB_PASSWORD', ''),
        database: cfg.get<string>('DB_NAME', 'chatgpt_flutter'),
        entities: [
          __dirname + '/**/*.entity{.ts,.js}',
          VerificationCode,
          SmtpProvider,
          AuthSettings,
          EmailTemplate,
        ],
        synchronize: cfg.get<string>('NODE_ENV') !== 'production',
        logging:
          cfg.get<string>('DB_LOGGING') === 'true'
            ? ['error', 'warn']
            : ['error'],
        extra: { max: parseInt(cfg.get<string>('DB_POOL_MAX', '10'), 10) },
      }),
    }),
    UserModule,
    NoticeModule,
    UpdateModule,
    ...(process.env.NODE_ENV === 'production' ? [] : [TestModule]),
    ChatModule,
    AdminModule,
    AiModule,
    HealthModule,
    AuthModule,
  ],
  providers: [{ provide: APP_GUARD, useClass: ThrottlerGuard }],
})
export class AppModule {}
