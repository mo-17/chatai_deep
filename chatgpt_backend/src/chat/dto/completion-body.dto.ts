import {
  IsString,
  IsArray,
  IsInt,
  IsNumber,
  IsOptional,
  IsIn,
  Min,
  Max,
} from 'class-validator';

export class CompletionBodyDto {
  @IsString()
  model: string;

  @IsArray()
  messages: Record<string, unknown>[];

  @IsOptional()
  @IsInt()
  @Min(1)
  max_tokens?: number;

  @IsOptional()
  @IsNumber()
  @Min(0)
  @Max(2)
  temperature?: number;

  @IsOptional()
  @IsNumber()
  @Min(0)
  @Max(1)
  top_p?: number;

  // 工具调用（OpenAI function declarations）。ValidationPipe 开了 whitelist，
  // 不声明会被剥掉；SSE 中继本就原样透传 tool_calls 增量，无需其它改动。
  @IsOptional()
  @IsArray()
  tools?: Record<string, unknown>[];

  @IsOptional()
  @IsIn(['standard', 'translation'])
  request_profile?: 'standard' | 'translation';

  @IsOptional()
  @IsIn(['provider_default', 'off_if_supported'])
  reasoning_policy?: 'provider_default' | 'off_if_supported';

  @IsOptional()
  @IsIn(['low', 'high', 'max'])
  reasoning_effort?: 'low' | 'high' | 'max';
}
