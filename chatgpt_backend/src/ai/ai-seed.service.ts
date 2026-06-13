import { Injectable, OnApplicationBootstrap } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { AiGlobalConfig } from './ai-global-config.entity';

@Injectable()
export class AiSeedService implements OnApplicationBootstrap {
  constructor(
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    @InjectRepository(AiModel)
    private readonly modelRepo: Repository<AiModel>,
    @InjectRepository(AiGlobalConfig)
    private readonly globalRepo: Repository<AiGlobalConfig>,
  ) {}

  async onApplicationBootstrap() {
    await this.seedProviders();
    await this.seedModels();
    await this.seedGlobalConfig();
  }

  private async seedProviders() {
    const count = await this.providerRepo.count();
    if (count > 0) return;

    await this.providerRepo.save([
      {
        code: 'openai',
        displayName: 'OpenAI',
        apiKey: process.env.OPENAI_API_KEY ?? '',
        baseUrl: process.env.OPENAI_BASE_URL ?? 'https://api.openai.com/v1',
        modelPrefixes: 'gpt-,o1-,chatgpt-',
        enabled: true,
        sortOrder: 100,
      },
      {
        code: 'deepseek',
        displayName: 'DeepSeek',
        apiKey: process.env.DEEPSEEK_API_KEY ?? '',
        baseUrl: process.env.DEEPSEEK_BASE_URL ?? 'https://api.deepseek.com',
        modelPrefixes: 'deepseek-',
        enabled: true,
        sortOrder: 90,
      },
    ]);
  }

  private async seedModels() {
    const count = await this.modelRepo.count();
    if (count > 0) return;

    const openai = await this.providerRepo.findOne({
      where: { code: 'openai' },
    });
    const deepseek = await this.providerRepo.findOne({
      where: { code: 'deepseek' },
    });

    const models: Partial<AiModel>[] = [];

    if (openai) {
      const openaiModels: Partial<AiModel>[] = [
        {
          providerId: openai.id,
          modelId: 'gpt-3.5-turbo',
          displayName: 'GPT-3.5 Turbo',
          description: '便宜快，适合日常对话',
          enabled: true,
          isDefault: false,
          sortOrder: 10,
          supportsTool: true,
        },
        {
          providerId: openai.id,
          modelId: 'gpt-4o-mini',
          displayName: 'GPT-4o mini',
          description: '小模型，性价比高（推荐）',
          enabled: true,
          isDefault: true,
          sortOrder: 20,
          supportsVision: true,
          supportsTool: true,
          supportsPdf: true,
        },
        {
          providerId: openai.id,
          modelId: 'gpt-4o',
          displayName: 'GPT-4o',
          description: '主力模型，多模态',
          enabled: true,
          isDefault: false,
          sortOrder: 30,
          supportsVision: true,
          supportsTool: true,
          supportsPdf: true,
        },
        {
          providerId: openai.id,
          modelId: 'gpt-4-turbo',
          displayName: 'GPT-4 Turbo',
          description: '上一代旗舰',
          enabled: true,
          isDefault: false,
          sortOrder: 40,
          supportsVision: true,
          supportsTool: true,
        },
        {
          providerId: openai.id,
          modelId: 'o1-mini',
          displayName: 'o1-mini',
          description: '推理模型（小）',
          enabled: true,
          isDefault: false,
          sortOrder: 50,
          supportsReasoning: true,
        },
        {
          providerId: openai.id,
          modelId: 'o1',
          displayName: 'o1',
          description: '推理模型（强）',
          enabled: true,
          isDefault: false,
          sortOrder: 60,
          supportsVision: true,
          supportsTool: true,
          supportsReasoning: true,
        },
      ];
      models.push(...openaiModels);
    }

    if (deepseek) {
      const deepseekModels: Partial<AiModel>[] = [
        {
          providerId: deepseek.id,
          modelId: 'deepseek-chat',
          displayName: 'DeepSeek Chat',
          description: 'V3 对话模型（推荐）',
          enabled: true,
          isDefault: true,
          sortOrder: 10,
          supportsTool: true,
        },
        {
          providerId: deepseek.id,
          modelId: 'deepseek-reasoner',
          displayName: 'DeepSeek Reasoner',
          description: 'R1 推理模型，会输出思考过程',
          enabled: true,
          isDefault: false,
          sortOrder: 20,
          supportsReasoning: true,
        },
      ];
      models.push(...deepseekModels);
    }

    if (models.length > 0) {
      await this.modelRepo.save(models);
    }
  }

  private async seedGlobalConfig() {
    const count = await this.globalRepo.count();
    if (count > 0) return;

    await this.globalRepo.save({
      id: 1,
      defaultProviderCode: 'deepseek',
      defaultModelId: 'deepseek-chat',
      catalogPublic: true,
    });
  }
}
