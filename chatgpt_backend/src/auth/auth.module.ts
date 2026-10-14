import { Global, Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { User } from '../user/user.entity';
import { AuthKitModule } from '@auth-kit';
import { ChatGptUserResolver } from './chatgpt-user.resolver';
import { ChatGptJwtSigner } from './chatgpt-jwt-signer';
import { TokenAuthenticationService } from './token-authentication.service';
import { JwtGuard } from './jwt.guard';
import { AdminGuard } from './admin.guard';
import { requireAppSecretKey } from '@auth-kit';

/**
 * 提供 ChatGpt 项目的 IUserResolver / IJwtSigner 实现，
 * 单独成模块以便在 AuthKitModule.forRootAsync 的 imports 中可见。
 */
@Global()
@Module({
  imports: [TypeOrmModule.forFeature([User])],
  providers: [
    ChatGptUserResolver,
    ChatGptJwtSigner,
    TokenAuthenticationService,
    JwtGuard,
    AdminGuard,
  ],
  exports: [
    ChatGptUserResolver,
    ChatGptJwtSigner,
    TokenAuthenticationService,
    JwtGuard,
    AdminGuard,
  ],
})
class ChatGptAuthProvidersModule {}

/**
 * 宿主 Auth 模块 —— 组装 AuthKitModule.forRootAsync，
 * 注入 ChatGpt 项目专用的 UserResolver 与 JwtSigner。
 */
@Global()
@Module({
  imports: [
    ChatGptAuthProvidersModule,
    AuthKitModule.forRootAsync({
      imports: [ChatGptAuthProvidersModule],
      inject: [
        ChatGptUserResolver,
        ChatGptJwtSigner,
        TokenAuthenticationService,
      ],
      useFactory: (
        userResolver: ChatGptUserResolver,
        jwtSigner: ChatGptJwtSigner,
        accessTokenVerifier: TokenAuthenticationService,
      ) => ({
        userResolver,
        jwtSigner,
        accessTokenVerifier,
        appSecretKey: requireAppSecretKey(process.env.APP_SECRET_KEY),
        microsoftSmtpRedirectUri: process.env.MICROSOFT_SMTP_REDIRECT_URI,
      }),
    }),
  ],
  exports: [ChatGptAuthProvidersModule],
})
export class AuthModule {}
