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
import { AdminBannerService } from './admin-banner.service';
import { AdminGuard } from '../auth/admin.guard';
import { CreateBannerDto } from './dto/create-banner.dto';
import { UpdateBannerDto } from './dto/update-banner.dto';

@Controller('uapi/admin/banners')
@UseGuards(AdminGuard)
export class AdminBannerController {
  constructor(private readonly svc: AdminBannerService) {}

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
  async create(@Body() body: CreateBannerDto) {
    const data = await this.svc.create(body);
    return { code: 0, data };
  }

  @Patch(':id')
  async edit(@Param('id') id: string, @Body() body: UpdateBannerDto) {
    const data = await this.svc.edit(parseInt(id, 10), body);
    return { code: 0, data };
  }

  @Delete(':id')
  async delete(@Param('id') id: string) {
    await this.svc.delete(parseInt(id, 10));
    return { code: 0, data: null };
  }
}
