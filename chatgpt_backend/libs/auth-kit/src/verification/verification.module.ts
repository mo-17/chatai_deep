import { Module, type DynamicModule } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { VerificationService } from './verification.service';
import { EmailSenderManager } from './senders/email-sender.manager';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { VerificationCode } from './entities/verification-code.entity';
import { SmtpProvider } from './entities/smtp-provider.entity';
import { EmailTemplate } from './entities/email-template.entity';
import { AuthSettings } from './entities/auth-settings.entity';
import {
  MicrosoftSmtpService,
  MICROSOFT_SMTP_TRANSPORT,
} from '../microsoft/microsoft-smtp.service';
import { MicrosoftSmtpTransport } from '../microsoft/microsoft-smtp.transport';
import {
  MicrosoftSmtpConnection,
  MicrosoftSmtpFlow,
} from '../microsoft/microsoft-smtp.entities';

@Module({
  imports: [
    TypeOrmModule.forFeature([
      VerificationCode,
      SmtpProvider,
      EmailTemplate,
      AuthSettings,
      MicrosoftSmtpConnection,
      MicrosoftSmtpFlow,
    ]),
  ],
  providers: [
    VerificationService,
    EmailSenderManager,
    AuthSettingsService,
    MicrosoftSmtpService,
    {
      provide: MICROSOFT_SMTP_TRANSPORT,
      useFactory: () => new MicrosoftSmtpTransport(),
    },
  ],
  exports: [
    VerificationService,
    EmailSenderManager,
    AuthSettingsService,
    TypeOrmModule,
    MicrosoftSmtpService,
  ],
})
export class VerificationModule {
  static forRoot(optionsModule: DynamicModule): DynamicModule {
    return { module: VerificationModule, imports: [optionsModule] };
  }
}
