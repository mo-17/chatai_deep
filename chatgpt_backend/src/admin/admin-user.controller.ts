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
import { AdminUserService } from './admin-user.service';
import { AdminGuard } from '../auth/admin.guard';
import { UpdateUserDto } from './dto/update-user.dto';
import { ResetPasswordDto } from './dto/reset-password.dto';

@Controller('uapi/admin/users')
@UseGuards(AdminGuard)
export class AdminUserController {
  constructor(private readonly svc: AdminUserService) {}

  @Get()
  async list(
    @Query('keyword') keyword?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
    @Query('role') role?: string,
    @Query('banned') banned?: string,
  ) {
    const data = await this.svc.list({
      keyword,
      page: parseInt(page || '1', 10),
      pageSize: parseInt(pageSize || '10', 10),
      role,
      banned,
    });
    return { code: 0, data };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const data = await this.svc.detail(parseInt(id, 10));
    return { code: 0, data };
  }

  @Patch(':id')
  async edit(
    @Param('id') id: string,
    @Body() body: UpdateUserDto,
  ) {
    const data = await this.svc.edit(parseInt(id, 10), body);
    return { code: 0, data };
  }

  @Post(':id/reset-password')
  async resetPassword(
    @Param('id') id: string,
    @Body() body: ResetPasswordDto,
  ) {
    await this.svc.resetPassword(parseInt(id, 10), body.password);
    return { code: 0, data: null };
  }

  @Delete(':id')
  async delete(@Param('id') id: string) {
    await this.svc.delete(parseInt(id, 10));
    return { code: 0, data: null };
  }
}
