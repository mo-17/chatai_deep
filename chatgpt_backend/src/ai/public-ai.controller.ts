import { Controller, Get, UseGuards, ForbiddenException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { JwtGuard } from '../auth/jwt.guard';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { AiGlobalConfig } from './ai-global-config.entity';

@Controller('uapi/ai')
@UseGuards(JwtGuard)
export class PublicAiController {
  constructor(
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    @InjectRepository(AiModel)
    private readonly modelRepo: Repository<AiModel>,
    @InjectRepository(AiGlobalConfig)
    private readonly globalRepo: Repository<AiGlobalConfig>,
  ) {}

  @Get('catalog')
  async catalog() {
    const global = await this.globalRepo.findOne({ where: { id: 1 } });
    if (!global || !global.catalogPublic) {
      throw new ForbiddenException('模型清单暂不对外开放');
    }

    const providers = await this.providerRepo.find({
      where: { enabled: true },
      select: ['id', 'code', 'displayName'],
    });

    const models = await this.modelRepo.find({ where: { enabled: true } });
    const providerMap = new Map(providers.map((p) => [p.id, p.code]));

    const modelList = models
      .filter((m) => providerMap.has(m.providerId))
      .map((m) => ({
        modelId: m.modelId,
        displayName: m.displayName,
        description: m.description,
        providerCode: providerMap.get(m.providerId) || '',
        isDefault: m.isDefault,
        sortOrder: m.sortOrder,
        // 能力位：客户端在家族启发式之上做加法覆盖（见 ModelCatalog.capabilitiesFor）。
        supportsVision: m.supportsVision,
        supportsTool: m.supportsTool,
        supportsReasoning: m.supportsReasoning,
        supportsPdf: m.supportsPdf,
      }));

    return {
      code: 0,
      data: {
        providers: providers.map(({ code, displayName }) => ({
          code,
          displayName,
        })),
        models: modelList,
        default: {
          providerCode: global.defaultProviderCode,
          modelId: global.defaultModelId,
        },
        avatarUrl: global.avatarPath
          ? `/uploads/avatars/${global.avatarPath}`
          : null,
      },
    };
  }
}
