import { api } from './client';
import { assertAuthSession, type AuthSession } from './auth-session';
import type { ModelSyncPreview, ModelSyncResult } from '@/types/model-sync';

export const modelSyncApi = {
  async preview(providerId: number, session: AuthSession) {
    assertAuthSession(session);
    const result = await api.post<ModelSyncPreview>(
      `/admin/ai/providers/${providerId}/model-sync/preview`,
      {},
      {
        authScoped: true,
        authSession: session,
      } as Parameters<typeof api.post>[2],
    );
    assertAuthSession(session);
    return result.data;
  },
  async import(
    providerId: number,
    previewId: string,
    modelIds: string[],
    session: AuthSession,
  ) {
    assertAuthSession(session);
    const result = await api.post<ModelSyncResult>(
      `/admin/ai/providers/${providerId}/model-sync/import`,
      { previewId, modelIds },
      {
        authScoped: true,
        authSession: session,
      } as Parameters<typeof api.post>[2],
    );
    assertAuthSession(session);
    return result.data;
  },
};
