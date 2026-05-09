import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  Logger,
} from '@nestjs/common';
import { Request, Response } from 'express';

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('ExceptionFilter');

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse<Response>();
    const req = ctx.getRequest<Request>();

    const isHttp = exception instanceof HttpException;
    const status = isHttp ? exception.getStatus() : 500;
    const body = isHttp ? exception.getResponse() : { message: '服务器内部错误' };

    const payload =
      typeof body === 'object'
        ? (body as Record<string, unknown>)
        : { message: String(body) };

    this.logger.error(
      {
        err: exception instanceof Error ? exception.message : String(exception),
        method: req.method,
        url: req.url,
        status,
      },
      `${req.method} ${req.url} -> ${status}`,
    );

    res.status(status).json({
      code: -1,
      message: (payload['message'] as string) || 'unknown',
      error: status >= 500 ? undefined : payload,
    });
  }
}
