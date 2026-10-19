import { Controller, Get, Header, UseGuards } from '@nestjs/common';
import { AdminGuard } from '../auth/admin.guard';
import { OperationsService } from './operations.service';

@Controller('uapi/admin/operations')
@UseGuards(AdminGuard)
export class OperationsController {
  constructor(private readonly service: OperationsService) {}
  @Get()
  @Header('Cache-Control', 'no-store')
  async snapshot() {
    return { code: 0, data: await this.service.snapshot() };
  }
}
