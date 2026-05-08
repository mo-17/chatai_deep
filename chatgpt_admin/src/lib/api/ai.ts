import { api } from './client';
import type { AiProvider, AiModel, AiGlobalConfig, TestConnectionResult } from '@/types/ai';

export const aiApi = {
  // Providers
  listProviders: () =>
    api.get<{ list: AiProvider[] }>('/admin/ai/providers').then((r) => r.data),

  getProvider: (id: number) =>
    api.get<AiProvider>(`/admin/ai/providers/${id}`).then((r) => r.data),

  createProvider: (body: Partial<AiProvider>) =>
    api.post<AiProvider>('/admin/ai/providers', body).then((r) => r.data),

  updateProvider: (id: number, body: Partial<AiProvider>) =>
    api.patch<AiProvider>(`/admin/ai/providers/${id}`, body).then((r) => r.data),

  deleteProvider: (id: number) =>
    api.delete(`/admin/ai/providers/${id}`),

  testProvider: (id: number) =>
    api.post<TestConnectionResult>(`/admin/ai/providers/${id}/test`).then((r) => r.data),

  // Models
  listModels: (params?: { providerId?: string; enabled?: string; keyword?: string }) =>
    api.get<{ list: AiModel[] }>('/admin/ai/models', { params }).then((r) => r.data),

  getModel: (id: number) =>
    api.get<AiModel>(`/admin/ai/models/${id}`).then((r) => r.data),

  createModel: (body: Partial<AiModel>) =>
    api.post<AiModel>('/admin/ai/models', body).then((r) => r.data),

  updateModel: (id: number, body: Partial<AiModel>) =>
    api.patch<AiModel>(`/admin/ai/models/${id}`, body).then((r) => r.data),

  deleteModel: (id: number) =>
    api.delete(`/admin/ai/models/${id}`),

  setDefaultModel: (id: number) =>
    api.post<AiModel>(`/admin/ai/models/${id}/set-default`).then((r) => r.data),

  // Global
  getGlobal: () =>
    api.get<AiGlobalConfig>('/admin/ai/global').then((r) => r.data),

  updateGlobal: (body: Partial<AiGlobalConfig>) =>
    api.patch<AiGlobalConfig>('/admin/ai/global', body).then((r) => r.data),

  uploadAvatar: (base64: string) =>
    api.post<{ avatarUrl: string }>('/admin/ai/global/avatar', { base64 }).then((r) => r.data),
};
