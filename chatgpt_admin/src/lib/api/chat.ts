import {
  captureChatScope,
  assertChatScope,
  chatScopeCurrent,
  type ChatScope,
} from '@/lib/chat/scope';
import { ChatFailure, safeChatFailure } from '@/lib/chat/errors';
import { readPair, nonblank, type ChatPair } from '@/lib/chat/selection';
import { useAuthStore } from '@/store/authStore';

export interface ChatMessage {
  role: 'user' | 'assistant';
  content: string;
}
export interface CompletionRequest {
  model: string;
  providerCode: string;
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
  providerCode: string | null;
  userId?: number;
  updatedAt: string;
  createdAt: string;
}
interface Envelope<T> {
  code: number;
  data: T;
  ownerId?: number;
  conversationId?: number;
}
const messages = (value: ChatMessage[]) =>
  value.map((m) => ({ role: m.role, content: m.content }));
function authFailure(raw: unknown, status: number, path: string): ChatFailure {
  const value =
    raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  // CRUD有限认证响应与completion专门authError标记；上游401不能退出登录。
  const explicitAuth =
    value.authError === true ||
    (path.startsWith('/chat/conversations') &&
      value.code === -1 &&
      value.safeCode === 'authentication_error');
  return safeChatFailure({ ...value, authError: explicitAuth }, status);
}
function logoutOriginal(scope: ChatScope, error: ChatFailure) {
  if (error.authError && chatScopeCurrent(scope))
    useAuthStore.getState().logout();
}
async function scopedJson<T>(
  scope: ChatScope,
  path: string,
  method = 'GET',
  body?: unknown,
): Promise<Envelope<T>> {
  assertChatScope(scope);
  const abort = new AbortController(),
    timer = setTimeout(() => abort.abort(), 15000);
  try {
    const response = await fetch(scope.apiBase + path, {
      method,
      redirect: 'error',
      credentials: 'same-origin',
      signal: abort.signal,
      headers: {
        Authorization: `Bearer ${scope.session.token}`,
        'Content-Type': 'application/json',
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    assertChatScope(scope);
    let raw: unknown;
    try {
      raw = JSON.parse(await response.text());
    } catch {
      raw = null;
    }
    assertChatScope(scope);
    if (!response.ok) {
      const error = authFailure(raw, response.status, path);
      logoutOriginal(scope, error);
      throw error;
    }
    if (
      !raw ||
      typeof raw !== 'object' ||
      Array.isArray(raw) ||
      (raw as Envelope<T>).code !== 0
    )
      throw new ChatFailure('invalid_response');
    return raw as Envelope<T>;
  } catch (error) {
    throw safeChatFailure(error);
  } finally {
    clearTimeout(timer);
  }
}
function own<T>(data: Envelope<T>, scope: ChatScope, id?: number): T {
  assertChatScope(scope);
  if (
    data.ownerId !== scope.ownerId ||
    (id !== undefined && data.conversationId !== id)
  )
    throw new ChatFailure('ownership_unverified');
  return data.data;
}
function record(raw: ConversationRecord): ConversationRecord {
  if (
    !raw ||
    !Number.isSafeInteger(raw.id) ||
    raw.id <= 0 ||
    typeof raw.title !== 'string' ||
    !nonblank(raw.model) ||
    (raw.providerCode !== null && !nonblank(raw.providerCode))
  )
    throw new ChatFailure('invalid_response');
  return {
    id: raw.id,
    title: raw.title,
    model: raw.model,
    providerCode: raw.providerCode,
    userId: raw.userId,
    updatedAt: raw.updatedAt,
    createdAt: raw.createdAt,
  };
}
export const chatApi = {
  listConversations: async (scope = captureChatScope()) => {
    const list = own(
      await scopedJson<ConversationRecord[]>(scope, '/chat/conversations'),
      scope,
    );
    if (!Array.isArray(list)) throw new ChatFailure('invalid_response');
    const seen = new Set<number>();
    return list.map((r) => {
      const value = record(r);
      if (seen.has(value.id)) throw new ChatFailure('invalid_response');
      seen.add(value.id);
      return value;
    });
  },
  createConversation: async (pair: ChatPair, scope = captureChatScope()) => {
    const p = readPair(pair),
      response = await scopedJson<ConversationRecord>(
        scope,
        '/chat/conversations',
        'POST',
        { model: p.modelId, providerCode: p.providerCode },
      );
    const value = record(response.data);
    if (
      value.userId !== scope.ownerId ||
      value.model !== p.modelId ||
      value.providerCode !== p.providerCode
    )
      throw new ChatFailure('ownership_unverified');
    return value;
  },
  updateConversation: (id: number, title: string, scope = captureChatScope()) =>
    scopedJson(scope, `/chat/conversations/${id}`, 'PATCH', { title }),
  updateSelection: (id: number, pair: ChatPair, scope = captureChatScope()) => {
    const p = readPair(pair);
    return scopedJson(scope, `/chat/conversations/${id}`, 'PATCH', {
      model: p.modelId,
      providerCode: p.providerCode,
    });
  },
  deleteConversation: (id: number, scope = captureChatScope()) =>
    scopedJson(scope, `/chat/conversations/${id}`, 'DELETE'),
  listMessages: async (id: number, scope = captureChatScope()) => {
    const list = own(
      await scopedJson<ChatMessage[]>(
        scope,
        `/chat/conversations/${id}/messages`,
      ),
      scope,
      id,
    );
    if (
      !Array.isArray(list) ||
      list.some(
        (m) =>
          !m ||
          !['user', 'assistant'].includes(m.role) ||
          typeof m.content !== 'string',
      )
    )
      throw new ChatFailure('invalid_response');
    return messages(list);
  },
  saveMessages: async (
    id: number,
    increment: ChatMessage[],
    scope = captureChatScope(),
  ) =>
    own(
      await scopedJson<null>(
        scope,
        `/chat/conversations/${id}/messages`,
        'POST',
        { messages: messages(increment) },
      ),
      scope,
      id,
    ),
  resolveSelection: async (modelId: string, scope = captureChatScope()) => {
    if (!nonblank(modelId)) throw new ChatFailure('selection_required');
    const q = new URLSearchParams({ modelId });
    const reply = await scopedJson<ChatPair>(scope, '/ai/model-selection?' + q);
    const pair = readPair(reply.data);
    if (pair.modelId !== modelId) throw new ChatFailure('invalid_response');
    return pair;
  },
  metadata: async (scope = captureChatScope()) => {
    const [providers, models, config] = await Promise.all([
      scopedJson<{ list: unknown[] }>(scope, '/admin/ai/providers'),
      scopedJson<{ list: unknown[] }>(scope, '/admin/ai/models'),
      scopedJson<Record<string, unknown>>(scope, '/admin/ai/global'),
    ]);
    return {
      providers: providers.data.list,
      models: models.data.list,
      config: config.data,
    };
  },
  complete: async (body: CompletionRequest, scope = captureChatScope()) => {
    const pair = readPair({
      providerCode: body.providerCode,
      modelId: body.model,
    });
    const reply = await scopedJson<CompletionResponse>(
      scope,
      '/chat/completions',
      'POST',
      {
        ...body,
        model: pair.modelId,
        providerCode: pair.providerCode,
        messages: messages(body.messages),
      },
    );
    if (!reply.data || typeof reply.data.content !== 'string')
      throw new ChatFailure('invalid_response');
    return reply.data;
  },
  streamComplete: (
    body: CompletionRequest,
    onToken: (token: string) => void,
    onDone: () => void,
    onError: (error: ChatFailure) => void,
    scope = captureChatScope(),
  ): AbortController => {
    const abort = new AbortController();
    let settled = false,
      reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    const fail = (error: unknown) => {
      if (!settled) {
        settled = true;
        onError(safeChatFailure(error));
      }
    };
    const timer = setTimeout(() => {
      fail(new ChatFailure('total_timeout'));
      abort.abort();
    }, 90000);
    void (async () => {
      try {
        assertChatScope(scope);
        const pair = readPair({
          providerCode: body.providerCode,
          modelId: body.model,
        });
        const response = await fetch(
          scope.apiBase + '/chat/completions/stream',
          {
            method: 'POST',
            redirect: 'error',
            credentials: 'same-origin',
            signal: abort.signal,
            headers: {
              'Content-Type': 'application/json',
              Authorization: `Bearer ${scope.session.token}`,
            },
            body: JSON.stringify({
              ...body,
              model: pair.modelId,
              providerCode: pair.providerCode,
              messages: messages(body.messages),
            }),
          },
        );
        assertChatScope(scope);
        if (!response.ok) {
          let raw: unknown;
          try {
            raw = JSON.parse(await response.text());
          } catch {
            raw = null;
          }
          assertChatScope(scope);
          const error = authFailure(
            raw,
            response.status,
            '/chat/completions/stream',
          );
          logoutOriginal(scope, error);
          throw error;
        }
        if (!response.body) throw new ChatFailure('invalid_response');
        reader = response.body.getReader();
        const decoder = new TextDecoder('utf-8', { fatal: true });
        let buffer = '',
          doneMarker = false;
        const frame = (text: string) => {
          assertChatScope(scope);
          if (settled || doneMarker) return;
          const lines = text.split(/\r?\n/),
            data: string[] = [];
          let event = '';
          for (const line of lines) {
            if (line.startsWith('event:')) event = line.slice(6).trim();
            if (line.startsWith('data:'))
              data.push(line.slice(5).replace(/^ /, ''));
          }
          if (!data.length) return;
          const value = data.join('\n');
          if (value === '[DONE]') {
            doneMarker = true;
            return;
          }
          let raw: unknown;
          try {
            raw = JSON.parse(value);
          } catch {
            throw new ChatFailure('invalid_response');
          }
          if (!raw || typeof raw !== 'object' || Array.isArray(raw))
            throw new ChatFailure('invalid_response');
          const payload = raw as Record<string, unknown>;
          if (
            event === 'error' ||
            payload.error ||
            payload.code === 'upstream_error'
          ) {
            const failure = safeChatFailure(
              payload,
              Number.isSafeInteger(payload.statusCode)
                ? (payload.statusCode as number)
                : undefined,
            );
            throw new ChatFailure(failure.safeCode, failure.status, false);
          }
          if (!Array.isArray(payload.choices))
            throw new ChatFailure('invalid_response');
          for (const choice of payload.choices) {
            const c = choice as { delta?: { content?: unknown } };
            if (c.delta?.content !== undefined && c.delta.content !== null) {
              if (typeof c.delta.content !== 'string')
                throw new ChatFailure('invalid_response');
              onToken(c.delta.content);
            }
          }
        };
        while (!settled && !doneMarker) {
          const part = await reader.read();
          assertChatScope(scope);
          buffer += part.done
            ? decoder.decode()
            : decoder.decode(part.value, { stream: true });
          const frames = buffer.split(/\r?\n\r?\n/);
          buffer = frames.pop() ?? '';
          for (const text of frames) frame(text);
          if (part.done) {
            if (buffer.trim()) frame(buffer);
            break;
          }
        }
        assertChatScope(scope);
        if (abort.signal.aborted) throw new ChatFailure('cancelled');
        if (!doneMarker) throw new ChatFailure('stream_incomplete');
        if (!settled) {
          settled = true;
          onDone();
        }
      } catch (error) {
        fail(abort.signal.aborted ? new ChatFailure('cancelled') : error);
      } finally {
        clearTimeout(timer);
        try {
          await reader?.cancel();
        } catch {
          /* fixed terminal result */
        }
      }
    })();
    return abort;
  },
};
