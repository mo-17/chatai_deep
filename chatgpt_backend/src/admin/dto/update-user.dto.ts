import { IsString, IsBoolean, IsOptional, IsIn } from 'class-validator';

export class UpdateUserDto {
  @IsOptional()
  @IsString()
  avatar?: string;

  @IsOptional()
  @IsString()
  @IsIn(['user', 'admin'])
  role?: string;

  @IsOptional()
  @IsBoolean()
  banned?: boolean;
}
