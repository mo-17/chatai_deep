import {
  Injectable,
  BadRequestException,
  ServiceUnavailableException,
  Inject,
  Optional,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import {
  Repository,
  MoreThanOrEqual,
  IsNull,
  type EntityManager,
} from 'typeorm';
import * as bcrypt from 'bcryptjs';
import * as crypto from 'crypto';
import { VerificationCode } from './entities/verification-code.entity';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { EmailSenderManager } from './senders/email-sender.manager';
import { SmsMockSender } from './senders/sms-mock.sender';
import {
  codeTemplateKey,
  renderConfiguredCodeEmail,
} from './senders/email-code.template';
import { EmailTemplate } from './entities/email-template.entity';
import {
  MailDeliveryError,
  safeMailFailure,
} from './senders/mail-delivery.error';
import {
  canonicalIdentifier,
  assertCodeScope,
  validateCodePolicy,
  type CodeChannel,
  type CodePurpose,
} from './verification-contract';

const BCRYPT_ROUNDS = 10;
export const VERIFICATION_RUNTIME = Symbol('VERIFICATION_RUNTIME');
/** 仅代码注入用于隔离时钟/传输测试；没有 env/query 可开测试后门。 */
export interface VerificationRuntime {
  now?: () => number;
  deliveryTimeoutMs?: number;
}
const PURPOSE_LABELS: Record<CodePurpose, string> = {
  login: '登录',
  register: '注册',
  bind: '绑定',
  reset_password: '重置密码',
};

@Injectable()
export class VerificationService {
  private readonly smsMock = new SmsMockSender();
  private readonly now: () => number;
  private readonly deliveryTimeoutMs: number;

  constructor(
    @InjectRepository(VerificationCode)
    private readonly codeRepo: Repository<VerificationCode>,
    private readonly settingsService: AuthSettingsService,
    private readonly emailManager: EmailSenderManager,
    @Optional() @Inject(VERIFICATION_RUNTIME) runtime?: VerificationRuntime,
  ) {
    this.now = runtime?.now ?? Date.now;
    this.deliveryTimeoutMs = runtime?.deliveryTimeoutMs ?? 30000;
  }

  private async transaction<T>(
    action: (manager: EntityManager) => Promise<T>,
  ): Promise<T> {
    try {
      return await this.codeRepo.manager.transaction(async (manager) => {
        await manager.query("SET LOCAL lock_timeout='3000ms'");
        await manager.query("SET LOCAL statement_timeout='5000ms'");
        return action(manager);
      });
    } catch (error) {
      if (
        error instanceof BadRequestException ||
        error instanceof ServiceUnavailableException
      )
        throw error;
      // 不把 QueryFailedError 的 SQL/参数、SMTP 原文写进异常日志或返回值。
      throw new ServiceUnavailableException('验证码存储暂不可用，请稍后重试');
    }
  }

  private async scopeLock(
    manager: EntityManager,
    channel: CodeChannel,
    identifier: string,
  ) {
    await manager.query('SELECT pg_advisory_xact_lock(178408,hashtext($1))', [
      channel + ':' + identifier,
    ]);
  }

  /** 日限跨用途；createdAt 为锁等待完成后的预留时刻，统一 UTC 日界。 */
  async generateAndSendCode(
    channel: CodeChannel,
    raw: string,
    purpose: CodePurpose,
    ip: string,
  ): Promise<void> {
    assertCodeScope(channel, purpose);
    const identifier = canonicalIdentifier(channel, raw);
    const code = crypto.randomInt(100000, 1000000).toString();
    const codeHash = await bcrypt.hash(code, BCRYPT_ROUNDS);
    const reservation = await this.transaction(async (manager) => {
      // 所有发送固定 IP -> 标识 顺序，验证/送达结算只取标识锁。
      await manager.query('SELECT pg_advisory_xact_lock(178407,hashtext($1))', [
        ip,
      ]);
      await this.scopeLock(manager, channel, identifier);
      const settings = await this.settingsService.get(manager);
      validateCodePolicy(settings as unknown as Record<string, unknown>);
      // 在短事务内读取本次模板快照；不增加 SMTP 期间的锁或网络请求。
      const template =
        channel === 'email'
          ? await manager
              .getRepository(EmailTemplate)
              .findOne({ where: { key: codeTemplateKey(purpose) } })
          : null;
      const repo = manager.getRepository(VerificationCode);
      const at = this.now();
      const hourAgo = new Date(at - 3600000);
      const day = new Date(at);
      day.setUTCHours(0, 0, 0, 0);
      const ipCount = await repo.count({
        where: { ipAddress: ip, createdAt: MoreThanOrEqual(hourAgo) },
      });
      if (ipCount >= settings.codeHourlyLimitPerIp)
        throw new BadRequestException('该连接 IP 发送次数已达一小时上限');
      const count = await repo.count({
        where: { channel, identifier, createdAt: MoreThanOrEqual(day) },
      });
      if (count >= settings.codeDailyLimitPerIdentifier)
        throw new BadRequestException('该标识今日发送次数已达上限（UTC）');
      const latest = await repo.findOne({
        where: { channel, identifier, purpose },
        order: { createdAt: 'DESC', id: 'DESC' },
        lock: { mode: 'pessimistic_write' },
      });
      // count/latest 查询也可能等待；不使用方法入口的时间补签预留。
      const liveAt = this.now();
      if (
        latest &&
        liveAt - latest.createdAt.getTime() <
          settings.codeResendIntervalSeconds * 1000
      )
        throw new BadRequestException('请稍后再发送验证码');
      await repo.update(
        { channel, identifier, purpose, invalidatedAt: IsNull() },
        {
          invalidatedAt: new Date(liveAt),
          invalidationReason: 'superseded',
        },
      );
      const record = await repo.save(
        repo.create({
          channel,
          identifier,
          purpose,
          codeHash,
          ipAddress: ip,
          note: null,
          createdAt: new Date(liveAt),
          expiresAt: new Date(liveAt + settings.codeTtlSeconds * 1000),
          deliveryStatus: 'pending',
          deliveryErrorCode: null,
          deliveryDeadlineAt: new Date(liveAt + this.deliveryTimeoutMs),
          consumedAt: null,
          invalidatedAt: null,
          invalidationReason: null,
          sentAt: null,
        }),
      );
      return { id: record.id, ttlSeconds: settings.codeTtlSeconds, template };
    });

    let failure: MailDeliveryError | null = null;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let smsUnavailable: ServiceUnavailableException | undefined;
    try {
      // 不持有数据库事务等待 SMTP，只产生一次投递调用；超时后不重放。
      const sending =
        channel === 'email'
          ? this.emailManager.send(
              identifier,
              ...this.emailParts(
                code,
                purpose,
                reservation.ttlSeconds,
                reservation.template,
              ),
            )
          : this.smsMock.send(identifier, code);
      await Promise.race([
        sending,
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () =>
              reject(new MailDeliveryError('smtp_delivery_unknown', 'unknown')),
            this.deliveryTimeoutMs,
          );
        }),
      ]);
    } catch (error) {
      failure = safeMailFailure(error);
      if (channel === 'sms' && error instanceof ServiceUnavailableException) {
        smsUnavailable = error;
        failure = new MailDeliveryError('sms_not_configured', 'failed');
      }
    } finally {
      if (timer) clearTimeout(timer);
    }

    const applied = await this.transaction(async (manager) => {
      await this.scopeLock(manager, channel, identifier);
      const repo = manager.getRepository(VerificationCode);
      const record = await repo.findOne({
        where: { id: reservation.id },
        lock: { mode: 'pessimistic_write' },
      });
      const latest = await repo.findOne({
        where: { channel, identifier, purpose },
        order: { createdAt: 'DESC', id: 'DESC' },
      });
      if (!record || record.deliveryStatus !== 'pending') return false;
      const at = this.now();
      if (failure) {
        record.deliveryStatus = failure.deliveryStatus;
        record.deliveryErrorCode = failure.safeCode;
        record.invalidatedAt ??= new Date(at);
        record.invalidationReason ??= 'delivery_' + failure.deliveryStatus;
      } else if (
        latest?.id !== record.id ||
        record.invalidatedAt ||
        record.consumedAt
      ) {
        record.deliveryStatus = 'unknown';
        record.deliveryErrorCode = 'superseded';
        record.invalidatedAt ??= new Date(at);
        record.invalidationReason ??= 'superseded';
      } else if (
        !record.deliveryDeadlineAt ||
        at >= record.deliveryDeadlineAt.getTime() ||
        at >= record.expiresAt.getTime()
      ) {
        record.deliveryStatus = 'unknown';
        record.deliveryErrorCode = 'smtp_delivery_unknown';
        record.invalidatedAt = new Date(at);
        record.invalidationReason = 'delivery_unknown';
      } else {
        record.deliveryStatus = 'sent';
        record.sentAt = new Date(at);
      }
      await repo.save(record);
      return record.deliveryStatus === 'sent';
    });
    if (smsUnavailable) throw smsUnavailable;
    if (!applied)
      throw new BadRequestException(
        failure?.deliveryStatus === 'failed'
          ? '验证码未发送成功，请稍后重试'
          : '验证码投递状态未知或已失效，请稍后明确重新获取',
      );
  }

  private emailParts(
    code: string,
    purpose: CodePurpose,
    ttlSeconds: number,
    template?: EmailTemplate | null,
  ): [string, string] {
    const { subject, html } = renderConfiguredCodeEmail(
      {
        code,
        purposeLabel: PURPOSE_LABELS[purpose],
        ttlMinutes: Math.ceil(ttlSeconds / 60),
      },
      template,
    );
    return [subject, html];
  }

  /** latest 不过滤终态；新码消费/过期/失败后，永远不会回退查询旧码。 */
  async consumeWith<T>(
    channel: CodeChannel,
    raw: string,
    purpose: CodePurpose,
    code: string,
    business: (manager: EntityManager, assertCurrent: () => void) => Promise<T>,
    // 只能同步检查原授权；最后业务/验证码 save 返回后仍复核，不等同于 COMMIT 原子点。
    checkAuthorization?: () => undefined,
  ): Promise<T> {
    assertCodeScope(channel, purpose);
    const identifier = canonicalIdentifier(channel, raw);
    if (!/^\d{6}$/.test(code))
      throw new BadRequestException('验证码为 6 位数字');
    const result = await this.transaction<
      { ok: false; message: string } | { ok: true; value: T }
    >(async (manager) => {
      await this.scopeLock(manager, channel, identifier);
      const settings = await this.settingsService.get(manager);
      validateCodePolicy(settings as unknown as Record<string, unknown>);
      const repo = manager.getRepository(VerificationCode);
      const record = await repo.findOne({
        where: { channel, identifier, purpose },
        order: { createdAt: 'DESC', id: 'DESC' },
        lock: { mode: 'pessimistic_write' },
      });
      if (
        !record ||
        record.deliveryStatus !== 'sent' ||
        record.consumedAt ||
        record.invalidatedAt
      )
        return { ok: false, message: '验证码无效或已失效' };
      const invalidate = async (reason: 'expired' | 'locked') => {
        record.invalidatedAt = new Date(this.now());
        record.invalidationReason = reason;
        record.consumedAt = new Date(this.now());
        await repo.save(record);
      };
      if (this.now() >= record.expiresAt.getTime()) {
        await invalidate('expired');
        return { ok: false, message: '验证码已过期，请重新获取' };
      }
      if (record.attempts >= settings.codeMaxAttempts) {
        await invalidate('locked');
        return { ok: false, message: '验证码错误次数过多，已锁定，请重新获取' };
      }
      const valid = await bcrypt.compare(code, record.codeHash);
      // bcrypt 是异步工作，期间跨过到期时也不得消费。
      if (this.now() >= record.expiresAt.getTime()) {
        await invalidate('expired');
        return { ok: false, message: '验证码已过期，请重新获取' };
      }
      if (!valid) {
        record.attempts++;
        const remaining = settings.codeMaxAttempts - record.attempts;
        if (remaining <= 0) await invalidate('locked');
        else await repo.save(record);
        return {
          ok: false,
          message:
            remaining <= 0
              ? '验证码错误次数过多，已锁定，请重新获取'
              : '验证码错误，剩余 ' + remaining + ' 次尝试',
        };
      }
      // 用户行/唯一约束也可能等待；写入前与所有业务工作后重核到期。
      // 业务已执行后到期必须抛错回滚整个事务，不能正常返回提交半用户。
      const assertCurrent = () => {
        if (this.now() >= record.expiresAt.getTime())
          throw new BadRequestException('验证码已过期，请重新获取');
        checkAuthorization?.();
      };
      assertCurrent();
      const value = await business(manager, assertCurrent);
      assertCurrent();
      record.consumedAt = new Date(this.now());
      record.invalidatedAt = record.consumedAt;
      record.invalidationReason = 'consumed';
      await repo.save(record);
      assertCurrent();
      return { ok: true, value };
    });
    // 计数/锁定以正常事务返回提交，之后才抛公共错误。
    if (!result.ok) throw new BadRequestException(result.message);
    return result.value;
  }

  /** 兼容不附带宿主业务的旧调用；验证码消费者使用 consumeWith。 */
  async verifyCode(
    channel: CodeChannel,
    raw: string,
    purpose: CodePurpose,
    code: string,
  ): Promise<boolean> {
    return this.consumeWith(channel, raw, purpose, code, () =>
      Promise.resolve(true),
    );
  }
}
