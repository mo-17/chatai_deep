import { Controller, Get, Post, Query, Body } from '@nestjs/common';

@Controller('uapi/test')
export class TestController {
  @Get('test')
  getTest(@Query('requestPrams') requestPrams?: string) {
    return {
      code: 0,
      data: { message: 'GET test ok', requestPrams },
    };
  }

  @Post('test')
  postTest(@Body() body?: Record<string, unknown>) {
    return {
      code: 0,
      data: { message: 'POST test ok', body },
    };
  }

  @Get('testJson')
  getTestJson() {
    return {
      code: 0,
      data: { message: 'testJson ok', timestamp: new Date().toISOString() },
    };
  }
}
