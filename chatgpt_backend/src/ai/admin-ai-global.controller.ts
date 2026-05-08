import { Controller, Get, Patch, Post, Body, UseGuards } from '@nestjs/common';
import { AdminAiGlobalService } from './admin-ai-global.service';
import { AdminGuard } from '../auth/admin.guard';
import { UpdateGlobalDto } from './dto/update-global.dto';

@Controller('uapi/admin/ai/global')
@UseGuards(AdminGuard)
export class AdminAiGlobalController {
  constructor(private readonly svc: AdminAiGlobalService) {}

  @Get()
  async get() {
    const data = await this.svc.get();
    return { code: 0, data };
  }

  @Patch()
  async update(@Body() body: UpdateGlobalDto) {
    const data = await this.svc.update(body);
    return { code: 0, data };
  }

  @Post('avatar')
  async uploadAvatar(@Body() body: { base64: string }) {
    if (!body.base64) {
      return { code: -1, message: '缺少 base64 参数' };
    }
    const data = await this.svc.uploadAvatar(body.base64);
    return { code: 0, data };
  }
}
