import {
  Body,
  Controller,
  Get,
  HttpCode,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { JwtGuard } from '../auth/jwt.guard';
import { Throttle } from '@nestjs/throttler';
import { PushSyncDto } from './dto/sync.dto';
import { SyncService } from './sync.service';

@Controller('uapi/sync')
@UseGuards(JwtGuard)
export class SyncController {
  constructor(private readonly svc: SyncService) {}

  @Post('push')
  @HttpCode(200)
  async push(@Req() req: AuthenticatedRequest, @Body() body: PushSyncDto) {
    const data = await this.svc.push(
      req.user!.userId,
      body.changes ?? [],
      body.deviceId,
    );
    return { code: 0, data };
  }

  @Get('pull')
  @Throttle({ default: { limit: 120, ttl: 60_000 } })
  async pull(
    @Req() req: AuthenticatedRequest,
    @Query('cursor') cursor?: string,
    @Query('limit') limit?: string,
  ) {
    const data = await this.svc.pull(
      req.user!.userId,
      cursor ? parseInt(cursor, 10) : 0,
      limit ? parseInt(limit, 10) : 200,
    );
    return { code: 0, data };
  }
}
