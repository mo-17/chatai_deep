import { api } from './client';
import {
  assertChatScope,
  captureChatScope,
  type ChatScope,
} from '@/lib/chat/scope';
import { ChatFailure } from '@/lib/chat/errors';
import type { Paged } from '@/types/api';
import type { UsageRecord, UsageSummary } from '@/types/entities';

function scopedOptions(scope: ChatScope) {
  assertChatScope(scope);
  return {
    baseURL: scope.apiBase,
    authScoped: true,
    authSession: scope.session,
  };
}
async function scopedRead<T>(
  path: string,
  params: Record<string, string | number | undefined>,
  scope: ChatScope,
): Promise<T> {
  const reply = await api.get<T>(path, { ...scopedOptions(scope), params });
  assertChatScope(scope);
  return reply.data;
}
export const usageApi = {
  list: (
    params: Record<string, string | number | undefined>,
    scope = captureChatScope(),
  ) => scopedRead<Paged<UsageRecord>>('/admin/usage/list', params, scope),

  providerOptions: async (scope = captureChatScope()) => {
    const [configured, historical] = await Promise.all([
      scopedRead<{ list: Array<{ code: string; displayName: string }> }>(
        '/admin/ai/providers',
        {},
        scope,
      ),
      scopedRead<{ list: Array<{ provider: string }> }>(
        '/admin/usage/by-provider',
        {},
        scope,
      ),
    ]);
    const options = new Map<string, string>();
    if (!Array.isArray(configured.list) || !Array.isArray(historical.list))
      throw new ChatFailure('invalid_response');
    for (const p of configured.list) {
      if (
        typeof p.code !== 'string' ||
        !/\S/.test(p.code) ||
        typeof p.displayName !== 'string'
      )
        throw new ChatFailure('invalid_response');
      options.set(p.code, `${p.displayName}（${p.code}）`);
    }
    for (const h of historical.list) {
      if (typeof h.provider !== 'string' || !/\S/.test(h.provider))
        throw new ChatFailure('invalid_response');
      if (!options.has(h.provider))
        options.set(h.provider, `${h.provider}（历史记录，当前配置已删除）`);
    }
    assertChatScope(scope);
    return Array.from(options, ([key, label]) => ({ key, label }));
  },

  summary: () =>
    api.get<UsageSummary>('/admin/usage/summary').then((r) => r.data),

  series: (from?: string, to?: string) =>
    api
      .get<{
        list: Array<{ date: string; tokens: number; calls: number }>;
      }>('/admin/usage/series', { params: { from, to } })
      .then((r) => r.data),

  byProvider: () =>
    api
      .get<{
        list: Array<{ provider: string; tokens: number; calls: number }>;
      }>('/admin/usage/by-provider')
      .then((r) => r.data),

  topUsers: (limit = 10, days = 7) =>
    api
      .get<{
        list: Array<{
          userId: number;
          userName: string;
          tokens: number;
          calls: number;
        }>;
      }>('/admin/usage/top-users', { params: { limit, days } })
      .then((r) => r.data),

  exportCsv: async (
    params: Record<string, string | number | undefined>,
    scope = captureChatScope(),
  ) => {
    assertChatScope(scope);
    const qs = new URLSearchParams();
    Object.entries(params).forEach(([k, v]) => {
      if (v !== undefined && v !== '') qs.set(k, String(v));
    });
    const resp = await fetch(
      `${scope.apiBase}/admin/usage/export?${qs.toString()}`,
      {
        redirect: 'error',
        headers: { Authorization: `Bearer ${scope.session.token}` },
      },
    );
    assertChatScope(scope);
    if (!resp.ok) throw new ChatFailure('request_failed');
    const blob = await resp.blob();
    assertChatScope(scope);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `usage-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  },
};
