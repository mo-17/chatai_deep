import { IsIn, IsString, Matches, MaxLength } from 'class-validator';

export class BindDto {
  @IsIn(['email', 'sms'])
  channel: 'email' | 'sms';

  @IsString()
  @MaxLength(320)
  identifier: string;

  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;
}
