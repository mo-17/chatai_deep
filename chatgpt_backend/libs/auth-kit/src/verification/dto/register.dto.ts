import {
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import { AuthIdentifierDto } from './identifier.dto';

export class AuthRegisterDto extends AuthIdentifierDto {
  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;

  /** 密码可选，保持已有验证码账户语义。 */
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(64)
  password?: string;
}
