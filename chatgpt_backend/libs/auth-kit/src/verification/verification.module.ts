import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { VerificationService } from './verification.service';
import { EmailSenderManager } from './senders/email-sender.manager';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { VerificationCode } from './entities/verification-code.entity';
import { SmtpProvider } from './entities/smtp-provider.entity';
import { AuthSettings } from './entities/auth-settings.entity';

@Module({
  imports: [
    TypeOrmModule.forFeature([VerificationCode, SmtpProvider, AuthSettings]),
  ],
  providers: [VerificationService, EmailSenderManager, AuthSettingsService],
  exports: [
    VerificationService,
    EmailSenderManager,
    AuthSettingsService,
    TypeOrmModule,
  ],
})
export class VerificationModule {}
