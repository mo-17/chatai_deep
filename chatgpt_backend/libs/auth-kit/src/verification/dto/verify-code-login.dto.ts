import { IsString, Matches } from 'class-validator';
import { AuthIdentifierDto } from './identifier.dto';

export class VerifyCodeLoginDto extends AuthIdentifierDto {
  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;
}
