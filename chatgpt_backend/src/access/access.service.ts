import {
  BadRequestException,
  ForbiddenException,
  HttpException,
  Injectable,
} from '@nestjs/common';
import { DataSource } from 'typeorm';
import { randomUUID } from 'node:crypto';
import { AccessPolicy } from './access-policy.entity';
import { AccessRequest } from './access-request.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import type { CompletionBody } from '../chat/chat.service';
import { User } from '../user/user.entity';

export const TRIAL_MODEL = '__aipu_trial__';
export type Admission = { id: string | null; body: CompletionBody };
const integers = {
  dailyRequests: [1, 100000],
  dailyTokens: [1, 10000000],
  globalDailyTokens: [1, 100000000],
  globalDailyRequests: [1, 1000000],
  maxConcurrent: [1, 10],
  maxOutputTokens: [1, 32768],
  requestsPerMinute: [1, 60],
  globalMaxConcurrent: [1, 100],
} as const;
export function normalizePolicy(
  input: Record<string, unknown>,
  current: AccessPolicy,
): AccessPolicy {
  if (!input || typeof input !== 'object' || Array.isArray(input))
    throw new BadRequestException('配置格式无效');
  const result = Object.assign(new AccessPolicy(), current);
  for (const [key, value] of Object.entries(input)) {
    if (key === 'id') continue;
    if (
      key === 'limitsEnabled' ||
      key === 'trialEnabled' ||
      key === 'requireVerifiedEmail'
    ) {
      if (typeof value !== 'boolean')
        throw new BadRequestException('开关值无效');
      result[key] = value;
    } else if (Object.hasOwn(integers, key)) {
      const [min, max] = integers[key as keyof typeof integers];
      if (
        typeof value !== 'number' ||
        !Number.isInteger(value) ||
        value < min ||
        value > max
      )
        throw new BadRequestException('额度必须是范围内整数');
      (result as unknown as Record<string, unknown>)[key] = value;
    } else if (key === 'trialProviderCode' || key === 'trialModel') {
      if (typeof value !== 'string' || value.length > 128)
        throw new BadRequestException('试用模型无效');
      result[key] = value.trim();
    } else throw new BadRequestException('未知配置项');
  }
  if (
    result.trialEnabled &&
    (!result.limitsEnabled || !result.trialProviderCode || !result.trialModel)
  )
    throw new BadRequestException('开启试用前必须配置模型和额度');
  result.id = 1;
  return result;
}

@Injectable()
export class AccessService {
  constructor(private readonly db: DataSource) {}

  async policy(): Promise<AccessPolicy> {
    const repo = this.db.getRepository(AccessPolicy);
    await repo
      .createQueryBuilder()
      .insert()
      .values({ id: 1 })
      .orIgnore()
      .execute();
    return repo.findOneByOrFail({ id: 1 });
  }

  async update(input: Record<string, unknown>) {
    const policy = normalizePolicy(input, await this.policy());
    if (policy.trialEnabled) await this.checkTrial(policy);
    return this.db.getRepository(AccessPolicy).save(policy);
  }

  private async checkTrial(policy: AccessPolicy) {
    const provider = await this.db
      .getRepository(AiProvider)
      .findOneBy({ code: policy.trialProviderCode, enabled: true });
    const model =
      provider &&
      (await this.db.getRepository(AiModel).findOneBy({
        providerId: provider.id,
        modelId: policy.trialModel,
        enabled: true,
      }));
    if (!provider?.apiKey?.trim() || !model)
      throw new BadRequestException('试用服务商 Key 或启用模型尚未配置');
  }

