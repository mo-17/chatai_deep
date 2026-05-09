import { IsString, IsArray, IsInt, IsOptional, Min } from 'class-validator';

export class CompletionBodyDto {
  @IsString()
  model: string;

  @IsArray()
  messages: Record<string, unknown>[];

  @IsOptional()
  @IsInt()
  @Min(1)
  max_tokens?: number;
}
