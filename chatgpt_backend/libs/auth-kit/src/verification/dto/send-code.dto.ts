import { IsIn } from 'class-validator';
import { AuthIdentifierDto } from './identifier.dto';

export class SendCodeDto extends AuthIdentifierDto {
  @IsIn(['login', 'register', 'bind', 'reset_password'])
  purpose: 'login' | 'register' | 'bind' | 'reset_password';
}
