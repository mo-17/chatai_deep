import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { User } from '../user/user.entity';
import { AuthKitModule } from '@auth-kit';
import { ChatGptUserResolver } from './chatgpt-user.resolver';
import { ChatGptJwtSigner } from './chatgpt-jwt-signer';

/**
 * 提供 ChatGpt 项目的 IUserResolver / IJwtSigner 实现，
 * 单独成模块以便在 AuthKitModule.forRootAsync 的 imports 中可见。
 */
@Module({
  imports: [TypeOrmModule.forFeature([User])],
  providers: [ChatGptUserResolver, ChatGptJwtSigner],
  exports: [ChatGptUserResolver, ChatGptJwtSigner],
})
class ChatGptAuthProvidersModule {}

/**
 * 宿主 Auth 模块 —— 组装 AuthKitModule.forRootAsync，
 * 注入 ChatGpt 项目专用的 UserResolver 与 JwtSigner。
 */
@Module({
  imports: [
    AuthKitModule.forRootAsync({
      imports: [ChatGptAuthProvidersModule],
      inject: [ChatGptUserResolver, ChatGptJwtSigner],
      useFactory: (
        userResolver: ChatGptUserResolver,
        jwtSigner: ChatGptJwtSigner,
      ) => ({
        userResolver,
        jwtSigner,
        appSecretKey:
          process.env.APP_SECRET_KEY ?? 'CHANGE_ME_CHANGE_ME_CHANGE_ME_32B',
      }),
    }),
  ],
  exports: [],
})
export class AuthModule {}
