import { Injectable, BadGatewayException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import type { Response } from 'express';
import { Usage } from './usage.entity';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import {
  resolveReasoningControl,
  type ReasoningPolicy,
} from './reasoning-control';
import {
  StreamDeadlineController,
  type StreamDeadlineKind,
  type StreamRequestProfile,
} from './stream-deadline-controller';
import {
  SafeUpstreamException,
  safeFailureFromResponse,
  safeFailureFromSsePayload,
} from './upstream-error';

export interface CompletionBody {
  model: string;
  messages: Record<string, unknown>[];
  max_tokens?: number;
  temperature?: number;
  top_p?: number;
  // 工具调用声明（阶段六）：随 body 展开原样转发给上游。
  tools?: Record<string, unknown>[];
  request_profile?: StreamRequestProfile;
  reasoning_policy?: ReasoningPolicy;
}

export interface UpstreamResponse {
  choices?: Array<{
    message?: {
      content?: string;
      reasoning_content?: string;
      role?: string;
    };
  }>;
  model?: string;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
  error?: { message?: string; code?: unknown; type?: unknown };
  [key: string]: unknown;
}

const SSE_SEP = /\r?\n\r?\n/;

@Injectable()
export class ChatService {
  constructor(
    @InjectRepository(Usage)
    private readonly usageRepo: Repository<Usage>,
    @InjectRepository(Conversation)
    private readonly convRepo: Repository<Conversation>,
    @InjectRepository(Message)
    private readonly msgRepo: Repository<Message>,
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    @InjectRepository(AiModel)
    private readonly modelRepo: Repository<AiModel>,
    @InjectRepository(AiGlobalConfig)
    private readonly globalRepo: Repository<AiGlobalConfig>,
    private readonly providerCache: ProviderCacheService,
  ) {}

  // --- Conversation CRUD ---

  async listConversations(userId: number) {
    return this.convRepo.find({
      where: { userId },
      order: { updatedAt: 'DESC' },
      select: ['id', 'title', 'model', 'updatedAt', 'createdAt'],
    });
  }

  async createConversation(userId: number, model: string) {
    const conv = this.convRepo.create({ userId, model, title: '' });
    return this.convRepo.save(conv);
  }

  async updateConversation(userId: number, id: number, title: string) {
    await this.convRepo.update({ id, userId }, { title });
  }

  async deleteConversation(userId: number, id: number) {
    await this.msgRepo.delete({ conversationId: id });
    await this.convRepo.delete({ id, userId });
  }

  // --- Message CRUD ---

  async listMessages(conversationId: number) {
    return this.msgRepo.find({
      where: { conversationId },
      order: { id: 'ASC' },
      select: ['role', 'content'],
    });
  }

  async saveMessages(
    conversationId: number,
    msgs: { role: 'user' | 'assistant'; content: string }[],
  ) {
    const entities = msgs.map((m) =>
      this.msgRepo.create({ conversationId, ...m }),
    );
    return this.msgRepo.save(entities);
  }

  // --- Non-streaming completion ---

  async complete(userId: number, body: CompletionBody) {
    const provider = await this.resolveProvider(body.model);
    const data = await this.callUpstream(provider, body);

    if (data.usage) {
      void this.usageRepo
        .save({
          userId,
          provider: provider.code,
          model: body.model,
          promptTokens: data.usage.prompt_tokens || 0,
          completionTokens: data.usage.completion_tokens || 0,
          totalTokens: data.usage.total_tokens || 0,
        })
        .catch((e) => {
          console.error('[usage] save failed', e);
        });
    }

    const choice = data.choices?.[0];
    const message = choice?.message;
    return {
      content: message?.content || '',
      reasoningContent: message?.reasoning_content || '',
      model: data.model || body.model,
      usage: data.usage || null,
    };
  }

  async callUpstream(
    provider: AiProvider,
    body: CompletionBody,
  ): Promise<UpstreamResponse> {
    assertProviderAvailable(provider);

    const url = `${provider.baseUrl}/chat/completions`;
    const reasoningControl = requestReasoningControl(provider, body);
    const upstreamBody = buildUpstreamBody(body, reasoningControl);
    const t0 = Date.now();
    try {
      const resp = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${provider.apiKey}`,
        },
        body: JSON.stringify(upstreamBody),
      });

      if (!resp.ok) {
        throw await safeFailureFromResponse(resp);
      }
      const data: UpstreamResponse = (await resp.json()) as UpstreamResponse;

      console.log(
        `[upstream] ${provider.code}/${body.model} ${Date.now() - t0}ms tokens=${data.usage?.total_tokens ?? '?'}`,
      );
      return data;
    } catch (e) {
      if (e instanceof SafeUpstreamException) {
        throw classifyReasoningControlFailure(e, reasoningControl);
      }
      throw new SafeUpstreamException({ safeCode: 'request_failed' });
    }
  }

  // --- SSE streaming completion ---

  async completeStream(
    userId: number,
    body: CompletionBody,
    res: Response,
    clientSignal: AbortSignal = new AbortController().signal,
  ) {
    const provider = await this.resolveProvider(body.model);
    assertProviderAvailable(provider);
    if (clientSignal.aborted) return;

    const url = `${provider.baseUrl}/chat/completions`;
    const requestProfile = safeRequestProfile(body.request_profile);
    const reasoningControl = requestReasoningControl(provider, body);
    const streamBody = {
      ...buildUpstreamBody(body, reasoningControl),
      stream: true,
      stream_options: { include_usage: true },
    };

    const upstreamController = new AbortController();
    const abortUpstreamForClient = () => upstreamController.abort();
    clientSignal.addEventListener('abort', abortUpstreamForClient, {
      once: true,
    });
    if (clientSignal.aborted) abortUpstreamForClient();
    const deadlines = new StreamDeadlineController({
      profile: requestProfile,
      upstreamController,
    });
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    let lastUsage: UpstreamResponse['usage'] = undefined;
    let completedNormally = false;

    try {
      const upstreamResp = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${provider.apiKey}`,
        },
        body: JSON.stringify(streamBody),
        signal: upstreamController.signal,
      });

      if (!upstreamResp.ok) throw await safeFailureFromResponse(upstreamResp);
      if (!upstreamResp.body) {
        throw new SafeUpstreamException({ safeCode: 'request_failed' });
      }
      if (clientSignal.aborted || !isResponseWritable(res)) return;

      res.status(200);
      res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
      res.setHeader('Cache-Control', 'no-cache, no-transform');
      res.setHeader('Connection', 'keep-alive');
      res.setHeader('X-Accel-Buffering', 'no');
      res.flushHeaders();

      reader = upstreamResp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let upstreamDone = false;

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          buffer += decoder.decode();
          break;
        }
        if (value.byteLength > 0) deadlines.markActivity();
        buffer += decoder.decode(value, { stream: true });

        let idx: number;
        while ((idx = buffer.search(SSE_SEP)) !== -1) {
          const separatorLength = buffer[idx] === '\r' ? 4 : 2;
          const block = buffer.slice(0, idx);
          buffer = buffer.slice(idx + separatorLength);
          const inspected = inspectSseBlock(block);
          if (inspected.usage) lastUsage = inspected.usage;
          if (inspected.done) {
            upstreamDone = true;
            break;
          }
          if (isResponseWritable(res) && !clientSignal.aborted) {
            res.write(`${block}\n\n`);
          }
        }
        if (upstreamDone) {
          buffer = '';
          break;
        }
      }

      if (buffer.trim()) {
        const inspected = inspectSseBlock(buffer);
        if (inspected.usage) lastUsage = inspected.usage;
        if (
          !inspected.done &&
          isResponseWritable(res) &&
          !clientSignal.aborted
        ) {
          res.write(buffer);
        }
      }

      if (isResponseWritable(res) && !clientSignal.aborted) {
        res.write('data: [DONE]\n\n');
        completedNormally = true;
        res.end();
      }
    } catch (error) {
      if (upstreamController.signal.aborted) {
        const deadlineKind = deadlines.expiredKind;
        if (deadlineKind !== null) {
          throw new SafeUpstreamException({
            statusCode: 504,
            safeCode: safeCodeForDeadline(deadlineKind),
          });
        }
        if (clientSignal.aborted) return;
      }
      if (error instanceof SafeUpstreamException) {
        throw classifyReasoningControlFailure(error, reasoningControl);
      }
      throw new SafeUpstreamException({ safeCode: 'request_failed' });
    } finally {
      if (reader) {
        try {
          await reader.cancel();
        } catch {
          // 流已关闭或失败，无需再次暴露错误。
        }
        try {
          reader.releaseLock();
        } catch {
          // reader 已释放。
        }
      }
      deadlines.dispose();
      clientSignal.removeEventListener('abort', abortUpstreamForClient);
    }

    // Fire-and-forget usage save
    if (lastUsage && completedNormally) {
      void this.usageRepo
        .save({
          userId,
          provider: provider.code,
          model: body.model,
          promptTokens: lastUsage.prompt_tokens || 0,
          completionTokens: lastUsage.completion_tokens || 0,
          totalTokens: lastUsage.total_tokens || 0,
        })
        .catch((e) => {
          console.error('[usage] save failed', e);
        });
    }
  }

  async resolveProvider(model: string): Promise<AiProvider> {
    // 1. Check cache
    const cacheKey = `model:${model}`;
    const cached = this.providerCache.get(cacheKey);
    if (cached) return cached;

    // 2. 精确匹配 ai_models 表
    const modelRow = await this.modelRepo.findOne({
      where: { modelId: model, enabled: true },
    });
    if (modelRow) {
      const provider = await this.providerRepo.findOne({
        where: { id: modelRow.providerId },
      });
      if (provider) {
        this.providerCache.set(cacheKey, provider);
        return provider;
      }
    }

    // 3. 按 modelPrefixes 前缀匹配
    const providers = await this.providerRepo.find({
      where: { enabled: true },
      order: { sortOrder: 'DESC' },
    });
    for (const p of providers) {
      if (p.modelPrefixes) {
        const prefixes = p.modelPrefixes
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean);
        for (const prefix of prefixes) {
          if (model.startsWith(prefix)) {
            this.providerCache.set(cacheKey, p);
            return p;
          }
        }
      }
    }

    // 4. 兜底：全局默认 provider
    const global = await this.globalRepo.findOne({ where: { id: 1 } });
    const defaultCode = global?.defaultProviderCode || 'deepseek';
    const fallback = await this.providerRepo.findOne({
      where: { code: defaultCode },
    });
    if (!fallback) {
      throw new BadGatewayException('没有可用的 AI 服务商');
    }

    console.warn(
      `model "${model}" 未匹配任何 provider，fallback to default provider: ${defaultCode}`,
    );
    this.providerCache.set(cacheKey, fallback);
    return fallback;
  }
}

