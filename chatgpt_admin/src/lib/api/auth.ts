import { api } from './client';
import type { AdminUser } from '@/types/entities';

export const authApi = {
  login: (userName: string, password: string) =>
    api
      .post<{ token: string; admin: AdminUser }>('/admin/login', { userName, password })
      .then((r) => r.data),

  me: () => api.get<AdminUser>('/admin/me').then((r) => r.data),

  changePassword: (oldPassword: string, newPassword: string) =>
    api.post('/admin/change-password', { oldPassword, newPassword }),
};
