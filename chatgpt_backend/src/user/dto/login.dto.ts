import { IsString, MinLength, MaxLength } from 'class-validator';

export class LoginDto {
  @IsString()
  @MinLength(3)
  @MaxLength(64)
  userName: string;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  password: string;
}
