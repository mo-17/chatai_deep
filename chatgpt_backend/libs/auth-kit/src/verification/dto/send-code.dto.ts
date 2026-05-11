import { IsIn, IsString, MaxLength } from 'class-validator';

const CHANNELS = ['email', 'sms'] as const;
const PURPOSES = ['login', 'register', 'bind', 'reset_password'] as const;

export class SendCodeDto {
  @IsIn(CHANNELS)
  channel: 'email' | 'sms';

  @IsString()
  @MaxLength(320)
  identifier: string;

  @IsIn(PURPOSES)
  purpose: 'login' | 'register' | 'bind' | 'reset_password';
}
