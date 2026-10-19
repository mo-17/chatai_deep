import {
  Body,
  Controller,
  Get,
  Param,
  ParseIntPipe,
  Patch,
  Post,
  Query,
  Req,
  UseGuards,
  BadRequestException,
} from '@nestjs/common';
import { JwtGuard, type AuthenticatedRequest } from '../auth/jwt.guard';
import { AdminGuard } from '../auth/admin.guard';
import {
  FeedbackService,
  ReplyFeedbackDto,
  SubmitFeedbackDto,
} from './feedback.service';
function pageNumber(value?: string) {
  const page = value === undefined ? 1 : Number(value);
  if (!Number.isInteger(page) || page < 1 || page > 100000)
    throw new BadRequestException('页码无效');
  return page;
}
@Controller('uapi')
export class FeedbackController {
  constructor(private readonly service: FeedbackService) {}
  @Post('feedback')
  @UseGuards(JwtGuard)
  async submit(
    @Req() req: AuthenticatedRequest,
    @Body() body: SubmitFeedbackDto,
  ) {
    return { code: 0, data: await this.service.submit(req.user!.userId, body) };
  }
  @Get('feedback')
  @UseGuards(JwtGuard)
  async mine(@Req() req: AuthenticatedRequest, @Query('page') page?: string) {
    return {
      code: 0,
      data: await this.service.list(req.user!.userId, pageNumber(page)),
    };
  }
  @Get('admin/feedback')
  @UseGuards(AdminGuard)
  async all(@Query('page') page?: string) {
    return {
      code: 0,
      data: await this.service.list(undefined, pageNumber(page)),
    };
  }
  @Patch('admin/feedback/:id')
  @UseGuards(AdminGuard)
  async reply(
    @Param('id', ParseIntPipe) id: number,
    @Body() body: ReplyFeedbackDto,
  ) {
    return { code: 0, data: await this.service.reply(id, body) };
  }
}
