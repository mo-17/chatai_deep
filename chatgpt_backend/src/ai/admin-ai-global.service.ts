import { Injectable, BadRequestException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { AiGlobalConfig } from './ai-global-config.entity';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { resolveUploadsDir } from '../common/uploads-path';
import { ProviderCacheService } from './provider-cache.service';

@Injectable()
export class AdminAiGlobalService {
  constructor(
    @InjectRepository(AiGlobalConfig)
    private readonly repo: Repository<AiGlobalConfig>,
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    @InjectRepository(AiModel)
    private readonly modelRepo: Repository<AiModel>,
    private readonly providerCache: ProviderCacheService,
  ) {}

  async get() {
    let config = await this.repo.findOne({ where: { id: 1 } });
    if (!config) {
      config = await this.repo.save({
        id: 1,
        defaultProviderCode: 'deepseek',
        defaultModelId: 'deepseek-chat',
        catalogPublic: true,
      });
    }
    return config;
  }

  async update(body: Partial<AiGlobalConfig>) {
    const config = await this.repo.findOne({ where: { id: 1 } });
    // transform 后 DTO 可包含未提交的 undefined 字段，不能覆盖已有默认值。
    const updates = Object.fromEntries(
      Object.entries(body).filter(([, value]) => value !== undefined),
    );
    const candidate = this.repo.create({
      id: 1,
      defaultProviderCode: 'deepseek',
      defaultModelId: 'deepseek-chat',
      catalogPublic: true,
      ...config,
      ...updates,
    });

    // 仅改默认字段时校验最终组合，目录公开等无关修改不受旧失效默认阻断。
    if (
      body.defaultProviderCode !== undefined ||
      body.defaultModelId !== undefined
    ) {
      const code = candidate.defaultProviderCode;
      const modelId = candidate.defaultModelId;
      if (
        typeof code !== 'string' ||
        !code.trim() ||
        typeof modelId !== 'string' ||
        !modelId.trim()
      ) {
        throw new BadRequestException('默认服务商和模型不能为空');
      }
      const provider = await this.providerRepo.findOne({
        where: { code, enabled: true },
      });
      if (!provider) {
        throw new BadRequestException(`服务商 ${code} 不存在或已停用`);
      }
      const model = await this.modelRepo.findOne({
        where: { providerId: provider.id, modelId, enabled: true },
      });
      if (!model) {
        throw new BadRequestException(
          `服务商 ${code} 下的模型 ${modelId} 不存在或已停用`,
        );
      }
    }

    const saved = await this.repo.save(candidate);
    this.providerCache.invalidate();
    return saved;
  }

  async uploadAvatar(base64: string): Promise<{ avatarUrl: string }> {
    // 解析 base64: data:image/png;base64,xxxx 或纯 base64
    let data = base64;
    let ext = 'png';
    const mimeMatch = base64.match(/^data:(image\/\w+);base64,(.+)$/);
    if (mimeMatch) {
      const mime = mimeMatch[1];
      data = mimeMatch[2];
      if (mime === 'image/jpeg') ext = 'jpg';
      else if (mime === 'image/gif') ext = 'gif';
      else if (mime === 'image/webp') ext = 'webp';
    }

    const buffer = Buffer.from(data, 'base64');
    if (buffer.length > 2 * 1024 * 1024) {
      throw new BadRequestException('头像文件不能超过 2MB');
    }

    const dir = join(resolveUploadsDir(), 'avatars');
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });

    const filename = `avatar.${ext}`;
    writeFileSync(join(dir, filename), buffer);

    let config = await this.repo.findOne({ where: { id: 1 } });
    if (!config) {
      config = await this.repo.save({
        id: 1,
        defaultProviderCode: 'deepseek',
        defaultModelId: 'deepseek-chat',
        catalogPublic: true,
        avatarPath: filename,
      });
    } else {
      config.avatarPath = filename;
      await this.repo.save(config);
    }

    return { avatarUrl: `/uploads/avatars/${filename}` };
  }
}
