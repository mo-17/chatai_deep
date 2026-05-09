import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { APP_GUARD } from '@nestjs/core';
import { UserModule } from './user/user.module';
import { NoticeModule } from './notice/notice.module';
import { UpdateModule } from './update/update.module';
import { TestModule } from './test/test.module';
import { ChatModule } from './chat/chat.module';
import { AdminModule } from './admin/admin.module';
import { AiModule } from './ai/ai.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
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
        entities: [__dirname + '/**/*.entity{.ts,.js}'],
        synchronize: cfg.get<string>('NODE_ENV') !== 'production',
        logging: cfg.get<string>('DB_LOGGING') === 'true' ? ['error', 'warn'] : ['error'],
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
  ],
  providers: [{ provide: APP_GUARD, useClass: ThrottlerGuard }],
})
export class AppModule {}
