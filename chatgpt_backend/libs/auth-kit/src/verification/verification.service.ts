import {
  Injectable,
  BadRequestException,
  Logger,
  ServiceUnavailableException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, MoreThan, IsNull } from 'typeorm';
import * as bcrypt from 'bcryptjs';
import * as crypto from 'crypto';
import { VerificationCode } from './entities/verification-code.entity';
import { AuthSettingsService } from '../settings/auth-settings.service';
import { EmailSenderManager } from './senders/email-sender.manager';
import { SmsMockSender } from './senders/sms-mock.sender';
import { renderCodeEmail } from './senders/email-code.template';

const BCRYPT_ROUNDS = 10;

const PURPOSE_LABELS: Record<string, string> = {
  login: '登录',
  register: '注册',
  bind: '绑定',
  reset_password: '重置密码',
};

@Injectable()
export class VerificationService {
  private readonly logger = new Logger('VerificationService');
  private readonly smsMock = new SmsMockSender();
  /** IP 限频：Map<ip, { count, windowStart }>，1 小时 */
  private readonly ipRateMap = new Map<
    string,
    { count: number; windowStart: number }
  >();

  constructor(
    @InjectRepository(VerificationCode)
    private readonly codeRepo: Repository<VerificationCode>,
    private readonly settingsService: AuthSettingsService,
    private readonly emailManager: EmailSenderManager,
  ) {}

  /** 生成并发送验证码 */
  async generateAndSendCode(
    channel: 'email' | 'sms',
    identifier: string,
    purpose: 'login' | 'register' | 'bind' | 'reset_password',
    ip: string,
  ): Promise<void> {
    const settings = await this.settingsService.get();

    // 1. IP 限频
    this.checkIpRate(ip);

    // 2. 同 identifier+purpose 重发间隔
    const latest = await this.codeRepo.findOne({
      where: { channel, identifier, purpose },
      order: { createdAt: 'DESC' },
    });
    if (latest) {
      const elapsed = Date.now() - latest.createdAt.getTime();
      const intervalMs = settings.codeResendIntervalSeconds * 1000;
      if (elapsed < intervalMs) {
        const waitSec = Math.ceil((intervalMs - elapsed) / 1000);
        throw new BadRequestException(`请 ${waitSec} 秒后再发送验证码`);
      }
    }

    // 3. 同 identifier+purpose 日限
    const dayStart = new Date();
    dayStart.setHours(0, 0, 0, 0);
    const todayCount = await this.codeRepo.count({
      where: {
        channel,
        identifier,
        purpose,
        createdAt: MoreThan(dayStart),
      },
    });
    if (todayCount >= settings.codeDailyLimitPerIdentifier) {
      throw new BadRequestException('今日发送次数已达上限，请明天再试');
    }

    // 4. 生成 6 位验证码
    const code = crypto.randomInt(100000, 999999).toString();
    const codeHash = await bcrypt.hash(code, BCRYPT_ROUNDS);
    const ttlSeconds = settings.codeTtlSeconds;
    const expiresAt = new Date(Date.now() + ttlSeconds * 1000);

    // 5. 存入 DB
    const record = this.codeRepo.create({
      channel,
      identifier,
      purpose,
      codeHash,
      expiresAt,
      ipAddress: ip,
      note: channel === 'sms' ? 'MOCK' : null,
    });
    await this.codeRepo.save(record);

    // 6. 发送；发送失败必须删除刚创建的记录，避免未送达的 code 仍可使用。
    try {
      if (channel === 'email') {
        const { subject, html } = renderCodeEmail({
          code,
          purposeLabel: PURPOSE_LABELS[purpose],
          ttlMinutes: Math.ceil(ttlSeconds / 60),
        });
        await this.emailManager.send(identifier, subject, html);
      } else {
        await this.smsMock.send(identifier, code);
      }
    } catch (err) {
      try {
        await this.codeRepo.delete(record.id);
      } catch {
        this.logger.error('验证码发送失败后的记录清理也失败');
      }
      if (err instanceof ServiceUnavailableException) throw err;
      this.logger.error('邮件发送失败');
      throw new BadRequestException('邮件发送失败，请稍后重试');
    }
  }

  /** 校验验证码，成功则标记消费，失败记录尝试次数 */
  async verifyCode(
    channel: 'email' | 'sms',
    identifier: string,
    purpose: 'login' | 'register' | 'bind' | 'reset_password',
    code: string,
  ): Promise<boolean> {
    const settings = await this.settingsService.get();

    const result: { ok: true } | { ok: false; message: string } =
      await this.codeRepo.manager.transaction(async (manager) => {
        const repo = manager.getRepository(VerificationCode);
        // 行锁把读取、尝试计数和消费合成一个状态迁移。
        const record = await repo.findOne({
          where: { channel, identifier, purpose, consumedAt: IsNull() },
          order: { createdAt: 'DESC' },
          lock: { mode: 'pessimistic_write' },
        });
        if (!record) {
          return { ok: false, message: '验证码无效或已过期' };
        }

        if (Date.now() > record.expiresAt.getTime()) {
          record.consumedAt = new Date();
          await repo.save(record);
          return { ok: false, message: '验证码已过期，请重新获取' };
        }

        if (record.attempts >= settings.codeMaxAttempts) {
          record.consumedAt = new Date();
          await repo.save(record);
          return {
            ok: false,
            message: '验证码错误次数过多，已锁定，请重新获取',
          };
        }

        const valid = await bcrypt.compare(code, record.codeHash);
        if (!valid) {
          record.attempts += 1;
          const remaining = settings.codeMaxAttempts - record.attempts;
          if (remaining <= 0) record.consumedAt = new Date();
          await repo.save(record);
          return {
            ok: false,
            message:
              remaining <= 0
                ? '验证码错误次数过多，已锁定，请重新获取'
                : `验证码错误，剩余 ${remaining} 次尝试`,
          };
        }

        record.consumedAt = new Date();
        await repo.save(record);
        return { ok: true };
      });

    // 在 transaction 提交后再抛错，确保失败计数和锁定状态不会回滚。
    if (!result.ok) throw new BadRequestException(result.message);
    return true;
  }

  // ---- IP 限频 ----

  private checkIpRate(ip: string) {
    const now = Date.now();
    const windowMs = 60 * 60 * 1000; // 1 小时
    const maxPerHour = 30;
    let entry = this.ipRateMap.get(ip);
    if (!entry || now - entry.windowStart > windowMs) {
      entry = { count: 0, windowStart: now };
      this.ipRateMap.set(ip, entry);
    }
    entry.count += 1;
    if (entry.count > maxPerHour) {
      throw new BadRequestException('请求过于频繁，请稍后再试');
    }
  }
}
