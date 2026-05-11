import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { SmtpProvider } from '../entities/smtp-provider.entity';
import { IEmailSender } from './email-sender.interface';
import { EmailSmtpSender } from './email-smtp.sender';
import { EmailAliyunSender } from './email-aliyun.sender';
import { EmailTencentSender } from './email-tencent.sender';
import * as crypto from 'crypto';

/**
 * 邮件发送管理器 —— 运行时根据 smtp_providers.enabled=true 的记录路由到具体实现。
 * 切换服务商时调用 activate(key) 在事务内切换 enabled 状态。
 */
@Injectable()
export class EmailSenderManager {
  private readonly logger = new Logger('EmailSenderManager');
  private cachedSender: { key: string; sender: IEmailSender } | null = null;
  private readonly appSecret: Buffer;

  constructor(
    @InjectRepository(SmtpProvider)
    private readonly smtpRepo: Repository<SmtpProvider>,
  ) {
    const appSecretKey =
      process.env.APP_SECRET_KEY ?? 'CHANGE_ME_CHANGE_ME_CHANGE_ME_32B';
    if (!appSecretKey || appSecretKey.length < 32) {
      throw new Error('APP_SECRET_KEY 必须配置且 ≥ 32 字节');
    }
    this.appSecret = Buffer.from(appSecretKey, 'utf-8');
  }

  /** 获取当前启用的发送器 */
  async getSender(): Promise<{
    key: string;
    sender: IEmailSender;
    provider: SmtpProvider;
  }> {
    const provider = await this.smtpRepo.findOne({ where: { enabled: true } });
    if (!provider) {
      throw new Error('没有启用的 SMTP 服务商，请在管理后台启用一个');
    }
    // 缓存键变化时重建 sender
    if (this.cachedSender?.key !== provider.key) {
      const password = this.decrypt(provider.passwordEncrypted);
      const baseConfig = {
        host: provider.host,
        port: provider.port,
        secure: provider.secure,
        user: provider.username,
        pass: password,
        fromName: provider.fromName,
        fromAddress: provider.fromAddress,
      };
      let sender: IEmailSender;
      switch (provider.key) {
        case 'aliyun_dm':
          sender = new EmailAliyunSender(baseConfig);
          break;
        case 'tencent_ses':
          sender = new EmailTencentSender(baseConfig);
          break;
        default:
          sender = new EmailSmtpSender(baseConfig);
      }
      this.cachedSender = { key: provider.key, sender };
    }
    return { key: provider.key, sender: this.cachedSender.sender, provider };
  }

  /** 发送邮件（使用当前启用的服务商） */
  async send(to: string, subject: string, html: string): Promise<void> {
    const { sender } = await this.getSender();
    await sender.send(to, subject, html);
  }

  /** 切换到指定服务商（事务内把旧 enabled 置 false，新置 true，清内存缓存） */
  async activate(key: string): Promise<void> {
    await this.smtpRepo.manager.transaction(async (manager) => {
      await manager.update(SmtpProvider, { enabled: true }, { enabled: false });
      await manager.update(SmtpProvider, { key }, { enabled: true });
    });
    this.cachedSender = null;
    this.logger.log(`SMTP 服务商已切换至: ${key}`);
  }

  /** AES-256-GCM 解密 */
  private decrypt(encrypted: string): string {
    const parts = encrypted.split(':');
    if (parts.length !== 3) {
      throw new Error('加密数据格式无效');
    }
    const [ivHex, authTagHex, dataHex] = parts;
    const iv = Buffer.from(ivHex, 'hex');
    const authTag = Buffer.from(authTagHex, 'hex');
    const decipher = crypto.createDecipheriv('aes-256-gcm', this.appSecret, iv);
    decipher.setAuthTag(authTag);
    let decrypted = decipher.update(dataHex, 'hex', 'utf-8');
    decrypted += decipher.final('utf-8');
    return decrypted;
  }
}
