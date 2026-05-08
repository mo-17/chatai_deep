import {
  Controller,
  Get,
  Post,
  Patch,
  Delete,
  Param,
  Query,
  Body,
  UseGuards,
} from '@nestjs/common';
import { AdminAiModelService } from './admin-ai-model.service';
import { AdminGuard } from '../auth/admin.guard';
import { CreateModelDto } from './dto/create-model.dto';
import { UpdateModelDto } from './dto/update-model.dto';

@Controller('uapi/admin/ai/models')
@UseGuards(AdminGuard)
export class AdminAiModelController {
  constructor(private readonly svc: AdminAiModelService) {}

  @Get()
  async list(
    @Query('providerId') providerId?: string,
    @Query('enabled') enabled?: string,
    @Query('keyword') keyword?: string,
  ) {
    const data = await this.svc.list({ providerId, enabled, keyword });
    return { code: 0, data };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const data = await this.svc.detail(parseInt(id, 10));
    return { code: 0, data };
  }

  @Post()
  async create(@Body() body: CreateModelDto) {
    const data = await this.svc.create(body);
    return { code: 0, data };
  }

  @Patch(':id')
  async edit(@Param('id') id: string, @Body() body: UpdateModelDto) {
    const data = await this.svc.edit(parseInt(id, 10), body);
    return { code: 0, data };
  }

  @Delete(':id')
  async delete(@Param('id') id: string) {
    await this.svc.delete(parseInt(id, 10));
    return { code: 0, data: null };
  }

  @Post(':id/set-default')
  async setDefault(@Param('id') id: string) {
    const data = await this.svc.setDefault(parseInt(id, 10));
    return { code: 0, data };
  }
}
