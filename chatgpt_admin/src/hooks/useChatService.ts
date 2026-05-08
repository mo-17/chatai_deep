'use client';

import { useState, useCallback, useRef, useEffect } from 'react';
import { chatApi, type ChatMessage } from '@/lib/api/chat';
import type { Conversation } from '@/components/ai-chat/chat-sidebar';

export interface ChatState {
  conversations: Conversation[];
  activeId: string | null;
  messages: ChatMessage[];
  isLoading: boolean;
  error: string | null;
}

export function useChatService() {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  // 后端数字 ID 对应的映射表
  const idMap = useRef<Map<string, number>>(new Map());

  // 挂载时从后端加载对话列表
  useEffect(() => {
    chatApi.listConversations().then((list) => {
      const convs: Conversation[] = list.map((r) => {
        const id = String(r.id);
        idMap.current.set(id, r.id);
        return { id, title: r.title, updatedAt: new Date(r.updatedAt).getTime() };
      });
      setConversations(convs);
    }).catch(() => {
      // 加载失败时列表为空
    });
  }, []);

  // 新建对话
  const newConversation = useCallback((): string => {
    // 先生成一个临时 ID，后续后端返回真实 ID 后替换
    const tempId = `new_${Date.now()}`;
    const conv: Conversation = { id: tempId, title: '', updatedAt: Date.now() };
    setConversations((prev) => [conv, ...prev]);
    setActiveId(tempId);
    setMessages([]);
    setError(null);
    return tempId;
  }, []);

  // 选择对话 — 从后端加载历史消息
  const selectConversation = useCallback((id: string) => {
    setActiveId(id);
    setMessages([]);
    setError(null);
    const backendId = idMap.current.get(id);
    if (backendId) {
      chatApi.listMessages(backendId).then((msgs) => {
        setMessages(msgs);
      }).catch(() => {
        // 加载失败时保持空列表
      });
    }
  }, []);

  // 删除对话
  const deleteConversation = useCallback(
    (id: string) => {
      const backendId = idMap.current.get(id);
      if (backendId) {
        chatApi.deleteConversation(backendId).catch(() => {});
        idMap.current.delete(id);
      }
      setConversations((prev) => prev.filter((c) => c.id !== id));
      if (activeId === id) {
        setActiveId(null);
        setMessages([]);
      }
    },
    [activeId],
  );

  // 重命名
  const renameConversation = useCallback((id: string, title: string) => {
    const backendId = idMap.current.get(id);
    if (backendId) {
      chatApi.updateConversation(backendId, title).catch(() => {});
    }
    setConversations((prev) =>
      prev.map((c) => (c.id === id ? { ...c, title } : c)),
    );
  }, []);

  // 取消当前请求
  const cancelRequest = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
    setIsLoading(false);
  }, []);

  // 确保对话已持久化到后端，返回后端数字 ID
  const ensureBackendConv = useCallback(
    async (model: string): Promise<number | null> => {
      // 查找当前临时 ID 对应的对话
      const tempConv = conversations.find((c) => c.id === activeId);
      if (!tempConv) return null;

      // 已经有后端 ID 了
      const existing = idMap.current.get(tempConv.id);
      if (existing) return existing;

      // 需要创建后端记录
      try {
        const record = await chatApi.createConversation(model);
        const backendId = record.id;
        const finalId = String(backendId);
        idMap.current.set(finalId, backendId);

        // 替换临时 ID
        setConversations((prev) =>
          prev.map((c) =>
            c.id === tempConv.id ? { ...c, id: finalId } : c,
          ),
        );
        setActiveId(finalId);
        return backendId;
      } catch {
        return null;
      }
    },
    [activeId, conversations],
  );

  // 发送消息（流式）
  const sendMessage = useCallback(
    async (content: string, model = 'deepseek-chat', convId?: string) => {
      if (!content.trim() || isLoading) return;

      const targetId = convId || activeId;
      if (!targetId) return;

      // 确保后端有这条对话记录
      const backendId = await ensureBackendConv(model);
      if (!backendId) return;

      setError(null);
      setIsLoading(true);

      const userMsg: ChatMessage = { role: 'user', content };
      const newMessages = [...messages, userMsg];
      setMessages(newMessages);

      // 如果当前对话无标题，用首条消息作为标题
      const targetConv = conversations.find((c) => c.id === targetId) || null;
      if (targetConv && !targetConv.title) {
        const title = content.slice(0, 30) + (content.length > 30 ? '...' : '');
        renameConversation(targetId, title);
      }

      // 空 AI 消息占位
      const aiMsg: ChatMessage = { role: 'assistant', content: '' };
      setMessages([...newMessages, aiMsg]);

      const history: ChatMessage[] = [
        ...newMessages.filter((m) => m.content.length > 0),
      ];

      abortRef.current = chatApi.streamComplete(
        { model, messages: history, max_tokens: 2000 },
        (token) => {
          setMessages((prev) => {
            const copy = [...prev];
            const last = copy[copy.length - 1];
            if (last && last.role === 'assistant') {
              copy[copy.length - 1] = {
                ...last,
                content: last.content + token,
              };
            }
            return copy;
          });
        },
        () => {
          setIsLoading(false);
          abortRef.current = null;
          // 更新 conversation 时间
          setConversations((prev) =>
            prev.map((c) =>
              c.id === targetId ? { ...c, updatedAt: Date.now() } : c,
            ),
          );
          // 保存消息到后端
          setMessages((prev) => {
            const msgs = prev.filter((m) => m.content.length > 0);
            chatApi.saveMessages(backendId, msgs).catch(() => {});
            return prev;
          });
        },
        (err) => {
          setError(err.message);
          setIsLoading(false);
          abortRef.current = null;
          // 保留已收到的内容并保存
          setMessages((prev) => {
            const copy = [...prev];
            const last = copy[copy.length - 1];
            if (last && last.role === 'assistant' && last.content === '') {
              copy[copy.length - 1] = {
                ...last,
                content: `[错误] ${err.message}`,
              };
            }
            const msgs = copy.filter((m) => m.content.length > 0);
            chatApi.saveMessages(backendId, msgs).catch(() => {});
            return copy;
          });
        },
      );
    },
    [messages, isLoading, activeId, conversations, renameConversation, ensureBackendConv],
  );

  return {
    conversations,
    activeId,
    messages,
    isLoading,
    error,
    newConversation,
    selectConversation,
    deleteConversation,
    renameConversation,
    sendMessage,
    cancelRequest,
  };
}
