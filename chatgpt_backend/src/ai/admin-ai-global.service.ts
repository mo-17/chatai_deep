import { Injectable, BadRequestException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';
import { AiGlobalConfig } from './ai-global-config.entity';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';

@Injectable()
export class AdminAiGlobalService {
  constructor(
    @InjectRepository(AiGlobalConfig)
    private readonly repo: Repository<AiGlobalConfig>,
    @InjectRepository(AiProvider)
    private readonly providerRepo: Repository<AiProvider>,
    @InjectRepository(AiModel)
    private readonly modelRepo: Repository<AiModel>,
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
    let config = await this.repo.findOne({ where: { id: 1 } });
    if (!config) {
      config = await this.repo.save({
        id: 1,
        defaultProviderCode: 'deepseek',
        defaultModelId: 'deepseek-chat',
        catalogPublic: true,
      });
    }

    if (body.defaultProviderCode) {
      const provider = await this.providerRepo.findOne({
        where: { code: body.defaultProviderCode, enabled: true },
      });
      if (!provider) {
        throw new BadRequestException(
          `服务商 ${body.defaultProviderCode} 不存在或已停用`,
        );
      }
    }

    if (body.defaultModelId) {
      const code = body.defaultProviderCode || config.defaultProviderCode;
      const model = await this.modelRepo.findOne({
        where: { modelId: body.defaultModelId, enabled: true },
      });
      if (!model) {
        throw new BadRequestException(
          `模型 ${body.defaultModelId} 不存在或已停用`,
        );
      }
      // 验证该模型所属的 provider 匹配
      const provider = await this.providerRepo.findOne({
        where: { id: model.providerId },
      });
      if (provider && provider.code !== code) {
        throw new BadRequestException(
          `模型 ${body.defaultModelId} 不属于服务商 ${code}`,
        );
      }
    }

    Object.assign(config, body);
    return this.repo.save(config);
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

    const dir = join(process.cwd(), 'uploads', 'avatars');
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
