import { Controller, Get, Query } from '@nestjs/common';
import { NoticeService } from './notice.service';

@Controller('uapi/notice')
export class NoticeController {
  constructor(private readonly noticeService: NoticeService) {}

  @Get('banner')
  getBanners(
    @Query('pageIndex') pageIndex?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    const p = parseInt(pageIndex || '1', 10) || 1;
    const s = parseInt(pageSize || '10', 10) || 10;
    return this.noticeService.getBanners(p, s);
  }
}
