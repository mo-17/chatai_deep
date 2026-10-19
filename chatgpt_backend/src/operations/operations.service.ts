import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { AccessService } from '../access/access.service';
import { HttpMetrics } from './http-metrics';

@Injectable()
export class OperationsService {
  readonly metrics = new HttpMetrics();
  constructor(
    private readonly db: DataSource,
    private readonly access: AccessService,
  ) {}
  async snapshot() {
    const started = performance.now();
    // 数据库故障由既有异常过滤器返回；不把 SQL/连接信息暴露给浏览器。
    const [budget] = await this.db.query<
      Array<{ requests: number; tokens: number; active: number }>
    >(`SELECT
      count(*) FILTER (WHERE day=(now() AT TIME ZONE 'UTC')::date)::int AS requests,
      COALESCE(sum("chargedTokens") FILTER (WHERE day=(now() AT TIME ZONE 'UTC')::date),0)::bigint::float8 AS tokens,
      count(*) FILTER (WHERE "activeUntil">now())::int AS active FROM access_requests
      WHERE day=(now() AT TIME ZONE 'UTC')::date OR "activeUntil">now()`);
    const databaseMs = Math.round(performance.now() - started);
    const policy = await this.access.policy();
    const http = this.metrics.snapshot();
    const memory = process.memoryUsage();
    const alerts: Array<{ code: string; message: string }> = [];
    if (policy.limitsEnabled && budget.tokens >= policy.globalDailyTokens * 0.8)
      alerts.push({
        code: 'TOKEN_BUDGET',
        message: '全站今日 Token 预算已使用 80% 以上',
      });
    if (
      policy.limitsEnabled &&
      budget.requests >= policy.globalDailyRequests * 0.8
    )
      alerts.push({
        code: 'REQUEST_BUDGET',
        message: '全站今日请求预算已使用 80% 以上',
      });
    if (http.some((row) => row.serverErrors >= 3))
      alerts.push({
        code: 'HTTP_ERRORS',
        message: '最近一小时某类接口出现至少 3 次 HTTP 5xx，请检查服务日志',
      });
    return {
      sampledAt: new Date().toISOString(),
      uptimeSeconds: Math.floor(process.uptime()),
      database: { ok: true, latencyMs: databaseMs },
      memory: {
        rssBytes: memory.rss,
        heapUsedBytes: memory.heapUsed,
        heapTotalBytes: memory.heapTotal,
      },
      budget: {
        ...budget,
        tokenLimit: policy.globalDailyTokens,
        requestLimit: policy.globalDailyRequests,
        concurrencyLimit: policy.globalMaxConcurrent,
        limitsEnabled: policy.limitsEnabled,
        trialEnabled: policy.trialEnabled,
      },
      http,
      alerts,
      countingRule:
        'HTTP 统计仅限本 API 进程最近 60 个分钟桶，重启清零；SSE 的耗时含整段流，HTTP 200 中的业务错误不计为 5xx。预算来自数据库，UTC 0 点重置；无 usage 的请求保留预留量。',
    };
  }
}
