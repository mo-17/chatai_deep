import {
  BadRequestException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { isEmail } from 'class-validator';
import { isIP } from 'node:net';
import type { Request } from 'express';

export type CodeChannel = 'email' | 'sms';
export type CodePurpose = 'login' | 'register' | 'bind' | 'reset_password';
export const CODE_PURPOSES: CodePurpose[] = [
  'login',
  'register',
  'bind',
  'reset_password',
];

/** 只规范域名；local-part 大小写与 plus alias 均不合并。 */
export function canonicalIdentifier(
  channel: CodeChannel,
  value: string,
): string {
  if (typeof value !== 'string' || /[\r\n\0]/.test(value))
    throw new BadRequestException('邮箱或手机号格式无效');
  const text = value.trim();
  if (!text || text.length > 320)
    throw new BadRequestException('邮箱或手机号格式无效');
  if (channel === 'email') {
    if (
      !isEmail(text, {
        allow_utf8_local_part: false,
        allow_display_name: false,
      }) ||
      /[<>"\\]/.test(text)
    )
      throw new BadRequestException('邮箱格式无效');
    const at = text.lastIndexOf('@');
    return text.slice(0, at + 1) + text.slice(at + 1).toLowerCase();
  }
  if (channel !== 'sms' || !/^\+\d{1,3}\s?\d{4,15}$/.test(text))
    throw new BadRequestException('手机号格式无效');
  return text;
}

/** 默认仅信任实际连接/Express 的 IP，不自行解析调用方 XFF。 */
export function verificationClientIp(
  req: Pick<Request, 'ip' | 'socket'>,
): string {
  const address = req.ip || req.socket.remoteAddress || '';
  const normalized = address.startsWith('::ffff:') ? address.slice(7) : address;
  return isIP(normalized) ? normalized : 'unknown';
}

export const POLICY_RANGES = {
  codeTtlSeconds: [60, 1800],
  codeResendIntervalSeconds: [30, 600],
  codeMaxAttempts: [1, 10],
  codeDailyLimitPerIdentifier: [1, 100],
  codeHourlyLimitPerIp: [1, 100],
} as const;

export function validateCodePolicy(value: Record<string, unknown>): void {
  for (const [key, [min, max]] of Object.entries(POLICY_RANGES)) {
    const n = value[key];
    if (!Number.isSafeInteger(n) || (n as number) < min || (n as number) > max)
      throw new ServiceUnavailableException('验证码策略配置无效，请联系管理员');
  }
}

export function assertCodeScope(
  channel: CodeChannel,
  purpose: CodePurpose,
): void {
  if (!['email', 'sms'].includes(channel) || !CODE_PURPOSES.includes(purpose))
    throw new BadRequestException('验证码通道或用途无效');
}
