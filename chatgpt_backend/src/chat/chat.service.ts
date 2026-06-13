import { Injectable, BadGatewayException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Response } from 'express';
import { Usage } from './usage.entity';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';
import { ProviderCacheService } from '../ai/provider-cache.service';

export interface CompletionBody {
  model: string;
  messages: Record<string, unknown>[];
  max_tokens?: number;
  // 工具调用声明（阶段六）：随 body 展开原样转发给上游。
  tools?: Record<string, unknown>[];
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
  error?: { message?: string };
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
    if (!provider.apiKey) {
      throw new BadGatewayException(
        `服务商 ${provider.code} 未配置 API Key，请联系管理员`,
      );
    }
    if (!provider.enabled) {
      throw new BadGatewayException(`服务商 ${provider.displayName} 已停用`);
    }

    const url = `${provider.baseUrl}/chat/completions`;
    const t0 = Date.now();
    try {
      const resp = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${provider.apiKey}`,
        },
        body: JSON.stringify(body),
      });

      const data: UpstreamResponse = (await resp.json()) as UpstreamResponse;

      if (!resp.ok) {
        throw new BadGatewayException(
          data?.error?.message ||
            `上游 ${provider.code} 返回错误 ${resp.status}`,
        );
      }

      console.log(
        `[upstream] ${provider.code}/${body.model} ${Date.now() - t0}ms tokens=${data.usage?.total_tokens ?? '?'}`,
      );
      return data;
    } catch (e) {
      if (e instanceof BadGatewayException) throw e;

      console.warn(
        `[upstream] ${provider.code}/${body.model} ${Date.now() - t0}ms FAIL: ${(e as Error).message}`,
      );
      throw e;
    }
  }

  // --- SSE streaming completion ---

  async completeStream(userId: number, body: CompletionBody, res: Response) {
    const provider = await this.resolveProvider(body.model);

    if (!provider.apiKey) {
      throw new BadGatewayException(
        `服务商 ${provider.code} 未配置 API Key，请联系管理员`,
      );
    }
    if (!provider.enabled) {
      throw new BadGatewayException(`服务商 ${provider.displayName} 已停用`);
    }

    const url = `${provider.baseUrl}/chat/completions`;
    const streamBody = {
      ...body,
      stream: true,
      stream_options: { include_usage: true },
    };

    const controller = new AbortController();
    res.on('close', () => controller.abort());

    const upstreamResp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${provider.apiKey}`,
      },
      body: JSON.stringify(streamBody),
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(60_000)]),
    });

    if (!upstreamResp.ok) {
      const text = await upstreamResp.text();
      let errMsg = `上游 ${provider.code} 返回错误 ${upstreamResp.status}`;
      try {
        const errData = JSON.parse(text) as UpstreamResponse;
        if (errData?.error?.message) errMsg = errData.error.message;
      } catch {
        // JSON 解析失败，使用默认错误消息
      }
      throw new BadGatewayException(errMsg);
    }

    res.status(200);
    res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders();

    const reader = upstreamResp.body!.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let lastUsage: UpstreamResponse['usage'] = undefined;

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        let idx: number;
        while ((idx = buffer.search(SSE_SEP)) !== -1) {
          const block = buffer.slice(0, idx);
          buffer = buffer.slice(idx + (buffer[idx] === '\r' ? 4 : 2));

          // Parse SSE block for usage info
          const lines = block.split(/\r?\n/);
          for (const rawLine of lines) {
            const line = rawLine.trimEnd();
            if (line.startsWith('data: ')) {
              const data = line.slice(6);
              if (data === '[DONE]') continue;
              try {
                const json = JSON.parse(data) as UpstreamResponse;
                if (json.usage) {
                  lastUsage = json.usage;
                }
              } catch {
                // 忽略无法解析的 SSE 行
              }
            }
          }

          res.write(block + '\n\n');
        }
      }

      // 处理 buffer 中的残余块
      if (buffer.trim()) {
        const lines = buffer.split(/\r?\n/);
        for (const rawLine of lines) {
          const line = rawLine.trimEnd();
          if (line.startsWith('data: ') && line.slice(6) !== '[DONE]') {
            try {
              const json = JSON.parse(line.slice(6)) as UpstreamResponse;
              if (json.usage) lastUsage = json.usage;
            } catch {
              // 忽略
            }
          }
        }
        res.write(buffer);
      }
    } catch (err) {
      if ((err as Error).name === 'AbortError') {
        // Client disconnected — normal, just exit
      } else {
        throw err;
      }
    } finally {
      reader.releaseLock();
    }

    res.write('data: [DONE]\n\n');
    res.end();

    // Fire-and-forget usage save
    if (lastUsage) {
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
