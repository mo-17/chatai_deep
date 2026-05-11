import { ISmsSender } from './sms-sender.interface';
import { Logger } from '@nestjs/common';

/**
 * SMS Mock 发送器 — 仅 console.log 验证码。
 * 正式接入阿里云/腾讯云后替换此实现即可。
 */
export class SmsMockSender implements ISmsSender {
  private readonly logger = new Logger('SmsMock');

  send(phoneNumber: string, code: string): Promise<void> {
    this.logger.warn(`[MOCK SMS] 收件人: ${phoneNumber} | 验证码: ${code}`);
    return Promise.resolve();
  }
}
