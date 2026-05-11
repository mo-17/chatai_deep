import * as nodemailer from 'nodemailer';
import { IEmailSender } from './email-sender.interface';

/**
 * 通用 SMTP 邮件发送器（nodemailer）。
 * 适用于 QQ / 163 / Gmail / 自建 SMTP 等标准服务。
 */
export class EmailSmtpSender implements IEmailSender {
  private transporter: nodemailer.Transporter;

  constructor(config: {
    host: string;
    port: number;
    secure: boolean;
    user: string;
    pass: string;
    fromName: string;
    fromAddress: string;
  }) {
    this.transporter = nodemailer.createTransport({
      host: config.host,
      port: config.port,
      secure: config.secure,
      auth: { user: config.user, pass: config.pass },
    });
  }

  async send(to: string, subject: string, html: string): Promise<void> {
    await this.transporter.sendMail({
      from:
        this.transporter.options.from ?? `"${this.transporter.options.from}"`,
      to,
      subject,
      html,
    });
  }
}
