import {
  Controller,
  Get,
  Post,
  Patch,
  Delete,
  Param,
  Body,
  UseGuards,
} from '@nestjs/common';
import { AdminAiProviderService } from './admin-ai-provider.service';
import { AdminGuard } from '../auth/admin.guard';
import { CreateProviderDto } from './dto/create-provider.dto';
import { UpdateProviderDto } from './dto/update-provider.dto';

@Controller('uapi/admin/ai/providers')
@UseGuards(AdminGuard)
export class AdminAiProviderController {
  constructor(private readonly svc: AdminAiProviderService) {}

  @Get()
  async list() {
    const data = await this.svc.list();
    return { code: 0, data };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const data = await this.svc.detail(parseInt(id, 10));
    return { code: 0, data };
  }

  @Post()
  async create(@Body() body: CreateProviderDto) {
    const data = await this.svc.create(body);
    return { code: 0, data };
  }

  @Patch(':id')
  async edit(@Param('id') id: string, @Body() body: UpdateProviderDto) {
    const data = await this.svc.edit(parseInt(id, 10), body);
    return { code: 0, data };
  }

  @Delete(':id')
  async delete(@Param('id') id: string) {
    await this.svc.delete(parseInt(id, 10));
    return { code: 0, data: null };
  }

  @Post(':id/test')
  async test(@Param('id') id: string) {
    const data = await this.svc.testConnection(parseInt(id, 10));
    return { code: 0, data };
  }
}
