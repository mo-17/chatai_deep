import {
  Injectable,
  NotFoundException,
  BadRequestException,
  ConflictException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, DataSource, Like } from 'typeorm';
import { AiModel } from './ai-model.entity';
import { AiProvider } from './ai-provider.entity';
import { ProviderCacheService } from './provider-cache.service';

@Injectable()
export class AdminAiModelService {
  constructor(
    @InjectRepository(AiModel)
    private readonly repo: Repository<AiModel>,
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    private readonly dataSource: DataSource,
    private readonly providerCache: ProviderCacheService,
  ) {}

  async list(query: {
    providerId?: string;
    enabled?: string;
    keyword?: string;
  }) {
    const where: Record<string, unknown> = {};
    if (query.providerId) where['providerId'] = parseInt(query.providerId, 10);
    if (query.enabled === 'true') where['enabled'] = true;
    else if (query.enabled === 'false') where['enabled'] = false;

    const list = await this.repo.find({
      where: query.keyword
        ? [
            { ...where, modelId: Like(`%${query.keyword}%`) },
            { ...where, displayName: Like(`%${query.keyword}%`) },
          ]
        : where,
      order: { sortOrder: 'DESC', id: 'ASC' },
    });

    // 补充 providerCode
    const providers = await this.providerRepo.find();
    const providerMap = new Map(providers.map((p) => [p.id, p.code]));
    const enriched = list.map((m) => ({
      ...m,
      providerCode: providerMap.get(m.providerId) || '',
    }));

    return { list: enriched };
  }

  async detail(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('模型不存在');
    const provider = await this.providerRepo.findOne({
      where: { id: entity.providerId },
    });
    return { ...entity, providerCode: provider?.code || '' };
  }

  async create(body: Partial<AiModel>) {
    return this.writeModel(body);
  }

  async edit(id: number, body: Partial<AiModel>) {
    return this.writeModel(body, id);
  }

  async delete(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('模型不存在');
    await this.repo.remove(entity);
    this.providerCache.invalidate();
    return null;
  }

  async setDefault(id: number) {
    return this.writeModel({ isDefault: true }, id);
  }

  private positiveId(id: unknown): asserts id is number {
    if (typeof id !== 'number' || !Number.isSafeInteger(id) || id <= 0) {
      throw new BadRequestException('服务商或模型 ID 必须为正整数');
    }
  }

  private async writeModel(body: Partial<AiModel>, id?: number) {
    const updates = { ...body };
    for (const key of Object.keys(updates) as Array<keyof AiModel>) {
      if (updates[key] === undefined) delete updates[key];
    }
    if (id !== undefined) this.positiveId(id);
    // 此快照只确定锁集合；候选字段必须在锁后基于最新模型合并。
    const snapshot =
      id === undefined ? null : await this.repo.findOne({ where: { id } });
    if (id !== undefined && !snapshot) {
      throw new NotFoundException('模型不存在');
    }
    const targetId =
      updates.providerId !== undefined
        ? updates.providerId
        : snapshot?.providerId;
    this.positiveId(targetId);
    if (snapshot) this.positiveId(snapshot.providerId);
    const providerIds = [
      ...new Set(snapshot ? [snapshot.providerId, targetId] : [targetId]),
    ].sort((a, b) => a - b);

    const result = await this.dataSource.transaction(async (manager) => {
      // 所有管理写先锁 provider，再锁/更新 model；跨服务商按同一升序。
      const providers = new Map<number, AiProvider>();
      for (const providerId of providerIds) {
        const provider = await manager.findOne(AiProvider, {
          where: { id: providerId },
          lock: { mode: 'pessimistic_write' },
        });
        if (!provider) throw new BadRequestException('服务商不存在');
        providers.set(providerId, provider);
      }
      let candidate: AiModel;
      if (snapshot) {
        const latest = await manager.findOne(AiModel, {
          where: { id },
          lock: { mode: 'pessimistic_write' },
        });
        if (!latest) throw new NotFoundException('模型不存在');
        if (latest.providerId !== snapshot.providerId) {
          throw new ConflictException('模型所属服务商已变化，请刷新后重试');
        }
        candidate = manager.create(AiModel, { ...latest, ...updates });
      } else {
        candidate = manager.create(AiModel, { isDefault: false, ...updates });
      }
      const provider = providers.get(targetId)!;
      if (candidate.isDefault === true) {
        await manager.update(
          AiModel,
          { providerId: targetId, isDefault: true },
          { isDefault: false },
        );
      }
      const saved = await manager.save(AiModel, candidate);
      return { ...saved, providerCode: provider.code };
    });
    this.providerCache.invalidate();
    return result;
  }
}
