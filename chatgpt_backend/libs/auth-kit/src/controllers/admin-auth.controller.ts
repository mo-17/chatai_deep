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
  BadRequestException,
  ServiceUnavailableException,
  Inject,
  UseGuards,
  Optional,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import {
  Repository,
  Like,
  FindOptionsWhere,
  type EntityManager,
} from 'typeorm';
import { SmtpProvider } from '../verification/entities/smtp-provider.entity';
import { VerificationCode } from '../verification/entities/verification-code.entity';
import { EmailTemplate } from '../verification/entities/email-template.entity';
import { AuthSettings } from '../verification/entities/auth-settings.entity';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { EmailSenderManager } from '../verification/senders/email-sender.manager';
import { safeMailFailure } from '../verification/senders/mail-delivery.error';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import {
  UpdateAuthSettingsDto,
  UpdateSmtpProviderDto,
  TestSmtpProviderDto,
  CodeLogQueryDto,
  UpdateEmailTemplateDto,
} from './admin-auth.dto';
import {
  CODE_TEMPLATE_KEYS,
  validateCodeTemplate,
} from '../verification/senders/email-code.template';
import { MicrosoftSmtpService } from '../microsoft/microsoft-smtp.service';
import { AUTH_KIT_OPTIONS } from '../auth-kit.tokens';
import type { AuthKitModuleOptions } from '../auth-kit.module';
import * as crypto from 'crypto';
import { AuthKitAdminGuard } from '../guards/auth-kit-auth.guard';

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

function dto<T extends object>(type: new () => T, body: T): T {
  if (!body || Object.values(body).some((value) => value === null))
    throw new BadRequestException('参数无效');
  const value = plainToInstance(type, body);
  if (
    validateSync(value, { whitelist: true, forbidNonWhitelisted: true }).length
  )
    throw new BadRequestException('参数无效');
  return value;
}

function providerKey(key: string): SmtpProviderKey {
  if (!['generic', 'aliyun_dm', 'tencent_ses'].includes(key))
    throw new NotFoundException('服务商不存在');
  return key as SmtpProviderKey;
}

/** 明确投影，未来新增 secret/token 字段也不会被 spread 泄露。 */
function publicProvider(p: SmtpProvider) {
  return {
    id: p.id,
    key: p.key,
    authMode: p.authMode ?? 'password',
    configRevision: p.configRevision ?? 0,
    microsoftClientId: p.microsoftClientId,
    hasMicrosoftClientSecret: !!p.microsoftClientSecretEncrypted,
    displayName: p.displayName,
    host: p.host,
    port: p.port,
    secure: p.secure,
    username: p.username,
    passwordEncrypted: p.passwordEncrypted ? '••••••••' : '',
    hasPassword: !!p.passwordEncrypted,
    fromName: p.fromName,
    fromAddress: p.fromAddress,
    enabled: p.enabled,
    configured:
      p.authMode === 'microsoft_oauth'
        ? !!(
            p.microsoftClientId &&
            p.microsoftClientSecretEncrypted &&
            p.fromAddress
          )
        : !!(p.host && p.username && p.passwordEncrypted && p.fromAddress),
    lastTestRevision: p.lastTestRevision,
    lastTestedAt: p.lastTestedAt,
    lastTestStatus: p.lastTestStatus,
    lastTestError: p.lastTestError ? 'smtp_previous_test_failed' : null,
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  };
}

