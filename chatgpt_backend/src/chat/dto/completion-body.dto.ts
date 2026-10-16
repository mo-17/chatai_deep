import {
  IsString,
  IsArray,
  IsInt,
  IsNumber,
  IsOptional,
  IsIn,
  Min,
  Max,
  Matches,
  ValidateIf,
} from 'class-validator';

export class CompletionBodyDto {
  @IsString()
  @Matches(/\S/)
  model: string;

  // 缺字段兼容旧请求；显式 null/空白不允许退回 legacy。
  @ValidateIf((_object, value: unknown) => value !== undefined)
  @IsString()
  @Matches(/\S/)
  providerCode?: string;

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
