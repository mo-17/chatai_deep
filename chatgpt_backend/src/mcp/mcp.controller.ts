import {
  Body,
  Controller,
  Get,
  HttpCode,
  Post,
  UseGuards,
} from '@nestjs/common';
import { AdminGuard } from '../auth/admin.guard';
import { McpService } from './mcp.service';
import { CallToolDto } from './dto/call-tool.dto';

/**
 * MCP Host 对客户端的桥接接口（方案 B）。客户端拉取聚合工具清单、把每个工具
 * 包成本地 ChatTool，工具执行时回调 /uapi/mcp/call 由后端代为执行。
 * MCP server 配置与执行上下文是后端全局共享 authority，当前没有用户级 ACL。
 * 因此在 REST 共享边界统一要求管理员身份，避免普通用户直调 call 绕过客户端 UI。
 */
@Controller('uapi/mcp')
@UseGuards(AdminGuard)
export class McpController {
  constructor(private readonly svc: McpService) {}

  /** 聚合工具清单（含是否配置 + server 概览）。 */
  @Get('tools')
  async tools() {
    const servers = await this.svc.serverSummaries();
    const tools = servers.length > 0 ? await this.svc.listTools() : [];
    return {
      code: 0,
      data: { configured: servers.length > 0, servers, tools },
    };
  }

  /** server 概览（不触发连接）。 */
  @Get('servers')
  async servers() {
    const servers = await this.svc.serverSummaries();
    return {
      code: 0,
      data: { configured: servers.length > 0, servers },
    };
  }

  /** 执行一次工具调用，结果以纯文本返回。 */
  @Post('call')
  @HttpCode(200)
  async call(@Body() body: CallToolDto) {
    const content = await this.svc.callTool(body.name, body.arguments ?? {});
    return { code: 0, data: { content } };
  }
}
