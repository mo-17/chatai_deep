import { Controller, Get, Query } from '@nestjs/common';
import { UpdateService } from './update.service';

@Controller('uapi')
export class UpdateController {
  constructor(private readonly updateService: UpdateService) {}

  @Get('checkUpdate')
  checkUpdate(
    @Query('cid') cid?: string,
    @Query('version') version?: string,
    @Query('versionCode') versionCode?: string,
    @Query('channel') channel?: string,
    @Query('platform') platform?: string,
    @Query('installationId') installationId?: string,
    @Query('abi') abi?: string,
  ) {
    return this.updateService.checkUpdate(
      cid || 'all',
      version,
      versionCode,
      channel,
      platform,
      installationId,
      abi,
    );
  }
}
