'use client';

import { useEffect, useMemo, useSyncExternalStore } from 'react';
import { useAuthStore } from '@/store/authStore';
import { ChatController } from '@/lib/chat/controller';
import { chatContextSignature } from '@/lib/chat/scope';

export function useChatService() {
  useAuthStore((s) => s.token);
  useAuthStore((s) => s.sessionEpoch);
  useAuthStore((s) => s.admin?.id);
  const signature = chatContextSignature();
  const controller = useMemo(() => new ChatController(signature), [signature]);
  const snapshot = useSyncExternalStore(
    controller.subscribe,
    controller.getSnapshot,
    controller.getSnapshot,
  );
  useEffect(() => controller.activate(), [controller]);
  return {
    ...snapshot,
    newConversation: controller.newConversation,
    selectConversation: controller.selectConversation,
    deleteConversation: controller.deleteConversation,
    renameConversation: controller.renameConversation,
    sendMessage: controller.sendMessage,
    cancelRequest: controller.cancelRequest,
    chooseSelection: controller.chooseSelection,
    refreshMetadata: controller.refreshMetadata,
    refreshConversations: controller.refreshConversations,
  };
}
