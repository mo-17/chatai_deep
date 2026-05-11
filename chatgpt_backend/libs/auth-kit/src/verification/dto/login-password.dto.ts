import { IsIn, IsString, MaxLength, MinLength } from 'class-validator';

export class LoginPasswordDto {
  @IsIn(['email', 'sms'])
  channel: 'email' | 'sms';

  @IsString()
  @MaxLength(320)
  identifier: string;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  password: string;
}
