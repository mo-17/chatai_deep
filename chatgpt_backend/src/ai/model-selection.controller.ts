import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { JwtGuard } from '../auth/jwt.guard';
import { ChatService } from '../chat/chat.service';
import { SafeUpstreamException } from '../chat/upstream-error';
import { AiGlobalConfig } from './ai-global-config.entity';
import { ModelSelectionDto } from './dto/model-selection.dto';

@Controller('uapi/ai')
@UseGuards(JwtGuard)
export class ModelSelectionController {
  constructor(
    private readonly chat: ChatService,
    @InjectRepository(AiGlobalConfig)
    private readonly globalRepo: Repository<AiGlobalConfig>,
  ) {}

  @Get('model-selection')
  async resolve(@Query() query: ModelSelectionDto) {
    const global = await this.globalRepo.findOne({ where: { id: 1 } });
    if (!global?.catalogPublic) {
      throw new SafeUpstreamException({
        statusCode: 403,
        safeCode: 'catalog_not_public',
      });
    }
    const provider = await this.chat.resolveProvider(
      query.modelId,
      query.providerCode,
    );
    // 只确认用户给出的选择，不列候选、不返回密钥，也不授予后续发送许可。
    return {
      code: 0,
      data: { providerCode: provider.code, modelId: query.modelId },
    };
  }
}
