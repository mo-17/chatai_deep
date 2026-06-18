import { IsObject, IsOptional, IsString } from 'class-validator';

export class CallToolDto {
  /** 带前缀的工具名：mcp__<serverId>__<rawName>。 */
  @IsString()
  name!: string;

  /** 工具参数（JSON 对象）。 */
  @IsOptional()
  @IsObject()
  arguments?: Record<string, unknown>;
}
