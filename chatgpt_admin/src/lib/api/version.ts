import { api } from './client';
import type { Paged } from '@/types/api';
import type { AppVersion } from '@/types/entities';

export const versionApi = {
  list: (params?: Record<string, string | number | undefined>) =>
    api.get<Paged<AppVersion>>('/admin/versions', { params }).then((r) => r.data),

  detail: (id: number) =>
    api.get<AppVersion>(`/admin/versions/${id}`).then((r) => r.data),

  create: (body: Partial<AppVersion>) =>
    api.post<AppVersion>('/admin/versions', body).then((r) => r.data),

  edit: (id: number, body: Partial<AppVersion>) =>
    api.patch<AppVersion>(`/admin/versions/${id}`, body).then((r) => r.data),

  delete: (id: number) => api.delete(`/admin/versions/${id}`),
};
