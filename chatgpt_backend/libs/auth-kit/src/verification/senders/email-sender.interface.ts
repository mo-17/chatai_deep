/** 邮件发送接口，各服务商实现 */
export interface IEmailSender {
  send(to: string, subject: string, html: string): Promise<void>;
}
