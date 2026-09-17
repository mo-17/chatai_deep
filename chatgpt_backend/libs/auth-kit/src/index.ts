// AuthKitModule
export { AuthKitModule, AUTH_KIT_OPTIONS } from './auth-kit.module';
export type { AuthKitModuleOptions } from './auth-kit.module';

// Entities
export { VerificationCode } from './verification/entities/verification-code.entity';
export { SmtpProvider } from './verification/entities/smtp-provider.entity';
export { AuthSettings } from './verification/entities/auth-settings.entity';
export { EmailTemplate } from './verification/entities/email-template.entity';

// Contracts
export type {
  AuthUser,
  CreateUserInput,
  ThirdPartyProvider,
  AuthChannel,
} from './contracts/auth-user.types';
export type { IUserResolver } from './contracts/user-resolver.interface';
export type { IJwtSigner } from './contracts/jwt-signer.interface';
export type { IAuditLogger } from './contracts/audit-logger.interface';
export type {
  AuthenticatedPrincipal,
  IAccessTokenVerifier,
} from './contracts/access-token-verifier.interface';

// Services
export { AuthSettingsService } from './settings/auth-settings.service';
export { VerificationService } from './verification/verification.service';
export { EmailSenderManager } from './verification/senders/email-sender.manager';

// Senders
export { EmailSmtpSender } from './verification/senders/email-smtp.sender';
export { EmailAliyunSender } from './verification/senders/email-aliyun.sender';
export { EmailTencentSender } from './verification/senders/email-tencent.sender';
export { SmsMockSender } from './verification/senders/sms-mock.sender';
export type { IEmailSender } from './verification/senders/email-sender.interface';
export type { ISmsSender } from './verification/senders/sms-sender.interface';

// Controllers
export { AuthController } from './controllers/auth.controller';
export { ThirdPartyController } from './controllers/third-party.controller';

// Third-party services
export { HuaweiService } from './third-party/huawei/huawei.service';
export { AppleService } from './third-party/apple/apple.service';
export {
  AuthKitJwtGuard,
  AuthKitAdminGuard,
} from './guards/auth-kit-auth.guard';
export { requireAppSecretKey } from './security/app-secret';
export {
  ThirdPartyEnabledGuard,
  ThirdParty,
  THIRD_PARTY_KEY,
} from './third-party/third-party-enabled.guard';

// DTOs
export { SendCodeDto } from './verification/dto/send-code.dto';
export { VerifyCodeLoginDto } from './verification/dto/verify-code-login.dto';
export { AuthRegisterDto } from './verification/dto/register.dto';
export { LoginPasswordDto } from './verification/dto/login-password.dto';
export { ResetPasswordDto } from './verification/dto/reset-password.dto';
export { BindDto } from './verification/dto/bind.dto';
