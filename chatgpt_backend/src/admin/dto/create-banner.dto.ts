import { IsString, IsBoolean, IsNumber, IsOptional, MinLength } from 'class-validator';

export class CreateBannerDto {
  @IsString()
  @MinLength(1)
  title: string;

  @IsOptional()
  @IsString()
  subtitle?: string;

  @IsOptional()
  @IsString()
  cover?: string;

  @IsOptional()
  @IsString()
  url?: string;

  @IsOptional()
  @IsNumber()
  sticky?: number;

  @IsOptional()
  @IsBoolean()
  enabled?: boolean;

  @IsOptional()
  @IsString()
  type?: string;
}
