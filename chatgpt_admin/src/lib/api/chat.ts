import { api } from './client';
import { useAuthStore } from '@/store/authStore';

export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}

export interface CompletionRequest {
  model: string;
  messages: ChatMessage[];
  max_tokens?: number;
}

export interface CompletionResponse {
  content: string;
  reasoningContent?: string;
  model?: string;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
}

export interface ConversationRecord {
  id: number;
  title: string;
  model: string;
  updatedAt: string;
  createdAt: string;
}

export const chatApi = {
  // --- Conversations ---
  listConversations: () =>
    api.get<ConversationRecord[]>('/chat/conversations').then((r) => r.data),

  createConversation: (model: string) =>
    api.post<ConversationRecord>('/chat/conversations', { model }).then((r) => r.data),

  updateConversation: (id: number, title: string) =>
    api.patch(`/chat/conversations/${id}`, { title }),

  deleteConversation: (id: number) =>
    api.delete(`/chat/conversations/${id}`),

  // --- Messages ---
  listMessages: (convId: number) =>
    api.get<ChatMessage[]>(`/chat/conversations/${convId}/messages`).then((r) => r.data),

  saveMessages: (convId: number, messages: ChatMessage[]) =>
    api.post(`/chat/conversations/${convId}/messages`, { messages }),

  /** 非流式对话 */
  complete: (body: CompletionRequest) =>
    api
      .post<CompletionResponse>('/chat/completions', body)
      .then((r) => r.data),

  /** 流式对话 - 返回 SSE 流文本 */
  streamComplete: (
    body: CompletionRequest,
    onToken: (token: string) => void,
    onDone: () => void,
    onError: (err: Error) => void,
  ): AbortController => {
    const controller = new AbortController();

    const token = useAuthStore.getState().token;
    const authHeader = token ? `Bearer ${token}` : '';
    const baseURL = api.defaults.baseURL || '/api';

    fetch(`${baseURL}/chat/completions/stream`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: authHeader,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    })
      .then(async (resp) => {
        if (!resp.ok) {
          const text = await resp.text();
          throw new Error(text || `HTTP ${resp.status}`);
        }
        const reader = resp.body?.getReader();
        if (!reader) throw new Error('No response body');

        const decoder = new TextDecoder();
        let buffer = '';

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() || '';

          for (const rawLine of lines) {
            const line = rawLine.trimEnd();
            if (!line.startsWith('data: ')) continue;
            const data = line.slice(6);
            if (data === '[DONE]') continue;
            try {
              const json = JSON.parse(data);
              const choices = json?.choices;
              if (choices && Array.isArray(choices) && choices.length > 0) {
                const delta = choices[0]?.delta;
                if (delta && typeof delta === 'object') {
                  const content = delta.content;
                  if (typeof content === 'string' && content.length > 0) {
                    onToken(content);
                  }
                }
              }
            } catch {
              // skip unparseable SSE lines
            }
          }
        }
        onDone();
      })
      .catch((err) => {
        if (err.name !== 'AbortError') {
          onError(err instanceof Error ? err : new Error(String(err)));
        }
      });

    return controller;
  },
};
