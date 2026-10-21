import {
  BadRequestException,
  CallHandler,
  Controller,
  Delete,
  ExecutionContext,
  Get,
  Injectable,
  NestInterceptor,
  Param,
  PayloadTooLargeException,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { raw, type Response } from 'express';
import { from, mergeMap } from 'rxjs';
import { JwtGuard, type AuthenticatedRequest } from '../auth/jwt.guard';
import { OcrService } from './ocr.service';

/** 在 JWT guard 之后才读取原始二进制；不扩大其它路由的 JSON 上限。 */
@Injectable()
export class OcrUploadInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler) {
    const req = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const res = context.switchToHttp().getResponse<Response>();
    if (req.headers['content-type'] !== 'application/octet-stream')
      throw new BadRequestException('OCR 需要二进制文件');
    const read = new Promise<void>((resolve, reject) => {
      raw({
        type: 'application/octet-stream',
        limit: 8 * 1024 * 1024,
        inflate: false,
      })(req, res, (error?: unknown) => {
        if (error) {
          reject(
            new PayloadTooLargeException(
              'OCR 文件无法读取，单个文件最多 8 MiB',
            ),
          );
        } else if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
          reject(new BadRequestException('OCR 文件为空'));
        } else resolve();
      });
    });
    return from(read).pipe(mergeMap(() => next.handle()));
  }
}

@Controller('uapi/ocr')
@UseGuards(JwtGuard)
@Throttle({ default: { limit: 120, ttl: 60_000 } })
export class OcrController {
  constructor(private readonly service: OcrService) {}

  private owner(req: AuthenticatedRequest) {
    return `${req.user!.role === 'admin' ? 'admin' : 'user'}:${req.user!.userId}`;
  }
  private jobPath(id: string) {
    if (!/^[a-f0-9]{32}$/.test(id))
      throw new BadRequestException('OCR 任务编号无效');
    return `/jobs/${id}`;
  }
  @Get('capabilities')
  async capabilities(
    @Req() req: AuthenticatedRequest,
    @Res({ passthrough: true }) res: Response,
  ) {
    res.setHeader('Cache-Control', 'no-store');
    return {
      code: 0,
      data: await this.service.request(this.owner(req), '/health'),
    };
  }
  @Post('jobs/:id')
  @Throttle({ default: { limit: 6, ttl: 60_000 } })
  @UseInterceptors(OcrUploadInterceptor)
  async create(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Query('kind') kind?: string,
    @Query('pages') pages?: string,
    @Query('preview') preview?: string,
  ) {
    const path = this.jobPath(id);
    if (
      !['pdf', 'image'].includes(kind ?? '') ||
      (preview !== undefined && preview !== 'true') ||
      (pages !== undefined &&
        !/^(?:[1-9]|1[0-9]|20)(?:,(?:[1-9]|1[0-9]|20)){0,19}$/.test(pages))
    )
      throw new BadRequestException('OCR 类型或页码无效');
    const query = new URLSearchParams({ kind: kind! });
    if (pages) query.set('pages', pages);
    if (preview) query.set('preview', preview);
    return {
      code: 0,
      data: await this.service.request(
        this.owner(req),
        `${path}?${query}`,
        'PUT',
        req.body as Buffer,
      ),
    };
  }
  @Get('jobs/:id')
  async get(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
    @Res({ passthrough: true }) res: Response,
  ) {
    res.setHeader('Cache-Control', 'no-store');
    return {
      code: 0,
      data: await this.service.request(this.owner(req), this.jobPath(id)),
    };
  }
  @Delete('jobs/:id')
  async cancel(@Req() req: AuthenticatedRequest, @Param('id') id: string) {
    return {
      code: 0,
      data: await this.service.request(
        this.owner(req),
        this.jobPath(id),
        'DELETE',
      ),
    };
  }
}
