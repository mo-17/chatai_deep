import { EmailSmtpSender } from './email-smtp.sender';

/**
 * 腾讯云 SES SMTP 发送器。
 * 与通用 SMTP 接口一致。
 */
export class EmailTencentSender extends EmailSmtpSender {
  constructor(config: {
    host: string;
    port: number;
    secure: boolean;
    user: string;
    pass: string;
    fromName: string;
    fromAddress: string;
  }) {
    super(config);
  }
}
