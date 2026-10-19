import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
  HttpException,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import {
  IsIn,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  Length,
} from 'class-validator';
import { UserFeedback } from './feedback.entity';

export class SubmitFeedbackDto {
  @IsUUID() requestId: string;
  @IsIn(['bug', 'suggestion', 'account', 'other']) category: string;
  @IsString() @Length(5, 4000) content: string;
  @IsOptional() @IsObject() diagnostics?: Record<string, unknown>;
}
export class ReplyFeedbackDto {
  @IsIn(['open', 'in_progress', 'resolved', 'closed']) status: string;
  @IsString() @Length(0, 4000) reply: string;
}
export function sanitizeFeedbackDiagnostics(
  value: Record<string, unknown> = {},
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const key of ['appVersion', 'platform', 'locale']) {
    const item = value[key];
    if (typeof item === 'string' && /^[a-zA-Z0-9._+() -]{1,80}$/.test(item))
      result[key] = item;
  }
  return result;
}
@Injectable()
export class FeedbackService {
  constructor(private readonly db: DataSource) {}
  async submit(userId: number, body: SubmitFeedbackDto) {
    const content = body.content.trim();
    if (content.length < 5) throw new BadRequestException('请至少输入 5 个字');
    const diagnostics = sanitizeFeedbackDiagnostics(body.diagnostics);
    return this.db.transaction(async (manager) => {
      await manager.query('SELECT pg_advisory_xact_lock(1128812885, $1)', [
        userId,
      ]);
      const repo = manager.getRepository(UserFeedback);
      const previous = await repo.findOneBy({
        userId,
        requestId: body.requestId,
      });
      if (previous) {
        if (previous.content !== content || previous.category !== body.category)
          throw new ConflictException('请勿复用反馈编号');
        return previous;
      }
      const [daily] = await manager.query<Array<{ count: number }>>(
        'SELECT count(*)::int AS count FROM user_feedback WHERE "userId"=$1 AND "createdAt">=CURRENT_DATE',
        [userId],
      );
      if (daily.count >= 20)
        throw new HttpException('今日反馈数量已达上限', 429);
      return repo.save(
        repo.create({
          userId,
          requestId: body.requestId,
          category: body.category,
          content,
          diagnostics,
        }),
      );
    });
  }
  async list(userId: number | undefined, page = 1) {
    const [list, total] = await this.db
      .getRepository(UserFeedback)
      .findAndCount({
        where: userId === undefined ? {} : { userId },
        order: { createdAt: 'DESC', id: 'DESC' },
        take: 20,
        skip: (page - 1) * 20,
      });
    return { list, total, page, pageSize: 20 };
  }
  async reply(id: number, body: ReplyFeedbackDto) {
    const repo = this.db.getRepository(UserFeedback);
    const item = await repo.findOneBy({ id });
    if (!item) throw new NotFoundException('反馈不存在');
    item.status = body.status;
    item.reply = body.reply.trim();
    return repo.save(item);
  }
}
