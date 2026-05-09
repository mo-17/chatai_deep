import { IsString, MinLength, MaxLength, Matches } from 'class-validator';

export class RequestResetDto {
  @IsString()
  @MinLength(3)
  @MaxLength(64)
  userName: string;
}

export class ConfirmResetDto {
  @IsString()
  @MinLength(3)
  @MaxLength(64)
  userName: string;

  @IsString()
  @Matches(/^\d{6}$/, { message: 'reset code 必须是 6 位数字' })
  code: string;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  newPassword: string;
}
