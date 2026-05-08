import {
  IsString,
  IsBoolean,
  IsNumber,
  IsUrl,
  IsOptional,
  MinLength,
} from 'class-validator';

export class UpdateProviderDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  displayName?: string;

  @IsOptional()
  @IsString()
  apiKey?: string;

  @IsOptional()
  @IsUrl({ require_tld: false })
  baseUrl?: string;

  @IsOptional()
  @IsString()
  modelPrefixes?: string;

  @IsOptional()
  @IsBoolean()
  enabled?: boolean;

  @IsOptional()
  @IsNumber()
  sortOrder?: number;
}
