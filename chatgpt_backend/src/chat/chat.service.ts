import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, type EntityManager } from 'typeorm';
import type { Response } from 'express';
import { Usage } from './usage.entity';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';
import type { UpdateConversationDto } from './dto/conversation-body.dto';
import {
  resolveReasoningControl,
  type ReasoningEffort,
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
  providerCode?: string;
  messages: Record<string, unknown>[];
  max_tokens?: number;
  temperature?: number;
  top_p?: number;
  // 工具调用声明（阶段六）：随 body 展开原样转发给上游。
  tools?: Record<string, unknown>[];
  request_profile?: StreamRequestProfile;
  reasoning_policy?: ReasoningPolicy;
  reasoning_effort?: ReasoningEffort;
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
      select: [
        'id',
        'title',
        'model',
        'providerCode',
        'updatedAt',
        'createdAt',
      ],
    });
  }

  async createConversation(
    userId: number,
    model: string,
    providerCode?: string,
  ) {
    if (typeof model !== 'string' || !/\S/.test(model)) {
      throw new BadRequestException('请求参数无效');
    }
    if (providerCode !== undefined) {
      await this.resolveProvider(model, providerCode);
    }
    const conv = this.convRepo.create({
      userId,
      model,
      providerCode: providerCode ?? null,
      title: '',
    });
    return this.convRepo.save(conv);
  }

  async updateConversation(
    userId: number,
    id: number,
    body: UpdateConversationDto,
  ) {
    const existing = await this.convRepo.findOne({
      where: { id, userId },
      select: ['id'],
    });
    if (!existing) throw new NotFoundException('会话不存在');
    const changes: Partial<Conversation> = {};
    if (body.title !== undefined) changes.title = body.title;
    if (body.model !== undefined || body.providerCode !== undefined) {
      if (
        typeof body.model !== 'string' ||
        !/\S/.test(body.model) ||
        typeof body.providerCode !== 'string' ||
        !/\S/.test(body.providerCode)
      ) {
        throw new BadRequestException('请求参数无效');
      }
      await this.resolveProvider(body.model, body.providerCode);
      changes.model = body.model;
      changes.providerCode = body.providerCode;
    }
    if (Object.keys(changes).length === 0) return;
    const result = await this.convRepo.update({ id, userId }, changes);
    if (result.affected !== 1) throw new NotFoundException('会话不存在');
  }

  private withOwnedConversation<T>(
    userId: number,
    id: number,
    lock: 'pessimistic_read' | 'pessimistic_write',
    action: (manager: EntityManager, conversation: Conversation) => Promise<T>,
  ): Promise<T> {
    if (!Number.isSafeInteger(id) || id <= 0) {
      throw new BadRequestException('请求参数无效');
    }
    return this.convRepo.manager.transaction(async (manager) => {
      // 不先查子表；原私有owner合同固定在同一parent锁与短事务。
      const parent = await manager.findOne(Conversation, {
        where: { id, userId },
        select: ['id'],
        lock: { mode: lock },
      });
      if (!parent) throw new NotFoundException('会话不存在或不可访问');
      return action(manager, parent);
    });
  }

  async deleteConversation(userId: number, id: number) {
    return this.withOwnedConversation(
      userId,
      id,
      'pessimistic_write',
      async (manager) => {
        // 原FK的CASCADE与条件parent删除同事务；失败不能先删别人的子行。
        const result = await manager.delete(Conversation, { id, userId });
        if (result.affected !== 1)
          throw new NotFoundException('会话不存在或不可访问');
      },
    );
  }

  // --- Message CRUD ---

  async listMessages(userId: number, conversationId: number) {
    return this.withOwnedConversation(
      userId,
      conversationId,
      'pessimistic_read',
      (manager, parent) =>
        manager.find(Message, {
          where: { conversationId: parent.id },
          order: { id: 'ASC' },
          select: ['role', 'content'],
        }),
    );
  }

  async saveMessages(
    userId: number,
    conversationId: number,
    msgs: { role: 'user' | 'assistant'; content: string }[],
  ) {
    return this.withOwnedConversation(
      userId,
      conversationId,
      'pessimistic_write',
      async (manager, parent) => {
        const entities = msgs.map((m) =>
          manager.create(Message, {
            conversationId: parent.id,
            role: m.role,
            content: m.content,
          }),
        );
        return manager.save(Message, entities);
      },
    );
  }

  // --- Non-streaming completion ---

  async complete(userId: number, body: CompletionBody) {
    const provider = await this.resolveProvider(body.model, body.providerCode);
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
    const preparedBody = prepareUpstreamRequest(body, provider);
    const reasoningControl = requestReasoningControl(provider, preparedBody);
    const upstreamBody = buildUpstreamBody(preparedBody, reasoningControl);
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
    const provider = await this.resolveProvider(body.model, body.providerCode);
    assertProviderAvailable(provider);
    if (clientSignal.aborted) return;

    const url = `${provider.baseUrl}/chat/completions`;
    const requestProfile = safeRequestProfile(body.request_profile);
    const preparedBody = prepareUpstreamRequest(body, provider);
    const reasoningControl = requestReasoningControl(provider, preparedBody);
    const streamBody = {
      ...buildUpstreamBody(preparedBody, reasoningControl),
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

  /** 每次发送/解析均以当前数据库为准；旧 model-only 缓存不证明归属或可用性。 */
  async resolveProvider(
    model: string,
    providerCode?: string,
  ): Promise<AiProvider> {
    if (
      typeof model !== 'string' ||
      !/\S/.test(model) ||
      (providerCode !== undefined &&
        (typeof providerCode !== 'string' || !/\S/.test(providerCode)))
    ) {
      throw new SafeUpstreamException({
        statusCode: 400,
        safeCode: 'invalid_request',
      });
    }

    // 两次 SELECT 必须读取同一快照，避免拼接从未同时有效的配置。
    // 无网络操作留在事务内；提交与释放失败均向上传递，不能带旧对象发出请求。
    return this.modelRepo.manager.transaction(
      'REPEATABLE READ',
      async (manager) => {
        const providerRepo = manager.getRepository(AiProvider);
        const modelRepo = manager.getRepository(AiModel);
        if (providerCode !== undefined) {
          const provider = await providerRepo.findOne({
            where: { code: providerCode },
          });
          if (!providerUsable(provider)) {
            throw new SafeUpstreamException({
              statusCode: 409,
              safeCode: 'provider_unavailable',
            });
          }
          const row = await modelRepo.findOne({
            where: { providerId: provider.id, modelId: model },
          });
          if (!row || !row.enabled) {
            throw new SafeUpstreamException({
              statusCode: 409,
              safeCode: 'model_unavailable',
            });
          }
          return provider;
        }

        // legacy 必须统计全部同名行，停用/孤立行仍可能是原用户选择。
        const rows = await modelRepo.find({ where: { modelId: model } });
        if (rows.length > 1) {
          throw new SafeUpstreamException({
            statusCode: 409,
            safeCode: 'model_ambiguous',
          });
        }
        const row = rows[0];
        const provider = row?.enabled
          ? await providerRepo.findOne({ where: { id: row.providerId } })
          : null;
        if (!providerUsable(provider)) {
          throw new SafeUpstreamException({
            statusCode: 409,
            safeCode: 'model_unavailable',
          });
        }
        return provider;
      },
    );
  }
}

function providerUsable(provider: AiProvider | null): provider is AiProvider {
  return (
    !!provider?.enabled &&
    typeof provider.apiKey === 'string' &&
    provider.apiKey.trim().length > 0
  );
}

function prepareUpstreamRequest(
  body: CompletionBody,
  provider: AiProvider,
): CompletionBody {
  const selectedControl = resolveReasoningControl({
    providerCode: provider.code,
    modelId: body.model,
    policy:
      body.reasoning_policy === 'off_if_supported'
        ? 'off_if_supported'
        : 'provider_default',
    effort: body.reasoning_effort,
  });
  const selectedEffort = selectedControl.reasoning_effort;
  const fillOrdinaryReasoning =
    selectedEffort === 'low' ||
    selectedEffort === 'high' ||
    selectedEffort === 'max';
  return {
    ...body,
    messages: body.messages.map((message) => {
      const copy = { ...message };
      // 根据实际路由后的服务商过滤，而不是相信客户端的模型前缀。
      // 不修改输入 body，保留客户端用于恢复和换回 DeepSeek 的原始协议记录。
      if (
        !supportsThinkingReplay(provider, body.model) ||
        copy.role !== 'assistant' ||
        typeof copy.reasoning_content !== 'string'
      ) {
        delete copy.reasoning_content;
      }
      // 显式由 off 切回思考时，普通回复确实没有思考内容，可在请求副本中补空。
      // 工具调用回复不能补造字段，仍由下方兼容检查安全关闭思考。
      if (
        fillOrdinaryReasoning &&
        copy.role === 'assistant' &&
        !hasToolCalls(copy) &&
        typeof copy.reasoning_content !== 'string'
      ) {
        copy.reasoning_content = '';
      }
      return copy;
    }),
  };
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

function hasToolCalls(message: Record<string, unknown>): boolean {
  return Array.isArray(message.tool_calls) && message.tool_calls.length > 0;
}

function requestReasoningControl(
  provider: AiProvider,
  body: CompletionBody,
): Record<string, unknown> {
  // 思考工具协议需要所有历史 assistant 的 reasoning_content。完整的新历史
  // 使用选定的等级或上游默认；旧历史缺字段时保留非思考兼容路径（含工具收尾轮）。
  const hasToolHistory = body.messages.some(
    (message) => message.role === 'assistant' && hasToolCalls(message),
  );
  const missingReasoning = body.messages.some(
    (message) =>
      message.role === 'assistant' &&
      typeof message.reasoning_content !== 'string',
  );
  if (
    supportsThinkingReplay(provider, body.model) &&
    ((body.tools?.length ?? 0) > 0 || hasToolHistory) &&
    missingReasoning
  ) {
    return { thinking: { type: 'disabled' } };
  }
  const policy: ReasoningPolicy =
    body.reasoning_policy === 'off_if_supported'
      ? 'off_if_supported'
      : 'provider_default';
  return resolveReasoningControl({
    providerCode: provider.code,
    modelId: body.model,
    policy,
    effort: body.reasoning_effort,
  });
}

function supportsThinkingReplay(provider: AiProvider, model: string): boolean {
  return (
    provider.code === 'deepseek' &&
    [
      'deepseek-flash',
      'deepseek-v4-flash',
      'deepseek-v4-flash-vision-exp',
      'deepseek-v4-pro',
    ].includes(model.trim().toLowerCase())
  );
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
