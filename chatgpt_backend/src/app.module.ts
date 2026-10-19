import { logUrl } from './common/auth-log-safety';
import { FeedbackModule } from './feedback/feedback.module';
import { OperationsModule } from './operations/operations.module';
import { KnowledgeTeamModule } from './knowledge-team/knowledge-team.module';
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
import { McpModule } from './mcp/mcp.module';
import { SyncModule } from './sync/sync.module';
import { SyncV2Module } from './sync-v2/sync-v2.module';
import { buildPostgresOptions } from './database/postgres-options';
import { CloudWorkflowModule } from './cloud-workflow/cloud-workflow.module';

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
            'req.headers.cookie',
            '*.state',
            '*.nonce',
            '*.token',
            '*.accessToken',
            '*.refreshToken',
            '*.clientSecret',
            '*.code_verifier',
            '*.password',
            '*.apiKey',
            '*.code',
            'res.headers["set-cookie"]',
          ],
          censor: '[REDACTED]',
        },
        serializers: {
          err: () => ({ type: 'RequestError', message: 'request_failed' }),
          req: (req: { method: string; url: string; id: unknown }) => ({
            method: req.method,
            url: logUrl(req.url),
            id: req.id,
          }),
        },
      },
    }),
    ThrottlerModule.forRoot([{ ttl: 60_000, limit: 10 }]),
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (cfg: ConfigService) => {
        const synchronize = cfg.get<string>('DB_SYNCHRONIZE');
        return {
          ...buildPostgresOptions((key) => cfg.get<string>(key), __dirname),
          synchronize:
            synchronize === 'true' ||
            (synchronize !== 'false' &&
              cfg.get<string>('NODE_ENV') !== 'production'),
        };
      },
    }),
    FeedbackModule,
    KnowledgeTeamModule,
    UserModule,
    NoticeModule,
    UpdateModule,
    ...(process.env.NODE_ENV === 'production' ? [] : [TestModule]),
    ChatModule,
    AdminModule,
    AiModule,
    HealthModule,
    OperationsModule,
    AuthModule,
    McpModule,
    SyncModule,
    SyncV2Module,
    CloudWorkflowModule,
  ],
  providers: [{ provide: APP_GUARD, useClass: ThrottlerGuard }],
})
export class AppModule {}
