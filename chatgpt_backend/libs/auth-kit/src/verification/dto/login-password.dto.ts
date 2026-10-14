import { IsString, MaxLength, MinLength } from 'class-validator';
import { AuthIdentifierDto } from './identifier.dto';

export class LoginPasswordDto extends AuthIdentifierDto {
  @IsString()
  @MinLength(1)
  @MaxLength(64)
  password: string;
}
