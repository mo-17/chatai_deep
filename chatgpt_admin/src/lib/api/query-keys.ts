export const qk = {
  usage: {
    all: ['usage'] as const,
    summary: () => [...qk.usage.all, 'summary'] as const,
    series: (from?: string, to?: string) => [...qk.usage.all, 'series', { from, to }] as const,
    byProvider: () => [...qk.usage.all, 'by-provider'] as const,
    topUsers: (limit: number, days: number) => [...qk.usage.all, 'top', limit, days] as const,
    list: (q: Record<string, unknown>) => [...qk.usage.all, 'list', q] as const,
  },
  user: {
    all: ['user'] as const,
    list: (q: Record<string, unknown>) => [...qk.user.all, 'list', q] as const,
    detail: (id: number) => [...qk.user.all, 'detail', id] as const,
  },
  banner: {
    all: ['banner'] as const,
    list: (q: Record<string, unknown>) => [...qk.banner.all, 'list', q] as const,
    detail: (id: number) => [...qk.banner.all, 'detail', id] as const,
  },
  version: {
    all: ['version'] as const,
    list: (q: Record<string, unknown>) => [...qk.version.all, 'list', q] as const,
    detail: (id: number) => [...qk.version.all, 'detail', id] as const,
  },
  ai: {
    providers: ['ai', 'providers'] as const,
    models: ['ai', 'models'] as const,
    global: ['ai', 'global'] as const,
  },
};
