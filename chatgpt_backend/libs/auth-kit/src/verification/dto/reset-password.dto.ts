import { IsIn, IsString, Matches, MaxLength, MinLength } from 'class-validator';

export class ResetPasswordDto {
  @IsIn(['email', 'sms'])
  channel: 'email' | 'sms';

  @IsString()
  @MaxLength(320)
  identifier: string;

  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  newPassword: string;
}
