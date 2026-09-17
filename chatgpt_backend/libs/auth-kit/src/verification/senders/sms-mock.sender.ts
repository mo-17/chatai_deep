import { ISmsSender } from './sms-sender.interface';
import { ServiceUnavailableException } from '@nestjs/common';

/**
 * SMS 尚未配置真实服务商时 fail-closed，绝不输出或接受明文验证码。
 */
export class SmsMockSender implements ISmsSender {
  send(_phoneNumber: string, _code: string): Promise<void> {
    return Promise.reject(
      new ServiceUnavailableException('短信验证码服务尚未配置'),
    );
  }
}
