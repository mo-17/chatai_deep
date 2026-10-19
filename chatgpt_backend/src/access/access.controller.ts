import { Body, Controller, Get, Patch, Req, UseGuards } from '@nestjs/common';
import { AccessService } from './access.service';
import { JwtGuard, type AuthenticatedRequest } from '../auth/jwt.guard';
import { AdminGuard } from '../auth/admin.guard';

@Controller('uapi')
export class AccessController {
  constructor(private readonly service: AccessService) {}
  @Get('account/usage')
  @UseGuards(JwtGuard)
  async usage(@Req() req: AuthenticatedRequest) {
    return { code: 0, data: await this.service.status(req.user!.userId) };
  }
  @Get('admin/access-policy')
  @UseGuards(AdminGuard)
  async getPolicy() {
    return { code: 0, data: await this.service.policy() };
  }
  @Patch('admin/access-policy')
  @UseGuards(AdminGuard)
  async setPolicy(@Body() body: Record<string, unknown>) {
    return { code: 0, data: await this.service.update(body) };
  }
}
