import { api } from './client';
import type { Paged } from '@/types/api';
import type { Banner } from '@/types/entities';

export const bannerApi = {
  list: (params?: Record<string, string | number | undefined>) =>
    api.get<Paged<Banner>>('/admin/banners', { params }).then((r) => r.data),

  detail: (id: number) =>
    api.get<Banner>(`/admin/banners/${id}`).then((r) => r.data),

  create: (body: Partial<Banner>) =>
    api.post<Banner>('/admin/banners', body).then((r) => r.data),

  edit: (id: number, body: Partial<Banner>) =>
    api.patch<Banner>(`/admin/banners/${id}`, body).then((r) => r.data),

  delete: (id: number) => api.delete(`/admin/banners/${id}`),
};
