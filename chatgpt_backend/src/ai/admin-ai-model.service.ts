import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository, DataSource, Like } from 'typeorm';
import { AiModel } from './ai-model.entity';
import { AiProvider } from './ai-provider.entity';

@Injectable()
export class AdminAiModelService {
  constructor(
    @InjectRepository(AiModel)
    private readonly repo: Repository<AiModel>,
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    private readonly dataSource: DataSource,
  ) {}

  async list(query: {
    providerId?: string;
    enabled?: string;
    keyword?: string;
  }) {
    const where: any = {};
    if (query.providerId) where.providerId = parseInt(query.providerId, 10);
    if (query.enabled === 'true') where.enabled = true;
    else if (query.enabled === 'false') where.enabled = false;

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
    const entity = this.repo.create(body);
    const saved = await this.repo.save(entity);
    const provider = await this.providerRepo.findOne({
      where: { id: saved.providerId },
    });
    return { ...saved, providerCode: provider?.code || '' };
  }

  async edit(id: number, body: Partial<AiModel>) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('模型不存在');
    Object.assign(entity, body);
    const saved = await this.repo.save(entity);
    const provider = await this.providerRepo.findOne({
      where: { id: saved.providerId },
    });
    return { ...saved, providerCode: provider?.code || '' };
  }

  async delete(id: number) {
    const entity = await this.repo.findOne({ where: { id } });
    if (!entity) throw new NotFoundException('模型不存在');
    await this.repo.remove(entity);
    return null;
  }

  async setDefault(id: number) {
    const model = await this.repo.findOne({ where: { id } });
    if (!model) throw new NotFoundException('模型不存在');

    await this.dataSource.transaction(async (manager) => {
      await manager.update(
        AiModel,
        { providerId: model.providerId },
        { isDefault: false },
      );
      await manager.update(AiModel, { id }, { isDefault: true });
    });

    return this.detail(id);
  }
}
