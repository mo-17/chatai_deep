import { Controller, Get, Query } from '@nestjs/common';
import { UpdateService } from './update.service';

@Controller('uapi')
export class UpdateController {
  constructor(private readonly updateService: UpdateService) {}

  @Get('checkUpdate')
  checkUpdate(@Query('cid') cid?: string, @Query('version') version?: string) {
    return this.updateService.checkUpdate(cid || 'all', version);
  }
}
