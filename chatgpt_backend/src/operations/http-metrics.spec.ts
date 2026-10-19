import { EventEmitter } from 'node:events';
import type { Request, Response } from 'express';
import { HttpMetrics, metricGroup } from './http-metrics';

describe('bounded HTTP metrics', () => {
  it('never retains arbitrary path, query, account, credentials or IP dimensions', () => {
    expect(metricGroup('/uapi/auth/login/password?secret=x')).toBe('auth');
    expect(metricGroup('/uapi/admin/users/987654')).toBe('admin');
    expect(metricGroup('/healthz')).toBeNull();
    expect(metricGroup('/uapi/admin/operations')).toBeNull();
    const metrics = new HttpMetrics();
    for (let i = 0; i < 10000; i++)
      metrics.record('other', 200, 3, false, i * 60000);
    expect(
      metrics
        .snapshot(9999 * 60000)
        .reduce((sum, row) => sum + row.requests, 0),
    ).toBe(60);
    expect(JSON.stringify(metrics.snapshot(10060 * 60000))).not.toContain(
      'secret',
    );
    expect(
      metrics.snapshot(10060 * 60000).every((row) => row.requests === 0),
    ).toBe(true);
  });
  it('counts 5xx, denials, aborted connections and latency separately', () => {
    const metrics = new HttpMetrics();
    metrics.record('chat', 500, 100);
    metrics.record('chat', 429, 200);
    metrics.record('chat', 200, 300, true);
    expect(
      metrics.snapshot().find((row) => row.group === 'chat'),
    ).toMatchObject({
      requests: 3,
      serverErrors: 1,
      rejected: 1,
      aborted: 1,
      averageMs: 200,
      maxMs: 300,
    });
  });
  it('finish followed by close is counted once; close before finish counts as abort', () => {
    const metrics = new HttpMetrics();
    const res = Object.assign(new EventEmitter(), { statusCode: 200 });
    const req = { url: '/uapi/chat/completions' } as Request;
    const next = jest.fn();
    metrics.middleware()(req, res as unknown as Response, next);
    res.emit('finish');
    res.emit('close');
    metrics.middleware()(req, res as unknown as Response, next);
    res.emit('close');
    res.emit('finish');
    expect(
      metrics.snapshot().find((row) => row.group === 'chat'),
    ).toMatchObject({ requests: 2, aborted: 1 });
    expect(res.listenerCount('finish') + res.listenerCount('close')).toBe(0);
    expect(next).toHaveBeenCalledTimes(2);
  });
});
