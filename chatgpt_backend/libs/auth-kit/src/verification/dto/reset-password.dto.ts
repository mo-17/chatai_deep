import { IsString, Matches, MaxLength, MinLength } from 'class-validator';
import { AuthIdentifierDto } from './identifier.dto';

export class ResetPasswordDto extends AuthIdentifierDto {
  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  newPassword: string;
}