function buildUpstreamBody(
  body: CompletionBody,
  reasoningControl: Record<string, unknown>,
): Record<string, unknown> {
  return {
    model: body.model,
    messages: body.messages,
    ...(body.max_tokens === undefined ? {} : { max_tokens: body.max_tokens }),
    ...(body.temperature === undefined
      ? {}
      : { temperature: body.temperature }),
    ...(body.top_p === undefined ? {} : { top_p: body.top_p }),
    ...(body.tools === undefined ? {} : { tools: body.tools }),
    ...reasoningControl,
  };
}

function requestReasoningControl(
  provider: AiProvider,
  body: CompletionBody,
): Record<string, unknown> {
  const policy: ReasoningPolicy =
    body.reasoning_policy === 'off_if_supported'
      ? 'off_if_supported'
      : 'provider_default';
  return resolveReasoningControl({
    providerCode: provider.code,
    modelId: body.model,
    policy,
  });
}

function classifyReasoningControlFailure(
  error: SafeUpstreamException,
  reasoningControl: Record<string, unknown>,
): SafeUpstreamException {
  if (
    Object.keys(reasoningControl).length > 0 &&
    error.statusCode === 400 &&
    (error.safeCode === 'unknown_parameter' ||
      error.safeCode === 'unsupported_parameter')
  ) {
    return new SafeUpstreamException({
      statusCode: 400,
      safeCode: 'unsupported_reasoning_control',
      retryAfterSeconds: error.retryAfterSeconds,
    });
  }
  return error;
}

