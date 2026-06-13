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
import { AdminVersionService } from './admin-version.service';
import { AdminGuard } from '../auth/admin.guard';
import { AppVersion } from '../update/version.entity';

@Controller('uapi/admin/versions')
@UseGuards(AdminGuard)
export class AdminVersionController {
  constructor(private readonly svc: AdminVersionService) {}

  @Get()
  async list(
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    const data = await this.svc.list({
      page: parseInt(page || '1', 10),
      pageSize: parseInt(pageSize || '10', 10),
    });
    return { code: 0, data };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const data = await this.svc.detail(parseInt(id, 10));
    return { code: 0, data };
  }

  @Post()
  async create(@Body() body: Partial<AppVersion>) {
    const data = await this.svc.create(body);
    return { code: 0, data };
  }

  @Patch(':id')
  async edit(@Param('id') id: string, @Body() body: Partial<AppVersion>) {
    const data = await this.svc.edit(parseInt(id, 10), body);
    return { code: 0, data };
  }

  @Delete(':id')
  async delete(@Param('id') id: string) {
    await this.svc.delete(parseInt(id, 10));
    return { code: 0, data: null };
  }
}
