import {
  Controller,
  Get,
  Post,
  Put,
  Body,
  Param,
  Query,
  HttpCode,
  NotFoundException,
  Inject,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, Like, FindOptionsWhere } from 'typeorm';
import { SmtpProvider } from '../verification/entities/smtp-provider.entity';
import { VerificationCode } from '../verification/entities/verification-code.entity';
import { EmailTemplate } from '../verification/entities/email-template.entity';
import { AuthSettings } from '../verification/entities/auth-settings.entity';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { EmailSenderManager } from '../verification/senders/email-sender.manager';
import { EmailSmtpSender } from '../verification/senders/email-smtp.sender';
import { AUTH_KIT_OPTIONS } from '../auth-kit.tokens';
import type { AuthKitModuleOptions } from '../auth-kit.module';
import * as crypto from 'crypto';

type SmtpProviderKey = SmtpProvider['key'];

/** AES-256-GCM 加密 */
function encrypt(plain: string, secret: Buffer): string {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-gcm', secret, iv);
  let encrypted = cipher.update(plain, 'utf-8', 'hex');
  encrypted += cipher.final('hex');
  const authTag = cipher.getAuthTag();
  return `${iv.toString('hex')}:${authTag.toString('hex')}:${encrypted}`;
}

/** AES-256-GCM 解密 */
function decrypt(encrypted: string, secret: Buffer): string {
  const parts = encrypted.split(':');
  if (parts.length !== 3) throw new Error('加密数据格式无效');
  const [ivHex, authTagHex, dataHex] = parts;
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    secret,
    Buffer.from(ivHex, 'hex'),
  );
  decipher.setAuthTag(Buffer.from(authTagHex, 'hex'));
  let decrypted = decipher.update(dataHex, 'hex', 'utf-8');
  decrypted += decipher.final('utf-8');
  return decrypted;
}

@Controller('uapi/admin/auth')
export class AdminAuthController {
  private readonly appSecret: Buffer;

  constructor(
    @InjectRepository(SmtpProvider)
    private readonly smtpRepo: Repository<SmtpProvider>,
    @InjectRepository(VerificationCode)
    private readonly codeRepo: Repository<VerificationCode>,
    @InjectRepository(EmailTemplate)
    private readonly templateRepo: Repository<EmailTemplate>,
    private readonly settingsService: AuthSettingsService,
    private readonly emailManager: EmailSenderManager,
    @Inject(AUTH_KIT_OPTIONS) options: AuthKitModuleOptions,
  ) {
    this.appSecret = Buffer.from(options.appSecretKey, 'utf-8');
  }

  // ---- SMTP 服务商 ----

  @Get('providers')
  async listProviders() {
    const list = await this.smtpRepo.find({ order: { id: 'ASC' } });
    const safe = list.map((p) => ({
      ...p,
      passwordEncrypted: p.passwordEncrypted ? '••••••••' : '',
    }));
    return { code: 0, data: safe };
  }

  @Put('providers/:key')
  async updateProvider(
    @Param('key') key: string,
    @Body() body: Partial<SmtpProvider & { password?: string }>,
  ) {
    const provider = await this.smtpRepo.findOne({
      where: { key: key as SmtpProviderKey },
    });
    if (!provider) throw new NotFoundException('服务商不存在');

    if (body.host !== undefined) provider.host = body.host;
    if (body.port !== undefined) provider.port = body.port;
    if (body.secure !== undefined) provider.secure = body.secure;
    if (body.username !== undefined) provider.username = body.username;
    if (body.fromName !== undefined) provider.fromName = body.fromName;
    if (body.fromAddress !== undefined) provider.fromAddress = body.fromAddress;
    if (body.password && body.password !== '••••••••') {
      provider.passwordEncrypted = encrypt(body.password, this.appSecret);
    }

    await this.smtpRepo.save(provider);
    return { code: 0, data: { ...provider, passwordEncrypted: '••••••••' } };
  }

  @Post('providers/:key/activate')
  @HttpCode(200)
  async activateProvider(@Param('key') key: string) {
    await this.emailManager.activate(key);
    return { code: 0, data: null };
  }

