import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  Logger,
} from '@nestjs/common';
import { isAuthPath, logUrl } from './auth-log-safety';
import { MICROSOFT_CLIENT_ID_INVALID } from '../../libs/auth-kit/src/controllers/admin-auth.dto';
import { Request, Response } from 'express';

interface AuthFeedback {
  message: string;
  errorCode?: string;
}
/** 精确常量白名单，不接受任意HttpException payload、前后缀或provider原文。 */
const AUTH_FEEDBACK = new Map<string, string>([
  ['验证码已过期，请重新获取', 'AUTH_CODE_EXPIRED'],
  ['验证码无效或已失效', 'AUTH_CODE_INVALID'],
  ['验证码错误次数过多，已锁定，请重新获取', 'AUTH_CODE_LOCKED'],
  ['请稍后再发送验证码', 'AUTH_CODE_RESEND_WAIT'],
  ['验证码为 6 位数字', 'AUTH_CODE_FORMAT'],
  ['验证码未发送成功，请稍后重试', 'AUTH_CODE_SEND_FAILED'],
  ['验证码投递状态未知或已失效，请稍后明确重新获取', 'AUTH_CODE_SEND_UNKNOWN'],
  ['该连接 IP 发送次数已达一小时上限', 'AUTH_CODE_IP_LIMIT'],
  ['该标识今日发送次数已达上限（UTC）', 'AUTH_CODE_DAILY_LIMIT'],
  ['该账号未设置密码，请使用验证码登录', 'AUTH_PASSWORD_UNSET'],
  ['账号或密码错误', 'AUTH_CREDENTIALS_INVALID'],
  ['账号已被封禁', 'AUTH_ACCOUNT_BANNED'],
  ['该账号已注册', 'AUTH_ACCOUNT_EXISTS'],
  ['账号不存在', 'AUTH_ACCOUNT_MISSING'],
  ['登录状态已变化，请重新登录', 'AUTH_SESSION_CHANGED'],
  ['未提供有效的认证令牌', 'AUTH_TOKEN_MISSING'],
  ['令牌无效或已过期', 'AUTH_TOKEN_INVALID'],
  ['需要管理员权限', 'AUTH_ADMIN_REQUIRED'],
  ['邮箱或手机号格式无效', 'AUTH_IDENTIFIER_INVALID'],
  ['邮箱格式无效', 'AUTH_IDENTIFIER_INVALID'],
  ['手机号格式无效', 'AUTH_IDENTIFIER_INVALID'],
  [
    '手机号格式错误，请使用 E.164 格式（如 +8613800000000）',
    'AUTH_IDENTIFIER_INVALID',
  ],
  ['验证码通道或用途无效', 'AUTH_CODE_SCOPE_INVALID'],
  ['参数无效', 'AUTH_INPUT_INVALID'],
  [MICROSOFT_CLIENT_ID_INVALID, 'AUTH_MICROSOFT_CLIENT_ID_INVALID'],
  ['该登录方式暂未开放', 'THIRD_PARTY_DISABLED'],
  ['bindTicket 无效或已过期，请重新登录', 'AUTH_BIND_TICKET_INVALID'],
  ['bindTicket 已使用或与登录方式不匹配', 'AUTH_BIND_TICKET_INVALID'],
  ['请提供 authCode 或 accessToken', 'AUTH_THIRD_PARTY_INPUT'],
  ['该邮箱已被其他账号绑定', 'AUTH_IDENTIFIER_BOUND'],
  ['该手机号已被其他账号绑定', 'AUTH_IDENTIFIER_BOUND'],
  ['历史邮箱记录存在冲突，请联系管理员', 'AUTH_IDENTIFIER_CONFLICT'],
  ['SMTP 密码过长', 'AUTH_SMTP_INPUT'],
  ['微软密钥过长', 'AUTH_SMTP_INPUT'],
  ['仅通用slot支持个人Outlook', 'AUTH_SMTP_INPUT'],
  ['邮件授权不可用', 'AUTH_SMTP_UNAVAILABLE'],
  ['SMTP 配置未就绪，无法启用', 'AUTH_SMTP_NOT_READY'],
  ['SMTP 配置保存失败', 'AUTH_SMTP_SAVE_FAILED'],
  ['邮件测试状态保存失败', 'AUTH_SMTP_TEST_SAVE_FAILED'],
  ['服务商不存在', 'AUTH_SMTP_MISSING'],
  ['未提供有效设置字段', 'AUTH_SETTINGS_INPUT'],
  ['验证码策略配置无效，请联系管理员', 'AUTH_CODE_POLICY_INVALID'],
  ['验证码存储暂不可用，请稍后重试', 'AUTH_CODE_STORAGE_UNAVAILABLE'],
  ['邮件授权服务已停止', 'AUTH_MAIL_SERVICE_STOPPED'],
  ['邮件授权存储暂不可用', 'AUTH_MAIL_STORAGE_UNAVAILABLE'],
]);
const MICROSOFT_FEEDBACK = new Map<string, string>([
  ['microsoft_needs_reauth', '邮箱授权已失效，请重新授权'],
  ['microsoft_authorization_expired', '管理员登录已过期，请重新登录并授权'],
  ['microsoft_authorization_invalid', '邮箱授权会话无效，请重新发起授权'],
  ['microsoft_callback_invalid', '邮箱授权回调无效，请重新发起授权'],
  ['microsoft_connection_stale', '邮箱连接已变化，请重新发起授权'],
  ['microsoft_flow_stale', '邮箱授权流程已失效，请重新发起'],
  ['microsoft_not_configured', '邮箱授权尚未配置，请先保存配置'],
  ['microsoft_redirect_not_configured', '邮箱授权回调尚未配置，请联系管理员'],
  ['microsoft_origin_invalid', '邮箱授权来源无效，请从当前后台重新发起'],
  ['microsoft_refresh_busy', '邮箱授权正在刷新，请稍后再试'],
  ['microsoft_response_unknown', '邮箱授权结果未知，请查看授权状态或重新发起'],
  ['microsoft_temporarily_unavailable', '邮箱授权服务暂不可用，请稍后重试'],
  ['microsoft_service_unavailable', '邮箱授权服务暂不可用，请稍后重试'],
  ['microsoft_service_stopped', '邮箱授权服务已停止，请稍后重试'],
  ...[
    'microsoft_exchange_failed',
    'microsoft_refresh_failed',
    'microsoft_request_failed',
    'microsoft_response_invalid',
    'microsoft_scope_invalid',
    'microsoft_discovery_invalid',
    'microsoft_identity_invalid',
    'microsoft_jwks_invalid',
    'microsoft_identity_changed',
  ].map(
    (code) => [code, '邮箱授权验证失败，请重新发起授权'] as [string, string],
  ),
]);
function authFeedback(body: unknown): AuthFeedback {
  const message =
    typeof body === 'string'
      ? body
      : body && typeof body === 'object' && !Array.isArray(body)
        ? (body as Record<string, unknown>).message
        : undefined;
  // Nest ValidationPipe 的数组仅放行这一条固定提示；混合、未知及带值错误仍隐藏。
  if (Array.isArray(message)) {
    if (message.length === 1 && message[0] === MICROSOFT_CLIENT_ID_INVALID)
      return {
        message: MICROSOFT_CLIENT_ID_INVALID,
        errorCode: 'AUTH_MICROSOFT_CLIENT_ID_INVALID',
      };
    return { message: '认证请求失败' };
  }
  if (typeof message !== 'string') return { message: '认证请求失败' };
  const errorCode = AUTH_FEEDBACK.get(message);
  if (errorCode) return { message, errorCode };
  const remaining = /^验证码错误，剩余 ([1-9]) 次尝试$/.exec(message);
  if (remaining && remaining[0] === message)
    return {
      message: '验证码错误，剩余 ' + remaining[1] + ' 次尝试',
      errorCode: 'AUTH_CODE_ATTEMPTS_REMAINING',
    };
  const microsoft = MICROSOFT_FEEDBACK.get(message);
  if (microsoft) return { message: microsoft, errorCode: message };
  return { message: '认证请求失败' };
}

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('ExceptionFilter');

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse<Response>();
    const req = ctx.getRequest<Request>();

    const authPath = isAuthPath(req.url),
      url = logUrl(req.url);
    const isHttp = exception instanceof HttpException;
    const status = isHttp ? exception.getStatus() : 500;
    const body = isHttp
      ? exception.getResponse()
      : { message: '服务器内部错误' };

    const payload =
      typeof body === 'object'
        ? (body as Record<string, unknown>)
        : { message: String(body) };

    this.logger.error(
      {
        err: authPath
          ? 'authentication_request_failed'
          : exception instanceof Error
            ? exception.message
            : String(exception),
        method: req.method,
        url,
        status,
      },
      `${req.method} ${url} -> ${status}`,
    );

    res.status(status).json({
      code: -1,
      ...(authPath
        ? authFeedback(body)
        : { message: (payload['message'] as string) || 'unknown' }),
      error: authPath || status >= 500 ? undefined : payload,
    });
  }
}
