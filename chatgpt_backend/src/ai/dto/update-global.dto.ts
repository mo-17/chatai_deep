import { IsString, IsBoolean, IsOptional } from 'class-validator';

export class UpdateGlobalDto {
  @IsOptional()
  @IsString()
  defaultProviderCode?: string;

  @IsOptional()
  @IsString()
  defaultModelId?: string;

  @IsOptional()
  @IsBoolean()
  catalogPublic?: boolean;
}
