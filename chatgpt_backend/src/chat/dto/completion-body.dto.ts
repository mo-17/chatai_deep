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

  // 工具调用（OpenAI function declarations）。ValidationPipe 开了 whitelist，
  // 不声明会被剥掉；SSE 中继本就原样透传 tool_calls 增量，无需其它改动。
  @IsOptional()
  @IsArray()
  tools?: Record<string, unknown>[];
}
