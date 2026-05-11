import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { SmtpProvider } from '../entities/smtp-provider.entity';
import { IEmailSender } from './email-sender.interface';
import { EmailSmtpSender } from './email-smtp.sender';
import { EmailAliyunSender } from './email-aliyun.sender';
import { EmailTencentSender } from './email-tencent.sender';
import * as crypto from 'crypto';

/** 启动时为 ak_smtp_providers 预置的 3 个 slot（仅当对应 key 不存在时插入）。 */
const PROVIDER_SEEDS: Array<
  Pick<SmtpProvider, 'key' | 'displayName' | 'host' | 'port' | 'secure'>
> = [
  {
    key: 'generic',
    displayName: '通用 SMTP',
    host: '',
    port: 587,
    secure: false,
  },
  {
    key: 'aliyun_dm',
    displayName: '阿里云邮件推送',
    host: 'smtpdm.aliyun.com',
    port: 465,
    secure: true,
  },
  {
    key: 'tencent_ses',
    displayName: '腾讯云 SES',
    host: 'smtp.ses.tencent-cloud.com',
    port: 465,
    secure: true,
  },
];

/**
 * 邮件发送管理器 —— 运行时根据 smtp_providers.enabled=true 的记录路由到具体实现。
 * 切换服务商时调用 activate(key) 在事务内切换 enabled 状态。
 */
@Injectable()
export class EmailSenderManager implements OnModuleInit {
  private readonly logger = new Logger('EmailSenderManager');
  private cachedSender: { key: string; sender: IEmailSender } | null = null;
  private readonly appSecret: Buffer;

  constructor(
    @InjectRepository(SmtpProvider)
    private readonly smtpRepo: Repository<SmtpProvider>,
  ) {
    const appSecretKey =
      process.env.APP_SECRET_KEY ?? 'CHANGE_ME_CHANGE_ME_CHANGE_ME_32B';
    if (!appSecretKey || appSecretKey.length < 16) {
      throw new Error('APP_SECRET_KEY 必须配置且 ≥ 16 字符');
    }
    this.appSecret = crypto.createHash('sha256').update(appSecretKey).digest();
  }

  /** 启动时确保 3 个 slot 都存在；缺哪条补哪条，已有的不动。 */
  async onModuleInit(): Promise<void> {
    const existing = await this.smtpRepo.find({ select: ['key'] });
    const existingKeys = new Set(existing.map((p) => p.key));
    const toCreate = PROVIDER_SEEDS.filter((s) => !existingKeys.has(s.key));
    if (toCreate.length === 0) return;
    const rows = toCreate.map((s) =>
      this.smtpRepo.create({
        ...s,
        username: '',
        passwordEncrypted: '',
        fromName: '',
        fromAddress: '',
        enabled: false,
      }),
    );
    await this.smtpRepo.save(rows);
    this.logger.log(
      `已补齐 SMTP 服务商占位记录: ${toCreate.map((s) => s.key).join(', ')}`,
    );
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
