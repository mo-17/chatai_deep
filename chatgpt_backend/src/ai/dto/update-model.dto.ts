import {
  IsString,
  IsBoolean,
  IsNumber,
  IsOptional,
  MinLength,
} from 'class-validator';

export class UpdateModelDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  modelId?: string;

  @IsOptional()
  @IsString()
  @MinLength(1)
  displayName?: string;

  @IsOptional()
  @IsString()
  description?: string;

  @IsOptional()
  @IsBoolean()
  enabled?: boolean;

  @IsOptional()
  @IsBoolean()
  isDefault?: boolean;

  @IsOptional()
  @IsNumber()
  sortOrder?: number;

  @IsOptional()
  @IsNumber()
  providerId?: number;
}