  async admit(userId: number, body: CompletionBody): Promise<Admission> {
    const policy = await this.policy();
    // 直接提交真实模型 ID 也必须受试用开关保护，不能只检查客户端别名。
    const trial =
      body.model === TRIAL_MODEL ||
      (body.model === policy.trialModel &&
        (!body.providerCode || body.providerCode === policy.trialProviderCode));
    if (trial && !policy.trialEnabled)
      throw new ForbiddenException('官方试用暂未开放，请配置自己的 AI 服务');
    if (policy.trialEnabled && policy.requireVerifiedEmail) {
      const user = await this.db.getRepository(User).findOneBy({ id: userId });
      if (
        !user ||
        (user.role !== 'admin' && (!user.email || !user.emailVerifiedAt))
      )
        throw new ForbiddenException(
          '请先通过邮箱验证码登录或绑定邮箱，再使用官方服务',
        );
    }
    if (!policy.limitsEnabled) return { id: null, body };
    if (trial) await this.checkTrial(policy);
    const effective = {
      ...body,
      max_tokens: Math.min(
        body.max_tokens ?? policy.maxOutputTokens,
        policy.maxOutputTokens,
      ),
      ...(trial
        ? { model: policy.trialModel, providerCode: policy.trialProviderCode }
        : {}),
    };
    if (trial && Buffer.byteLength(JSON.stringify(body.messages)) > 128 * 1024)
      throw new BadRequestException('试用上下文过长，请新建对话');
    // Text-only quota mode gives a conservative byte-level input reservation.
    // Media/tool payloads need provider tokenization before they can share this budget.
    const inputTokens = estimateInputReservation(body);
    const id = randomUUID();
    await this.db.transaction(async (manager) => {
      // 所有进程共享 admission 锁，检查与写入必须在同一 transaction 内。
      await manager.query('SELECT pg_advisory_xact_lock(1128812884, 31)');
      const [counts] = await manager.query<
        Array<{
          used: number;
          global: number;
          tokens: number;
          globalTokens: number;
        }>
      >(
        `SELECT count(*) FILTER (WHERE "userId"=$1)::int AS used,
        count(*)::int AS global, COALESCE(sum("chargedTokens") FILTER (WHERE "userId"=$1),0)::int AS tokens, COALESCE(sum("chargedTokens"),0)::int AS "globalTokens" FROM access_requests WHERE day=(now() AT TIME ZONE 'UTC')::date`,
        [userId],
      );
      const [active] = await manager.query<
        Array<{ count: number; global: number; recent: number }>
      >(
        `SELECT count(*) FILTER (WHERE "userId"=$1 AND "activeUntil">now())::int AS count,
          count(*) FILTER (WHERE "activeUntil">now())::int AS global,
          count(*) FILTER (WHERE "userId"=$1 AND "createdAt">now()-interval '1 minute')::int AS recent
          FROM access_requests WHERE "activeUntil">now() OR "createdAt">now()-interval '1 minute'`,
        [userId],
      );
      if (active.recent >= policy.requestsPerMinute)
        throw new HttpException('请求过于频繁，请一分钟后再试', 429);
      if (active.global >= policy.globalMaxConcurrent)
        throw new HttpException('服务繁忙，请稍后再试', 429);
      if (
        counts.used >= policy.dailyRequests ||
        counts.global >= policy.globalDailyRequests
      )
        throw new HttpException('今日额度已用完，请明天再试', 429);
      if (active.count >= policy.maxConcurrent)
        throw new HttpException('已有请求进行中，请稍后再试', 429);
      const remaining = Math.min(
        policy.dailyTokens - counts.tokens,
        policy.globalDailyTokens - counts.globalTokens,
      );
      if (remaining <= inputTokens)
        throw new HttpException(
          '今日 Token 额度不足，请缩短对话或明天再试',
          429,
        );
      effective.max_tokens = Math.min(
        effective.max_tokens,
        remaining - inputTokens,
      );
      const reserved = inputTokens + effective.max_tokens;
      await manager.query(
        `INSERT INTO access_requests(id,"userId",day,model,"chargedTokens","activeUntil") VALUES($1,$2,(now() AT TIME ZONE 'UTC')::date,$3,$4,now()+interval '15 minutes')`,
        [id, userId, effective.model, reserved],
      );
    });
    return { id, body: effective };
  }

  async finish(id: string | null, usage?: { total_tokens?: number }) {
    if (!id) return;
    // 缺少 usage / 中断时保留预留量；不能把未知账单当零消费。
    const actual = usage?.total_tokens;
    const valid =
      typeof actual === 'number' && Number.isSafeInteger(actual) && actual >= 0;
    await this.db
      .getRepository(AccessRequest)
      .update(
        { id },
        { activeUntil: null, ...(valid ? { chargedTokens: actual } : {}) },
      );
  }

  async status(userId: number) {
    const policy = await this.policy();
    const user = policy.requireVerifiedEmail
      ? await this.db.getRepository(User).findOneBy({ id: userId })
      : null;
    const eligible =
      !policy.requireVerifiedEmail ||
      (!!user &&
        (user.role === 'admin' || (!!user.email && !!user.emailVerifiedAt)));
    const [count] = await this.db.query<
      Array<{ used: number; tokens: number }>
    >(
      `SELECT count(*)::int AS used, COALESCE(sum("chargedTokens"),0)::int AS tokens FROM access_requests WHERE "userId"=$1 AND day=(now() AT TIME ZONE 'UTC')::date`,
      [userId],
    );
    const models = await this.db.query<
      Array<{ model: string; requests: number; totalTokens: string }>
    >(
      `SELECT model, count(*)::int AS requests, COALESCE(sum("totalTokens"),0)::bigint::text AS "totalTokens"
      FROM usage WHERE "userId"=$1 AND "createdAt">=(now() AT TIME ZONE 'UTC')::date GROUP BY model ORDER BY count(*) DESC LIMIT 50`,
      [userId],
    );
    return {
      trialProviderCode: policy.trialEnabled ? policy.trialProviderCode : null,
      trialEnabled: policy.trialEnabled,
      trialEligible: eligible,
      trialUnavailableReason: !eligible ? 'verified_email_required' : null,
      trialModel: policy.trialEnabled ? policy.trialModel : null,
      limitsEnabled: policy.limitsEnabled,
      dailyTokens: policy.dailyTokens,
      usedTokens: count.tokens,
      remainingTokens: policy.limitsEnabled
        ? Math.max(0, policy.dailyTokens - count.tokens)
        : null,
      dailyRequests: policy.dailyRequests,
      usedRequests: count.used,
      remainingRequests: policy.limitsEnabled
        ? Math.max(0, policy.dailyRequests - count.used)
        : null,
      maxConcurrent: policy.maxConcurrent,
      models,
      resetTimezone: 'UTC',
      countingRule:
        '每日 UTC 0 点重置；输入和输出均计入。请求先预留，完成后按 usage 结算；无 usage/中断保留预留量。当前预算模式支持纯文本聊天。',
    };
  }
}

export function estimateInputReservation(body: CompletionBody): number {
  if (
    !Array.isArray(body.messages) ||
    body.messages.length === 0 ||
    body.tools?.length ||
    body.messages.some(
      (message) =>
        !message ||
        !['system', 'user', 'assistant'].includes(String(message.role)) ||
        typeof message.content !== 'string' ||
        Object.keys(message).some((key) => !['role', 'content'].includes(key)),
    )
  ) {
    throw new BadRequestException(
      '官方额度模式暂支持纯文本聊天，请移除图片、文件或工具',
    );
  }
  // UTF-8 byte bound plus per-message framing reserve for the byte-level tokenizer.
  return (
    Buffer.byteLength(JSON.stringify(body.messages)) +
    body.messages.length * 32 +
    256
  );
}
