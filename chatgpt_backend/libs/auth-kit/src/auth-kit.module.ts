import { Module, DynamicModule, Provider } from '@nestjs/common';
import type { ForwardReference, Type } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { VerificationCode } from './verification/entities/verification-code.entity';
import { SmtpProvider } from './verification/entities/smtp-provider.entity';
import { AuthSettings } from './verification/entities/auth-settings.entity';
import { EmailTemplate } from './verification/entities/email-template.entity';
import { VerificationModule } from './verification/verification.module';
import { IUserResolver } from './contracts/user-resolver.interface';
import { IJwtSigner } from './contracts/jwt-signer.interface';
import { IAuditLogger } from './contracts/audit-logger.interface';
import { AuthController } from './controllers/auth.controller';
import { ThirdPartyController } from './controllers/third-party.controller';
import { AdminAuthController } from './controllers/admin-auth.controller';
import { HuaweiService } from './third-party/huawei/huawei.service';
import { AppleService } from './third-party/apple/apple.service';
import { ThirdPartyEnabledGuard } from './third-party/third-party-enabled.guard';
import { AUTH_KIT_OPTIONS } from './auth-kit.tokens';
import type { IAccessTokenVerifier } from './contracts/access-token-verifier.interface';
import {
  AuthKitAdminGuard,
  AuthKitJwtGuard,
} from './guards/auth-kit-auth.guard';
import { requireAppSecretKey } from './security/app-secret';

export interface AuthKitModuleOptions {
  userResolver: IUserResolver;
  jwtSigner: IJwtSigner;
  accessTokenVerifier: IAccessTokenVerifier;
  auditLogger?: IAuditLogger;
  /** 凭据加密主密钥，用于加密 smtp_providers.passwordEncrypted */
  appSecretKey: string;
}

export { AUTH_KIT_OPTIONS } from './auth-kit.tokens';

@Module({})
export class AuthKitModule {
  static forRootAsync(asyncOptions: {
    imports?: Array<
      | Type<unknown>
      | DynamicModule
      | Promise<DynamicModule>
      | ForwardReference<unknown>
    >;
    inject?: Array<Type<unknown> | string | symbol>;
    useFactory: (
      ...args: unknown[]
    ) => Promise<AuthKitModuleOptions> | AuthKitModuleOptions;
  }): DynamicModule {
    const optionsProvider: Provider = {
      provide: AUTH_KIT_OPTIONS,
      inject: asyncOptions.inject ?? [],
      useFactory: async (...args: unknown[]) => {
        const options = await asyncOptions.useFactory(...args);
        return {
          ...options,
          appSecretKey: requireAppSecretKey(options.appSecretKey),
        };
      },
    };

    return {
      module: AuthKitModule,
      imports: [
        ...(asyncOptions.imports ?? []),
        TypeOrmModule.forFeature([
          VerificationCode,
          SmtpProvider,
          AuthSettings,
          EmailTemplate,
        ]),
        VerificationModule,
      ],
      controllers: [AuthController, AdminAuthController, ThirdPartyController],
      providers: [
        optionsProvider,
        HuaweiService,
        AppleService,
        ThirdPartyEnabledGuard,
        AuthKitJwtGuard,
        AuthKitAdminGuard,
      ],
      exports: [VerificationModule, TypeOrmModule, AUTH_KIT_OPTIONS],
    };
  }
}
