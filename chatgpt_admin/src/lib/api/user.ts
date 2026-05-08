import { api } from './client';
import type { Paged } from '@/types/api';
import type { AppUser } from '@/types/entities';

export const userApi = {
  list: (params: Record<string, string | number | undefined>) =>
    api.get<Paged<AppUser>>('/admin/users', { params }).then((r) => r.data),

  detail: (id: number) =>
    api.get<AppUser>(`/admin/users/${id}`).then((r) => r.data),

  edit: (id: number, body: Partial<AppUser>) =>
    api.patch(`/admin/users/${id}`, body).then((r) => r.data),

  resetPassword: (id: number, password: string) =>
    api.post(`/admin/users/${id}/reset-password`, { password }),

  delete: (id: number) => api.delete(`/admin/users/${id}`),
};
