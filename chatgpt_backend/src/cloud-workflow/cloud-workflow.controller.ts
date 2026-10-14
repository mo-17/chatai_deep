import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { CloudWorkflowGuard } from './cloud-workflow.guard';
import type { CloudRequest } from './cloud-workflow.guard';
import { CloudWorkflowService } from './cloud-workflow.service';

@Controller('uapi/cloud-workflows')
@UseGuards(CloudWorkflowGuard)
export class CloudWorkflowController {
  constructor(private readonly service: CloudWorkflowService) {}
  @Get('capability')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  capability(@Req() r: CloudRequest) {
    return this.service.capabilities(r.cloudAuthorization);
  }
  @Get('profiles')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  profiles() {
    return this.service.profiles();
  }
  @Get('by-idempotency/:key')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  byIdempotency(@Req() r: CloudRequest, @Param('key') key: string) {
    return this.service.byIdempotency(r.cloudAuthorization, key);
  }
  @Post()
  @Throttle({ default: { limit: 3, ttl: 60000 } })
  create(@Req() r: CloudRequest, @Body() body: unknown) {
    return this.service.create(r.cloudAuthorization, body);
  }
  @Get()
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  list(
    @Req() r: CloudRequest,
    @Query('cursor') cursor?: string,
    @Query('limit') limit?: string,
  ) {
    return this.service.list(r.cloudAuthorization, cursor, limit);
  }
  @Post('revoke-client')
  revoke(@Req() r: CloudRequest, @Body() body: unknown) {
    return this.service.revokeClient(r.cloudAuthorization, body);
  }
  @Get(':id/result')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  result(@Req() r: CloudRequest, @Param('id') id: string) {
    return this.service.results(r.cloudAuthorization, id);
  }
  @Get(':id')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  detail(@Req() r: CloudRequest, @Param('id') id: string) {
    return this.service.detail(r.cloudAuthorization, id);
  }
  @Post(':id/stop')
  stop(@Req() r: CloudRequest, @Param('id') id: string, @Body() body: unknown) {
    return this.service.control(r.cloudAuthorization, id, 'stop', body);
  }
  @Post(':id/continue')
  resume(
    @Req() r: CloudRequest,
    @Param('id') id: string,
    @Body() body: unknown,
  ) {
    return this.service.control(r.cloudAuthorization, id, 'continue', body);
  }
  @Delete(':id')
  remove(
    @Req() r: CloudRequest,
    @Param('id') id: string,
    @Body() body: unknown,
  ) {
    return this.service.control(r.cloudAuthorization, id, 'delete', body);
  }
}
