import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { TypeOrmModule } from '@nestjs/typeorm';
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
    TypeOrmModule.forRoot({
      type: 'postgres',
      host: 'localhost',
      port: 5432,
      username: 'huangzhibin',
      password: '',
      database: 'chatgpt_flutter',
      entities: [__dirname + '/**/*.entity{.ts,.js}'],
      synchronize: true,
    }),
    UserModule,
    NoticeModule,
    UpdateModule,
    TestModule,
    ChatModule,
    AdminModule,
    AiModule,
  ],
})
export class AppModule {}
