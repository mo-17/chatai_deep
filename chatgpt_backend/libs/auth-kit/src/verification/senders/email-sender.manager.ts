import {
  Injectable,
  Logger,
  OnModuleInit,
  OnApplicationShutdown,
  Optional,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { SmtpProvider } from '../entities/smtp-provider.entity';
import { IEmailSender } from './email-sender.interface';
import { EmailSmtpSender } from './email-smtp.sender';
import { EmailAliyunSender } from './email-aliyun.sender';
import { EmailTencentSender } from './email-tencent.sender';
import * as crypto from 'crypto';
import { requireAppSecretKey } from '../../security/app-secret';
import { MicrosoftSmtpConnection } from '../../microsoft/microsoft-smtp.entities';
import { MicrosoftSmtpService } from '../../microsoft/microsoft-smtp.service';
import { EmailMicrosoftSender } from './email-microsoft.sender';
import { MailDeliveryError } from './mail-delivery.error';

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
export class EmailSenderManager implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger('EmailSenderManager');
  private cachedSender: {
    key: string;
    fingerprint: string;
    sender: IEmailSender;
  } | null = null;
  private readonly appSecret: Buffer;

  constructor(
    @InjectRepository(SmtpProvider)
    private readonly smtpRepo: Repository<SmtpProvider>,
    @Optional() private readonly microsoft?: MicrosoftSmtpService,
  ) {
    const appSecretKey = requireAppSecretKey(process.env.APP_SECRET_KEY);
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
      throw new MailDeliveryError('smtp_not_configured', 'failed');
    }
    const sender = this.senderFor(provider);
    return { key: provider.key, sender, provider };
  }

  /** 正式与测试发信共用构造入口；指纹覆盖同 key 更新和跨实例修改。 */
  senderFor(provider: SmtpProvider): IEmailSender {
    if (provider.authMode === 'microsoft_oauth') {
      if (provider.key !== 'generic' || !this.microsoft)
        throw new MailDeliveryError(
          'microsoft_authorization_unavailable',
          'failed',
        );
      return new EmailMicrosoftSender(provider, this.microsoft);
    }
    if (
      !provider.host ||
      !provider.username ||
      !provider.passwordEncrypted ||
      !provider.fromAddress
    )
      throw new MailDeliveryError('smtp_not_configured', 'failed');
    const fingerprint = crypto
      .createHash('sha256')
      .update(
        JSON.stringify([
          provider.configRevision,
          provider.host,
          provider.port,
          provider.secure,
          provider.username,
          provider.passwordEncrypted,
          provider.fromName,
          provider.fromAddress,
        ]),
      )
      .digest('hex');
    if (
      this.cachedSender?.key !== provider.key ||
      this.cachedSender.fingerprint !== fingerprint
    ) {
      this.invalidate();
      let password: string;
      try {
        password = this.decrypt(provider.passwordEncrypted);
      } catch {
        throw new MailDeliveryError('smtp_configuration_invalid', 'failed');
      }
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
      this.cachedSender = { key: provider.key, fingerprint, sender };
    }
    return this.cachedSender.sender;
  }

  invalidate(key?: string): void {
    if (!key || this.cachedSender?.key === key) {
      this.cachedSender?.sender.close?.();
      this.cachedSender = null;
    }
  }

  /** 发送邮件（使用当前启用的服务商） */
  async send(to: string, subject: string, html: string): Promise<void> {
    const { sender } = await this.getSender();
    await sender.send(to, subject, html);
  }

  /** 切换到指定服务商（事务内把旧 enabled 置 false，新置 true，清内存缓存） */
  async activate(key: string): Promise<void> {
    await this.smtpRepo.manager.transaction(async (manager) => {
      await manager.query('SELECT pg_advisory_xact_lock(178409,1)');
      const provider = await manager.findOne(SmtpProvider, {
        where: { key: key as SmtpProvider['key'] },
        lock: { mode: 'pessimistic_write' },
      });
      if (!provider)
        throw new MailDeliveryError('smtp_configuration_invalid', 'failed');
      if (provider.authMode === 'microsoft_oauth') {
        if (!this.microsoft)
          throw new MailDeliveryError(
            'microsoft_authorization_unavailable',
            'failed',
          );
        await this.microsoft.activationReady(manager, provider);
        const c = await manager.findOne(MicrosoftSmtpConnection, {
          where: { providerId: provider.id },
        });
        if (
          !c ||
          c.status !== 'connected' ||
          c.configRevision !== provider.configRevision ||
          !c.refreshEncrypted ||
          !provider.microsoftClientId ||
          !provider.microsoftClientSecretEncrypted
        )
          throw new MailDeliveryError(
            'microsoft_authorization_unavailable',
            'failed',
          );
      } else this.senderFor(provider);
      await manager.update(SmtpProvider, { enabled: true }, { enabled: false });
      await manager.update(SmtpProvider, { key }, { enabled: true });
    });
    this.invalidate();
    this.microsoft?.invalidate();
    this.logger.log(`SMTP 服务商已切换至: ${key}`);
  }

  onApplicationShutdown(): void {
    this.invalidate();
    this.microsoft?.invalidate();
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