@Controller('uapi/admin/auth')
@UseGuards(AuthKitAdminGuard)
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
    @Optional() private readonly microsoft?: MicrosoftSmtpService,
  ) {
    this.appSecret = crypto
      .createHash('sha256')
      .update(options.appSecretKey)
      .digest();
  }

  // ---- SMTP 服务商 ----

  @Get('providers')
  async listProviders() {
    const list = await this.smtpRepo.find({ order: { id: 'ASC' } });
    const safe = list.map(publicProvider);
    return { code: 0, data: safe };
  }

  @Put('providers/:key')
  async updateProvider(
    @Param('key') key: string,
    @Body() body: UpdateSmtpProviderDto,
  ) {
    providerKey(key);
    body = dto(UpdateSmtpProviderDto, body);
    if (body.password && Buffer.byteLength(body.password, 'utf8') > 200)
      throw new BadRequestException('SMTP 密码过长');
    if (
      body.microsoftClientSecret &&
      Buffer.byteLength(body.microsoftClientSecret, 'utf8') > 4096
    )
      throw new BadRequestException('微软密钥过长');
    if (
      key !== 'generic' &&
      (body.authMode === 'microsoft_oauth' ||
        body.microsoftClientId !== undefined ||
        body.microsoftClientSecret !== undefined ||
        body.clearMicrosoftClientSecret !== undefined)
    )
      throw new BadRequestException('仅通用slot支持个人Outlook');
    let result: SmtpProvider;
    try {
      result = await this.mutate(async (manager) => {
        const provider = await manager.findOne(SmtpProvider, {
          where: { key: key as SmtpProviderKey },
          lock: { mode: 'pessimistic_write' },
        });
        if (!provider) throw new NotFoundException('服务商不存在');
        const fields: Partial<SmtpProvider> = {};
        const allowed = [
          'displayName',
          'host',
          'port',
          'secure',
          'username',
          'fromName',
          'fromAddress',
          'authMode',
          'microsoftClientId',
        ] as const;
        for (const field of allowed)
          if (body[field] !== undefined)
            Object.assign(fields, { [field]: body[field] });
        if (body.clearPassword) fields.passwordEncrypted = '';
        else if (body.password && body.password !== '••••••••')
          fields.passwordEncrypted = encrypt(body.password, this.appSecret);
        if (body.clearMicrosoftClientSecret)
          fields.microsoftClientSecretEncrypted = null;
        else if (
          body.microsoftClientSecret &&
          body.microsoftClientSecret !== '••••••••'
        ) {
          if (!this.microsoft) throw new BadRequestException('邮件授权不可用');
          fields.microsoftClientSecretEncrypted = this.microsoft.cipher.seal(
            body.microsoftClientSecret,
            provider.id,
            'client-secret',
          );
        }
        const updated = { ...provider, ...fields };
        if (updated.authMode !== provider.authMode) fields.enabled = false;
        if (updated.authMode === 'microsoft_oauth') {
          fields.host = 'smtp-mail.outlook.com';
          fields.port = 587;
          fields.secure = false;
          fields.username = updated.fromAddress;
          fields.passwordEncrypted = '';
          fields.enabled = false;
        }
        fields.configRevision = provider.configRevision + 1;
        fields.lastTestedAt = null;
        fields.lastTestStatus = null;
        fields.lastTestError = null;
        fields.lastTestRevision = null;
        await manager.update(SmtpProvider, { id: provider.id }, fields);
        const current = await manager.findOneByOrFail(SmtpProvider, {
          id: provider.id,
        });
        if (
          this.microsoft &&
          (provider.authMode === 'microsoft_oauth' ||
            current.authMode === 'microsoft_oauth')
        )
          await this.microsoft.disconnectWith(manager, current);
        return current;
      });
    } catch (e) {
      if (e instanceof BadRequestException || e instanceof NotFoundException)
        throw e;
      throw new ServiceUnavailableException('SMTP 配置保存失败');
    }
    this.emailManager.invalidate(key);
    this.microsoft?.invalidate(key);
    return { code: 0, data: publicProvider(result) };
  }
  private mutate<T>(
    action: (manager: EntityManager) => Promise<T>,
  ): Promise<T> {
    if (this.microsoft) return this.microsoft.mutate(action);
    return this.smtpRepo.manager.transaction(async (manager) => {
      await manager.query("SET LOCAL lock_timeout='3000ms'");
      await manager.query('SELECT pg_advisory_xact_lock(178409,1)');
      return action(manager);
    });
  }

  @Post('providers/:key/activate')
  @HttpCode(200)
  async activateProvider(@Param('key') key: string) {
    providerKey(key);
    try {
      await this.emailManager.activate(key);
    } catch {
      throw new BadRequestException('SMTP 配置未就绪，无法启用');
    }
    return { code: 0, data: null };
  }

  @Post('providers/:key/test')
  @HttpCode(200)
  async testProvider(
    @Param('key') key: string,
    @Body() body: TestSmtpProviderDto,
  ) {
    providerKey(key);
    body = dto(TestSmtpProviderDto, body);
    const provider = await this.smtpRepo.findOne({
      where: { key: key as SmtpProviderKey },
    });
    if (!provider) throw new NotFoundException('服务商不存在');
    let status: 'ok' | 'failed' = 'ok',
      error: string | null = null;
    try {
      const tester = this.emailManager.senderFor(provider);
      await tester.send(
        body.to,
        'ChatAI Deep - 测试邮件',
        '<h2>这是一封测试邮件</h2><p>如果您收到此邮件，说明 SMTP 配置正确。</p>',
      );
    } catch (e) {
      status = 'failed';
      error = safeMailFailure(e).safeCode;
    }
    // 只写测试元数据；旧配置的迟到SMTP结果不能改enabled/配置或污染新revision。
    let persisted: boolean;
    try {
      const result = await this.smtpRepo.update(
        { id: provider.id, configRevision: provider.configRevision },
        {
          lastTestStatus: status,
          lastTestError: error,
          lastTestedAt: new Date(),
          lastTestRevision: provider.configRevision,
        },
      );
      persisted = result.affected === 1;
    } catch {
      throw new ServiceUnavailableException('邮件测试状态保存失败');
    }
    return {
      code: 0,
      data: {
        status,
        error,
        persisted,
        configRevision: provider.configRevision,
      },
    };
  }

  // ---- 验证码日志 ----

  @Get('codes')
  async listCodes(@Query() query: CodeLogQueryDto) {
    const q = dto(CodeLogQueryDto, query);
    const p = q.page ?? 1,
      ps = q.pageSize ?? 20;
    const where: Record<string, unknown> = {};
    if (q.channel) where.channel = q.channel;
    if (q.identifier)
      where.identifier = Like(
        '%' + q.identifier.replace(/[\\%_]/g, (c) => '\\' + c) + '%',
      );
    if (q.purpose) where.purpose = q.purpose;
    const [list, total] = await this.codeRepo.findAndCount({
      select: {
        id: true,
        channel: true,
        identifier: true,
        purpose: true,
        expiresAt: true,
        consumedAt: true,
        attempts: true,
        ipAddress: true,
        createdAt: true,
        deliveryStatus: true,
        deliveryErrorCode: true,
        sentAt: true,
        invalidatedAt: true,
        invalidationReason: true,
      },
      where: where as FindOptionsWhere<VerificationCode>,
      order: { createdAt: 'DESC', id: 'DESC' },
      take: ps,
      skip: (p - 1) * ps,
    });
    return { code: 0, data: { list, total, page: p, pageSize: ps } };
  }

  // ---- 邮件模板 ----

  @Get('templates')
  async listTemplates() {
    const list = (await this.templateRepo.find({ order: { id: 'ASC' } }))
      .filter((t) => (CODE_TEMPLATE_KEYS as readonly string[]).includes(t.key))
      .map((t) => ({
        id: t.id,
        key: t.key,
        subject: t.subject,
        body: t.body,
        updatedAt: t.updatedAt,
      }));
    return { code: 0, data: list };
  }

  @Put('templates/:key')
  async updateTemplate(
    @Param('key') key: string,
    @Body() body: UpdateEmailTemplateDto,
  ) {
    if (!(CODE_TEMPLATE_KEYS as readonly string[]).includes(key))
      throw new NotFoundException('模板不存在');
    body = dto(UpdateEmailTemplateDto, body);
    if (!validateCodeTemplate(body))
      throw new BadRequestException('模板参数无效');
    // upsert 仅提交主题与正文；不回写读出的旧实体或请求中的额外字段。
    await this.templateRepo.upsert(
      { key, subject: body.subject, body: body.body },
      ['key'],
    );
    const tmpl = await this.templateRepo.findOneOrFail({ where: { key } });
    return {
      code: 0,
      data: {
        id: tmpl.id,
        key: tmpl.key,
        subject: tmpl.subject,
        body: tmpl.body,
        updatedAt: tmpl.updatedAt,
      },
    };
  }

  // ---- 认证设置 ----

  @Get('settings')
  async getSettings() {
    const settings = await this.settingsService.get();
    return { code: 0, data: settings };
  }

  @Put('settings')
  @HttpCode(200)
  async updateSettings(@Body() body: UpdateAuthSettingsDto) {
    body = dto(UpdateAuthSettingsDto, body);
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
      'codeHourlyLimitPerIp',
    ];
    const data = Object.fromEntries(
      allowed.filter((k) => body[k] !== undefined).map((k) => [k, body[k]]),
    ) as Partial<AuthSettings>;
    if (!Object.keys(data).length)
      throw new BadRequestException('未提供有效设置字段');
    const settings = await this.settingsService.update(data);
    return { code: 0, data: settings };
  }
}
