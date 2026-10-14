import {
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Post,
  Req,
  Res,
  UseGuards,
  ServiceUnavailableException,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { AuthKitAdminGuard } from '../guards/auth-kit-auth.guard';
import type { AuthenticatedPrincipal } from '../contracts/access-token-verifier.interface';
import {
  MicrosoftSmtpService,
  type MicrosoftSession,
} from './microsoft-smtp.service';
import { MicrosoftSmtpError } from './microsoft-smtp.transport';
export const MICROSOFT_FLOW_COOKIE = '__Host-ms-smtp-flow';
function session(req: Request): MicrosoftSession {
  const bearer =
    /^Bearer\s+(\S+)\s*$/i.exec(req.headers.authorization ?? '')?.[1] ?? '';
  const values = (req.headers.cookie ?? '')
    .split(';')
    .map((v) => v.trim())
    .filter((v) => v.startsWith(MICROSOFT_FLOW_COOKIE + '='));
  const cookie =
    values.length === 1
      ? values[0].slice(MICROSOFT_FLOW_COOKIE.length + 1)
      : '';
  return {
    principal: (req as Request & { user: AuthenticatedPrincipal }).user,
    bearer,
    cookie,
  };
}
async function safe<T>(action: () => Promise<T>): Promise<T> {
  try {
    return await action();
  } catch (e) {
    throw new ServiceUnavailableException(
      e instanceof MicrosoftSmtpError
        ? e.safeCode
        : 'microsoft_service_unavailable',
    );
  }
}
@Controller('uapi/admin/auth/providers/generic/microsoft')
@UseGuards(AuthKitAdminGuard)
export class MicrosoftSmtpAdminController {
  constructor(private readonly service: MicrosoftSmtpService) {}
  @Post('start')
  @HttpCode(200)
  async start(@Req() req: Request, @Res({ passthrough: true }) res: Response) {
    return safe(async () => {
      this.service.origin(req.headers.origin);
      const result = await this.service.start(session(req));
      res.cookie(MICROSOFT_FLOW_COOKIE, result.cookie, {
        httpOnly: true,
        secure: true,
        sameSite: 'lax',
        path: '/',
        maxAge: Math.max(0, result.expiresAt - Date.now()),
      });
      return {
        code: 0,
        data: {
          flowId: result.flowId,
          authorizeUrl: result.authorizeUrl,
          expiresAt: result.expiresAt,
        },
      };
    });
  }
  @Post('complete/:flowId')
  @HttpCode(200)
  async complete(@Param('flowId') id: string, @Req() req: Request) {
    return safe(async () => {
      this.service.origin(req.headers.origin);
      return { code: 0, data: await this.service.complete(id, session(req)) };
    });
  }
  @Get('flow/:flowId')
  async flow(@Param('flowId') id: string, @Req() req: Request) {
    return safe(async () => ({
      code: 0,
      data: await this.service.flowStatus(id, session(req)),
    }));
  }
  @Get('status') async status() {
    return safe(async () => ({ code: 0, data: await this.service.status() }));
  }
  @Post('disconnect')
  @HttpCode(200)
  async disconnect(
    @Req() req: Request,
    @Res({ passthrough: true }) res: Response,
  ) {
    return safe(async () => {
      this.service.origin(req.headers.origin);
      await this.service.disconnect(session(req));
      res.clearCookie(MICROSOFT_FLOW_COOKIE, {
        httpOnly: true,
        secure: true,
        sameSite: 'lax',
        path: '/',
      });
      return { code: 0, data: null };
    });
  }
}
/** 此公开回调绝不兑换code；跨站POST不依赖SameSite cookie。 */
@Controller('uapi/auth/microsoft')
export class MicrosoftSmtpCallbackController {
  constructor(private readonly service: MicrosoftSmtpService) {}
  @Post('callback')
  async callback(@Body() body: unknown, @Res() res: Response) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    // 成功、取消、无效与重放均回固定同源结果页，URL从不携code/state。
    try {
      if (body && typeof body === 'object' && !Array.isArray(body)) {
        const b = body as Record<string, unknown>;
        if (
          typeof b.state === 'string' &&
          (typeof b.code === 'string' || typeof b.error === 'string')
        )
          await this.service.callback(
            b.state,
            typeof b.code === 'string' ? b.code : undefined,
            typeof b.error === 'string',
          );
      }
    } catch {
      /* 结果由原管理员authenticated status/complete读取。 */
    }
    res.redirect(
      303,
      new URL('/auth/microsoft/result', this.service.redirectUri()).href,
    );
  }
}