function safeCodeForDeadline(
  kind: StreamDeadlineKind,
): 'first_event_timeout' | 'idle_timeout' | 'total_timeout' {
  switch (kind) {
    case 'first_event':
      return 'first_event_timeout';
    case 'idle':
      return 'idle_timeout';
    case 'total':
      return 'total_timeout';
  }
}

function assertProviderAvailable(provider: AiProvider): void {
  if (!provider.apiKey || !provider.enabled) {
    throw new SafeUpstreamException({ safeCode: 'request_failed' });
  }
}

function safeRequestProfile(value: unknown): StreamRequestProfile {
  return value === 'translation' ? 'translation' : 'standard';
}

function inspectSseBlock(block: string): {
  done: boolean;
  usage?: UpstreamResponse['usage'];
} {
  const lines = block.split(/\r?\n/);
  const eventName = lines
    .find((line) => line.startsWith('event:'))
    ?.slice(6)
    .trim();
  const dataLines = lines
    .filter((line) => line.startsWith('data:'))
    .map((line) => {
      const data = line.slice(5);
      return data.startsWith(' ') ? data.slice(1) : data;
    });
  const data = dataLines.join('\n');

  if (data === '[DONE]') return { done: true };
  const payload = parseJsonObject(data);
  if (
    eventName === 'error' ||
    payload?.['error'] != null ||
    payload?.['code'] === 'upstream_error'
  ) {
    throw safeFailureFromSsePayload(payload);
  }
  const usage = asRecord(payload?.['usage']);
  return {
    done: false,
    ...(usage ? { usage: usage } : {}),
  };
}

function parseJsonObject(text: string): Record<string, unknown> | null {
  if (!text) return null;
  try {
    return asRecord(JSON.parse(text) as unknown);
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object'
    ? (value as Record<string, unknown>)
    : null;
}

function isResponseWritable(res: Response): boolean {
  return !res.destroyed && !res.writableEnded;
}
