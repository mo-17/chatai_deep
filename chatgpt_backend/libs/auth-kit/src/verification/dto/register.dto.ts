import {
  IsIn,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';

export class AuthRegisterDto {
  @IsIn(['email', 'sms'])
  channel: 'email' | 'sms';

  @IsString()
  @MaxLength(320)
  identifier: string;

  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;

  /** 密码可选——未给即纯验证码账户 */
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(64)
  password?: string;
}
