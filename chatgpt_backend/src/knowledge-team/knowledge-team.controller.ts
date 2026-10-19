import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  ParseIntPipe,
  Post,
  Put,
  Query,
  Req,
  UseGuards,
  BadRequestException,
} from '@nestjs/common';
import { JwtGuard, type AuthenticatedRequest } from '../auth/jwt.guard';
import { KnowledgeTeamService } from './knowledge-team.service';
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new BadRequestException('请求正文无效');
  return value as Record<string, unknown>;
}
@Controller('uapi/knowledge/teams')
@UseGuards(JwtGuard)
export class KnowledgeTeamController {
  constructor(private readonly service: KnowledgeTeamService) {}
  private wrap<T>(data: T) {
    return { code: 0, data };
  }
  @Get() async list(@Req() req: AuthenticatedRequest) {
    return this.wrap(await this.service.list(req.user!.userId));
  }
  @Post() async create(@Req() req: AuthenticatedRequest, @Body() raw: unknown) {
    return this.wrap(
      await this.service.create(req.user!.userId, object(raw).name),
    );
  }
  @Post('join') async join(
    @Req() req: AuthenticatedRequest,
    @Body() raw: unknown,
  ) {
    return this.wrap(
      await this.service.join(req.user!.userId, object(raw).code),
    );
  }
  @Get(':id') async read(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
  ) {
    return this.wrap(await this.service.read(req.user!.userId, id));
  }
  @Post(':id/invites') async invite(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Body() raw: unknown,
  ) {
    return this.wrap(
      await this.service.invite(req.user!.userId, id, object(raw).role),
    );
  }
  @Delete(':id/invites/:inviteId') async cancelInvite(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Param('inviteId') inviteId: string,
  ) {
    return this.wrap(
      await this.service.cancelInvite(req.user!.userId, id, inviteId),
    );
  }
  @Put(':id/members/:member') async member(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Param('member', ParseIntPipe) member: number,
    @Body() raw: unknown,
  ) {
    return this.wrap(
      await this.service.member(req.user!.userId, id, member, object(raw).role),
    );
  }
  @Put(':id/documents/:uid') async put(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Param('uid') uid: string,
    @Body() raw: unknown,
  ) {
    return this.wrap(
      await this.service.putDocument(req.user!.userId, id, uid, object(raw)),
    );
  }
  @Delete(':id/documents/:uid') async remove(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Param('uid') uid: string,
    @Query('revision', ParseIntPipe) revision: number,
  ) {
    return this.wrap(
      await this.service.removeDocument(req.user!.userId, id, uid, revision),
    );
  }
  @Post(':id/answers') async answer(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Body() raw: unknown,
  ) {
    return this.wrap(
      await this.service.saveAnswer(req.user!.userId, id, object(raw)),
    );
  }
  @Get(':id/audit') async audit(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
  ) {
    return this.wrap(await this.service.audit(req.user!.userId, id));
  }
}
