import {
  Injectable,
  NotFoundException,
  BadRequestException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, DataSource } from 'typeorm';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { ChatService } from '../chat/chat.service';
import { ProviderCacheService } from './provider-cache.service';
import { SafeUpstreamException } from '../chat/upstream-error';

@Injectable()
export class AdminAiProviderService {
  constructor(
    @InjectRepository(AiProvider)
    private readonly repo: Repository<AiProvider>,
    @InjectRepository(AiModel)
    private readonly modelRepo: Repository<AiModel>,
    private readonly dataSource: DataSource,
    private readonly chatService: ChatService,
    private readonly providerCache: ProviderCacheService,
  ) {}

  async list() {
    const list = await this.repo.find({
      order: { sortOrder: 'DESC', id: 'ASC' },
    });
    return {
      list: list.map((p) => ({ ...p, apiKey: this.maskKey(p.apiKey) })),
    };
  }

  async detail(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('服务商不存在');
    return { ...entity, apiKey: this.maskKey(entity.apiKey) };
  }

  async create(body: Partial<AiProvider>) {
    const entity = this.repo.create(body);
    const saved = await this.repo.save(entity);
    this.providerCache.invalidate();
    return { ...saved, apiKey: this.maskKey(saved.apiKey) };
  }

  async edit(id: number, body: Partial<AiProvider> & { apiKey?: string }) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('服务商不存在');
    // apiKey 为空或未传 → 保留原值
    if (body.apiKey === '' || body.apiKey === undefined) {
      delete body.apiKey;
    }
    Object.assign(entity, body);
    const saved = await this.repo.save(entity);
    this.providerCache.invalidate();
    return { ...saved, apiKey: this.maskKey(saved.apiKey) };
  }

  async delete(id: number) {
    await this.dataSource.transaction(async (manager) => {
      const provider = await manager.findOne(AiProvider, {
        where: { id },
        lock: { mode: 'pessimistic_write' },
      });
      if (!provider) throw new NotFoundException('服务商不存在');
      const modelCount = await manager.count(AiModel, {
        where: { providerId: id },
      });
      await manager.delete(AiModel, { providerId: id });
      await manager.remove(provider);
      if (modelCount > 0) {
        console.warn(
          `已删除服务商 ${provider.code} 及其 ${modelCount} 个模型。全局默认 provider 可能已不可用，请到全局配置页修改。`,
        );
      }
    });
    this.providerCache.invalidate();
    return null;
  }

  async testConnection(id: number) {
    // 默认数量、归属与 provider 可用性来自同一快照；网络请求在事务完成后。
    const { provider, model } = await this.dataSource.transaction(
      'REPEATABLE READ',
      async (manager) => {
        const provider = await manager
          .getRepository(AiProvider)
          .findOne({ where: { id } });
        if (!provider) throw new NotFoundException('服务商不存在');
        const defaults = await manager.getRepository(AiModel).find({
          where: { providerId: id, isDefault: true },
        });
        if (
          defaults.length !== 1 ||
          !defaults[0].enabled ||
          typeof defaults[0].modelId !== 'string' ||
          !/\S/.test(defaults[0].modelId)
        ) {
          throw new BadRequestException(
            '该服务商默认模型无效，请明确设置一个可用默认模型',
          );
        }
        if (!provider.enabled || !provider.apiKey?.trim()) {
          throw new SafeUpstreamException({
            statusCode: 409,
            safeCode: 'provider_unavailable',
          });
        }
        return { provider, model: defaults[0].modelId };
      },
    );

    const start = Date.now();
    try {
      const data = await this.chatService.callUpstream(provider, {
        model,
        messages: [{ role: 'user', content: 'ping' }],
        max_tokens: 8,
      });
      const sample = data.choices?.[0]?.message?.content?.slice(0, 50) || '';
      return { ok: true, latencyMs: Date.now() - start, sample };
    } catch (err: unknown) {
      return { ok: false, error: (err as Error).message || '未知错误' };
    }
  }

  private maskKey(k: string) {
    if (!k || k.length <= 8) return '****';
    return k.slice(0, 4) + '****' + k.slice(-4);
  }
}
