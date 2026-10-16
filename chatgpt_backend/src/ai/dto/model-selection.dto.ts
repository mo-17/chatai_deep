import { IsString, Matches, ValidateIf } from 'class-validator';

export class ModelSelectionDto {
  @IsString()
  @Matches(/\S/)
  modelId: string;

  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsString()
  @Matches(/\S/)
  providerCode?: string;
}
