import { Transform } from 'class-transformer';
import {
  IsBoolean,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
} from 'class-validator';
import { canonicalIdentifier } from '../verification/verification-contract';

export class UpdateAuthSettingsDto {
  @IsOptional() @IsIn(['getAuthCode', 'quickLogin']) huaweiPrimaryFlow?:
    | 'getAuthCode'
    | 'quickLogin';
  @IsOptional() @IsBoolean() huaweiQuickLoginEnabled?: boolean;
  @IsOptional() @IsBoolean() huaweiGetAuthCodeEnabled?: boolean;
  @IsOptional() @IsBoolean() appleSignInEnabled?: boolean;
  @IsOptional() @IsBoolean() smsMockHighlight?: boolean;
  @IsOptional() @IsInt() @Min(60) @Max(1800) codeTtlSeconds?: number;
  @IsOptional() @IsInt() @Min(30) @Max(600) codeResendIntervalSeconds?: number;
  @IsOptional() @IsInt() @Min(1) @Max(10) codeMaxAttempts?: number;
  @IsOptional() @IsInt() @Min(1) @Max(100) codeDailyLimitPerIdentifier?: number;
  @IsOptional() @IsInt() @Min(1) @Max(100) codeHourlyLimitPerIp?: number;
}

/** 固定安全反馈，class-validator 不将提交值写入此提示。 */
export const MICROSOFT_CLIENT_ID_INVALID =
  'Microsoft Client ID 必须填写微软应用的“应用程序（客户端）ID”（UUID）';

export class UpdateSmtpProviderDto {
  @IsOptional() @IsIn(['password', 'microsoft_oauth']) authMode?:
    | 'password'
    | 'microsoft_oauth';
  @IsOptional()
  @IsUUID(undefined, { message: MICROSOFT_CLIENT_ID_INVALID })
  microsoftClientId?: string;
  @IsOptional()
  @IsString()
  @MaxLength(4096)
  @Matches(/^[^\r\n\0]*$/)
  microsoftClientSecret?: string;
  @IsOptional() @IsBoolean() clearMicrosoftClientSecret?: boolean;
  @IsOptional() @IsBoolean() clearPassword?: boolean;
  @IsOptional()
  @IsString()
  @MaxLength(255)
  @Matches(/^[a-zA-Z0-9.-]+$/)
  host?: string;
  @IsOptional() @IsInt() @Min(1) @Max(65535) port?: number;
  @IsOptional() @IsBoolean() secure?: boolean;
  @IsOptional()
  @IsString()
  @MaxLength(255)
  @Matches(/^[^\r\n\0]+$/)
  username?: string;
  @IsOptional() @IsString() @MaxLength(200) password?: string;
  @IsOptional()
  @IsString()
  @MaxLength(100)
  @Matches(/^[^\r\n\0]*$/)
  fromName?: string;
  @IsOptional()
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? canonicalIdentifier('email', value) : value,
  )
  @IsString()
  @MaxLength(320)
  fromAddress?: string;
  @IsOptional()
  @IsString()
  @MaxLength(100)
  @Matches(/^[^\r\n\0]+$/)
  displayName?: string;
}

export class TestSmtpProviderDto {
  @Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? canonicalIdentifier('email', value) : value,
  )
  @IsString()
  @MaxLength(320)
  to: string;
}

export class UpdateEmailTemplateDto {
  @IsString() @MaxLength(200) @Matches(/^[^\r\n\0]+$/) subject: string;
  @IsString() @MaxLength(65536) @Matches(/^[^\0]+$/) body: string;
}

function integerQuery(value: unknown): unknown {
  return typeof value === 'string' && /^[1-9]\d*$/.test(value)
    ? Number(value)
    : value;
}
export class CodeLogQueryDto {
  @IsOptional()
  @Transform(({ value }: { value: unknown }) => integerQuery(value))
  @IsInt()
  @Min(1)
  @Max(1000000)
  page?: number;
  @IsOptional()
  @Transform(({ value }: { value: unknown }) => integerQuery(value))
  @IsInt()
  @Min(1)
  @Max(100)
  pageSize?: number;
  @IsOptional() @IsIn(['email', 'sms']) channel?: 'email' | 'sms';
  @IsOptional()
  @IsString()
  @MaxLength(320)
  @Matches(/^[^\r\n\0]*$/)
  identifier?: string;
  @IsOptional()
  @IsIn(['login', 'register', 'bind', 'reset_password'])
  purpose?: string;
}
