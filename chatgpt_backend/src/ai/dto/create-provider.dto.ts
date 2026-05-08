import {
  IsString,
  IsBoolean,
  IsNumber,
  IsUrl,
  IsOptional,
  Matches,
  MinLength,
} from 'class-validator';

export class CreateProviderDto {
  @IsString()
  @Matches(/^[a-z][a-z0-9_-]*$/)
  code: string;

  @IsString()
  @MinLength(1)
  displayName: string;

  @IsString()
  apiKey: string;

  @IsUrl({ require_tld: false })
  baseUrl: string;

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
