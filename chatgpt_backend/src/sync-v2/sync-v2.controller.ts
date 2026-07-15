import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { JwtGuard } from '../auth/jwt.guard';
import { PushSyncV2Dto } from './dto/sync-v2.dto';
import { SyncV2AccessPolicy } from './sync-v2-access.policy';
import { SYNC_V2_LIMITS } from './sync-v2.constants';
import { SyncV2Service } from './sync-v2.service';

@Controller('uapi/sync/v2')
@UseGuards(JwtGuard)
export class SyncV2Controller {
  constructor(
    private readonly service: SyncV2Service,
    private readonly accessPolicy: SyncV2AccessPolicy,
  ) {}

  @Get('capabilities')
  capabilities(@Req() request: AuthenticatedRequest) {
    return {
      code: 0,
      data: {
        ...this.service.capabilities(),
        shadowAccessEnabled: this.accessPolicy.isAllowed(request.user!.userId),
      },
    };
  }

  @Post('push')
  @HttpCode(200)
  @Throttle({ default: { limit: 120, ttl: 60_000 } })
  async push(
    @Req() request: AuthenticatedRequest,
    @Body() body: PushSyncV2Dto,
  ) {
    this.accessPolicy.assertAllowed(request.user!.userId);
    const data = await this.service.push(request.user!.userId, body);
    return { code: 0, data };
  }

  @Get('pull')
  @Throttle({ default: { limit: 120, ttl: 60_000 } })
  async pull(
    @Req() request: AuthenticatedRequest,
    @Query('cursor') cursor = '0',
    @Query('limit') limit?: string,
  ) {
    this.accessPolicy.assertAllowed(request.user!.userId);
    const data = await this.service.pull(
      request.user!.userId,
      cursor,
      this.parseLimit(limit),
    );
    return { code: 0, data };
  }

  private parseLimit(value?: string) {
    if (value === undefined || value === '') {
      return SYNC_V2_LIMITS.defaultPullLimit;
    }
    if (!/^[1-9]\d*$/.test(value)) {
      throw new BadRequestException('limit 必须是正整数');
    }
    const parsed = BigInt(value);
    return parsed > BigInt(SYNC_V2_LIMITS.maxPullLimit)
      ? SYNC_V2_LIMITS.maxPullLimit
      : Number(parsed);
  }
}
