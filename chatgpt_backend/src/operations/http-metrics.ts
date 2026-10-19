import type { RequestHandler } from 'express';

const groups = ['auth', 'chat', 'sync', 'update', 'admin', 'other'] as const;
type Group = (typeof groups)[number];
type Counter = {
  requests: number;
  serverErrors: number;
  rejected: number;
  aborted: number;
  totalMs: number;
  maxMs: number;
};
const empty = (): Counter => ({
  requests: 0,
  serverErrors: 0,
  rejected: 0,
  aborted: 0,
  totalMs: 0,
  maxMs: 0,
});

export function metricGroup(url: string): Group | null {
  const path = url.split('?')[0].toLowerCase();
  if (path === '/healthz' || path.startsWith('/uapi/admin/operations'))
    return null;
  if (path.startsWith('/uapi/auth/') || path.startsWith('/uapi/user/'))
    return 'auth';
  if (path.startsWith('/uapi/chat/')) return 'chat';
  if (path.startsWith('/uapi/sync')) return 'sync';
  if (path.startsWith('/uapi/checkupdate')) return 'update';
  if (path.startsWith('/uapi/admin/')) return 'admin';
  return 'other';
}

/** 固定六类、最多 60 个分钟桶；不保存 URL、账号、IP、正文或请求头。 */
export class HttpMetrics {
  private readonly buckets = new Map<number, Map<Group, Counter>>();
  private prune(now: number) {
    const minute = Math.floor(now / 60000);
    for (const key of this.buckets.keys())
      if (key < minute - 59 || key > minute) this.buckets.delete(key);
  }
  record(
    group: Group,
    status: number,
    ms: number,
    aborted = false,
    now = Date.now(),
  ) {
    this.prune(now);
    const minute = Math.floor(now / 60000);
    let bucket = this.buckets.get(minute);
    if (!bucket) this.buckets.set(minute, (bucket = new Map<Group, Counter>()));
    let counter = bucket.get(group);
    if (!counter) bucket.set(group, (counter = empty()));
    counter.requests++;
    if (!aborted && status >= 500) counter.serverErrors++;
    if (!aborted && [401, 403, 429].includes(status)) counter.rejected++;
    if (aborted) counter.aborted++;
    counter.totalMs += Math.max(0, ms);
    counter.maxMs = Math.max(counter.maxMs, ms);
  }
  snapshot(now = Date.now()) {
    this.prune(now);
    return groups.map((group) => {
      const sum = empty();
      for (const bucket of this.buckets.values()) {
        const value = bucket.get(group);
        if (!value) continue;
        for (const key of [
          'requests',
          'serverErrors',
          'rejected',
          'aborted',
          'totalMs',
        ] as const)
          sum[key] += value[key];
        sum.maxMs = Math.max(sum.maxMs, value.maxMs);
      }
      return {
        group,
        ...sum,
        averageMs: sum.requests ? Math.round(sum.totalMs / sum.requests) : 0,
        maxMs: Math.round(sum.maxMs),
      };
    });
  }
  middleware(): RequestHandler {
    return (req, res, next) => {
      const group = metricGroup(req.url);
      if (!group) return next();
      const started = performance.now();
      const finish = () => {
        res.off('close', close);
        this.record(group, res.statusCode, performance.now() - started);
      };
      const close = () => {
        res.off('finish', finish);
        this.record(group, res.statusCode, performance.now() - started, true);
      };
      res.once('finish', finish);
      res.once('close', close);
      next();
    };
  }
}
