import { EmailSmtpSender } from './email-smtp.sender';

/**
 * 阿里云邮件推送 SMTP 发送器。
 * 与通用 SMTP 差异仅在于 username 必须为验证过的发信地址。
 */
export class EmailAliyunSender extends EmailSmtpSender {
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
