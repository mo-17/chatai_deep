import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { AdminGuard } from '../auth/admin.guard';
import { AdminMcpService } from './admin-mcp.service';
import {
  CreateMcpServerDto,
  UpdateMcpServerDto,
} from './dto/upsert-server.dto';

/** MCP server 管理（item 4，AdminGuard）。后台维护后端聚合的 MCP server 列表。 */
@Controller('uapi/admin/mcp/servers')
@UseGuards(AdminGuard)
export class AdminMcpController {
  constructor(private readonly svc: AdminMcpService) {}

  @Get()
  async list() {
    return { code: 0, data: await this.svc.list() };
  }

  @Post()
  @HttpCode(200)
  async create(@Body() body: CreateMcpServerDto) {
    return { code: 0, data: await this.svc.create(body) };
  }

  @Patch(':id')
  async update(@Param('id') id: string, @Body() body: UpdateMcpServerDto) {
    return { code: 0, data: await this.svc.update(parseInt(id, 10), body) };
  }

  @Delete(':id')
  async remove(@Param('id') id: string) {
    await this.svc.remove(parseInt(id, 10));
    return { code: 0, data: null };
  }

  @Post(':id/test')
  @HttpCode(200)
  async test(@Param('id') id: string) {
    return { code: 0, data: await this.svc.test(parseInt(id, 10)) };
  }
}