  @Post('providers/:key/test')
  @HttpCode(200)
  async testProvider(@Param('key') key: string, @Body() body: { to: string }) {
    const provider = await this.smtpRepo.findOne({
      where: { key: key as SmtpProviderKey },
    });
    if (!provider) throw new NotFoundException('服务商不存在');

    // 使用指定服务商的凭据发测试邮件
    const password = decrypt(provider.passwordEncrypted, this.appSecret);
    const tester = new EmailSmtpSender({
      host: provider.host,
      port: provider.port,
      secure: provider.secure,
      user: provider.username,
      pass: password,
      fromName: provider.fromName,
      fromAddress: provider.fromAddress,
    });

    try {
      await tester.send(
        body.to,
        'ChatAI Deep - 测试邮件',
        '<h2>这是一封测试邮件</h2><p>如果您收到此邮件，说明 SMTP 配置正确。</p>',
      );
      provider.lastTestedAt = new Date();
      provider.lastTestStatus = 'ok';
      provider.lastTestError = null;
    } catch (err) {
      provider.lastTestedAt = new Date();
      provider.lastTestStatus = 'failed';
      provider.lastTestError = (err as Error).message;
    }
    await this.smtpRepo.save(provider);
    return {
      code: 0,
      data: {
        status: provider.lastTestStatus,
        error: provider.lastTestError,
      },
    };
  }

  // ---- 验证码日志 ----

  @Get('codes')
  async listCodes(
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
    @Query('channel') channel?: string,
    @Query('identifier') identifier?: string,
    @Query('purpose') purpose?: string,
  ) {
    const p = Math.max(parseInt(page ?? '1', 10), 1);
    const ps = Math.min(Math.max(parseInt(pageSize ?? '20', 10), 1), 100);
    const where: Record<string, unknown> = {};
    if (channel) where['channel'] = channel;
    if (identifier)
      where['identifier'] = Like(
        `%${identifier.replace(/[\\%_]/g, (c) => '\\' + c)}%`,
      );
    if (purpose) where['purpose'] = purpose;

    const [list, total] = await this.codeRepo.findAndCount({
      where: where as FindOptionsWhere<VerificationCode>,
      order: { createdAt: 'DESC' },
      take: ps,
      skip: (p - 1) * ps,
    });
    return { code: 0, data: { list, total, page: p, pageSize: ps } };
  }

  // ---- 邮件模板 ----

  @Get('templates')
  async listTemplates() {
    const list = await this.templateRepo.find({ order: { id: 'ASC' } });
    return { code: 0, data: list };
  }

  @Put('templates/:key')
  async updateTemplate(
    @Param('key') key: string,
    @Body() body: { subject?: string; body?: string },
  ) {
    let tmpl = await this.templateRepo.findOne({ where: { key } });
    if (!tmpl) {
      tmpl = this.templateRepo.create({
        key,
        subject: body.subject ?? '',
        body: body.body ?? '',
      });
    } else {
      if (body.subject !== undefined) tmpl.subject = body.subject;
      if (body.body !== undefined) tmpl.body = body.body;
    }
    await this.templateRepo.save(tmpl);
    return { code: 0, data: tmpl };
  }

  // ---- 认证设置 ----

  @Get('settings')
  async getSettings() {
    const settings = await this.settingsService.get();
    return { code: 0, data: settings };
  }

  @Put('settings')
  @HttpCode(200)
  async updateSettings(@Body() body: Partial<AuthSettings>) {
    const allowed: (keyof AuthSettings)[] = [
      'huaweiPrimaryFlow',
      'huaweiQuickLoginEnabled',
      'huaweiGetAuthCodeEnabled',
      'appleSignInEnabled',
      'smsMockHighlight',
      'codeTtlSeconds',
      'codeResendIntervalSeconds',
      'codeMaxAttempts',
      'codeDailyLimitPerIdentifier',
    ];
    const data = Object.fromEntries(
      allowed.filter((k) => body[k] !== undefined).map((k) => [k, body[k]]),
    ) as Partial<AuthSettings>;
    const settings = await this.settingsService.update(data);
    return { code: 0, data: settings };
  }
}
