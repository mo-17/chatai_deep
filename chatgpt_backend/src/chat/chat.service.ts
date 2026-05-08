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

export interface CompletionBody {
  model: string;
  messages: Record<string, unknown>[];
  max_tokens?: number;
}

export interface UpstreamResponse {
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
  error?: { message?: string };
  [key: string]: unknown;
}

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

  // --- Existing methods ---

  async complete(userId: number, body: CompletionBody) {
    const provider = await this.resolveProvider(body.model);
    const data = await this.callUpstream(provider, body);

    if (data.usage) {
      await this.usageRepo.save({
        userId,
        provider: provider.code,
        model: body.model,
        promptTokens: data.usage.prompt_tokens || 0,
        completionTokens: data.usage.completion_tokens || 0,
        totalTokens: data.usage.total_tokens || 0,
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
        data?.error?.message || `上游 ${provider.code} 返回错误 ${resp.status}`,
      );
    }

    return data;
  }

  /// SSE 流式透传：将上游 SSE 转发给客户端，末尾落库 usage
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
    const upstreamResp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${provider.apiKey}`,
      },
      body: JSON.stringify(streamBody),
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
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
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
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const rawLine of lines) {
          const line = rawLine.trimEnd(); // 去除 \r (DeepSeek 等 API 使用 \r\n 行尾)
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
          res.write(line + '\n');
        }
      }
      // 处理 buffer 中的残余行
      if (buffer.startsWith('data: ') && buffer !== 'data: [DONE]') {
        try {
          const data = buffer.slice(6).trimEnd();
          const json = JSON.parse(data) as UpstreamResponse;
          if (json.usage) {
            lastUsage = json.usage;
          }
        } catch {
          // 忽略无法解析的残余行
        }
      }
    } finally {
      reader.releaseLock();
    }

    res.write('data: [DONE]\n\n');
    res.end();

    // 落库 usage
    if (lastUsage) {
      await this.usageRepo.save({
        userId,
        provider: provider.code,
        model: body.model,
        promptTokens: lastUsage.prompt_tokens || 0,
        completionTokens: lastUsage.completion_tokens || 0,
        totalTokens: lastUsage.total_tokens || 0,
      });
    }
  }

  async resolveProvider(model: string): Promise<AiProvider> {
    // 1. 精确匹配 ai_models 表
    const modelRow = await this.modelRepo.findOne({
      where: { modelId: model, enabled: true },
    });
    if (modelRow) {
      const provider = await this.providerRepo.findOne({
        where: { id: modelRow.providerId },
      });
      if (provider) return provider;
    }

    // 2. 按 modelPrefixes 前缀匹配
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
          if (model.startsWith(prefix)) return p;
        }
      }
    }

    // 3. 兜底：全局默认 provider
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
    return fallback;
  }
}
