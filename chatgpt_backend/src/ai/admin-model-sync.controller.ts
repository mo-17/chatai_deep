import {
  ArgumentsHost,
  Body,
  Catch,
  Controller,
  ExceptionFilter,
  HttpException,
  Logger,
  Param,
  ParseIntPipe,
  Post,
  Req,
  UseFilters,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import type { AuthenticatedRequest } from '../auth/jwt.guard';
import { AdminGuard } from '../auth/admin.guard';
import { AdminModelSyncService } from './admin-model-sync.service';
import { ImportModelsDto } from './dto/model-sync.dto';
import { ModelSyncError, SYNC_MESSAGES } from './model-discovery';

/** 局部安全边界同时覆盖 guard、DTO 与未知异常；不改其它管理路由的过滤器。 */
@Catch()
export class ModelSyncExceptionFilter implements ExceptionFilter {
  private readonly logger = new Logger('ModelSync');
  catch(error: unknown, host: ArgumentsHost) {
    const status = error instanceof HttpException ? error.getStatus() : 500;
    let safeCode =
      status === 401
        ? 'authentication_error'
        : status === 403
          ? 'model_sync_forbidden'
          : status === 400
            ? 'model_sync_invalid'
            : 'model_sync_failed';
    let message =
      status === 401
        ? '未登录或登录已过期'
        : status === 403
          ? '需要管理员权限'
          : status === 400
            ? SYNC_MESSAGES.model_sync_invalid
            : SYNC_MESSAGES.model_sync_failed;
    if (error instanceof ModelSyncError) {
      const payload = error.getResponse() as {
        safeCode: keyof typeof SYNC_MESSAGES;
      };
      if (Object.hasOwn(SYNC_MESSAGES, payload.safeCode)) {
        safeCode = payload.safeCode;
        message = SYNC_MESSAGES[payload.safeCode];
      }
    }
    this.logger.error(
      { err: 'model_sync_request_failed', status },
      '模型同步请求未完成',
    );
    host
      .switchToHttp()
      .getResponse<Response>()
      .status(status)
      .json({
        code: -1,
        statusCode: status,
        safeCode,
        message,
        ...(status === 401 ? { authError: true } : {}),
      });
  }
}

@Controller('uapi/admin/ai/providers/:providerId/model-sync')
@UseGuards(AdminGuard)
@UseFilters(ModelSyncExceptionFilter)
export class AdminModelSyncController {
  constructor(private readonly service: AdminModelSyncService) {}
  private owner(req: AuthenticatedRequest) {
    return { userId: req.user!.userId, bearer: req.headers.authorization! };
  }
  @Post('preview')
  async preview(
    @Param('providerId', ParseIntPipe) providerId: number,
    @Req() req: AuthenticatedRequest,
  ) {
    return {
      code: 0,
      data: await this.service.preview(providerId, this.owner(req)),
    };
  }
  @Post('import')
  async import(
    @Param('providerId', ParseIntPipe) providerId: number,
    @Req() req: AuthenticatedRequest,
    @Body() body: ImportModelsDto,
  ) {
    return {
      code: 0,
      data: await this.service.import(
        providerId,
        this.owner(req),
        body.previewId,
        body.modelIds,
      ),
    };
  }
}
