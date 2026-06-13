import {
  IsString,
  IsBoolean,
  IsNumber,
  IsOptional,
  MinLength,
} from 'class-validator';

export class CreateModelDto {
  @IsNumber()
  providerId: number;

  @IsString()
  @MinLength(1)
  modelId: string;

  @IsString()
  @MinLength(1)
  displayName: string;

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

  // 能力位（可选，默认 false）。客户端做加法覆盖，故只需标注启发式判不出的能力。
  @IsOptional()
  @IsBoolean()
  supportsVision?: boolean;

  @IsOptional()
  @IsBoolean()
  supportsTool?: boolean;

  @IsOptional()
  @IsBoolean()
  supportsReasoning?: boolean;

  @IsOptional()
  @IsBoolean()
  supportsPdf?: boolean;
}
