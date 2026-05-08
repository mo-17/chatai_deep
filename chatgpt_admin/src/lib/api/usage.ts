import { api } from './client';
import type { Paged } from '@/types/api';
import type { UsageRecord, UsageSummary } from '@/types/entities';

export const usageApi = {
  list: (params: Record<string, string | number | undefined>) =>
    api.get<Paged<UsageRecord>>('/admin/usage/list', { params }).then((r) => r.data),

  summary: () =>
    api.get<UsageSummary>('/admin/usage/summary').then((r) => r.data),

  series: (from?: string, to?: string) =>
    api
      .get<{ list: Array<{ date: string; tokens: number; calls: number }> }>(
        '/admin/usage/series',
        { params: { from, to } },
      )
      .then((r) => r.data),

  byProvider: () =>
    api
      .get<{ list: Array<{ provider: string; tokens: number; calls: number }> }>(
        '/admin/usage/by-provider',
      )
      .then((r) => r.data),

  topUsers: (limit = 10, days = 7) =>
    api
      .get<{
        list: Array<{ userId: number; userName: string; tokens: number; calls: number }>;
      }>('/admin/usage/top-users', { params: { limit, days } })
      .then((r) => r.data),

  exportCsv: async (params: Record<string, string | number | undefined>) => {
    const token = (await import('@/store/authStore')).useAuthStore.getState().token;
    const qs = new URLSearchParams();
    Object.entries(params).forEach(([k, v]) => {
      if (v !== undefined && v !== '') qs.set(k, String(v));
    });
    const resp = await fetch(`/api/admin/usage/export?${qs.toString()}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!resp.ok) throw new Error('导出失败');
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `usage-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  },
};
