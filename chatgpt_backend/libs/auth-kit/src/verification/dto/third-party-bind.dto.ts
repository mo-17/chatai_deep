import { IsString, Matches, MaxLength } from 'class-validator';
import { AuthIdentifierDto } from './identifier.dto';

export class ThirdPartyBindDto extends AuthIdentifierDto {
  @IsString() @MaxLength(4096) bindTicket: string;
  @IsString()
  @Matches(/^\d{6}$/, { message: '验证码为 6 位数字' })
  code: string;
}
