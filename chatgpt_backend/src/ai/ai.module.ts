import { Module, forwardRef } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { AiProvider } from './ai-provider.entity';
import { AiModel } from './ai-model.entity';
import { AiGlobalConfig } from './ai-global-config.entity';
import { AiSeedService } from './ai-seed.service';
import { ProviderCacheService } from './provider-cache.service';
import { AdminAiProviderController } from './admin-ai-provider.controller';
import { AdminAiProviderService } from './admin-ai-provider.service';
import { AdminAiModelController } from './admin-ai-model.controller';
import { AdminAiModelService } from './admin-ai-model.service';
import { AdminAiGlobalController } from './admin-ai-global.controller';
import { AdminAiGlobalService } from './admin-ai-global.service';
import { ChatModule } from '../chat/chat.module';

import { PublicAiController } from './public-ai.controller';

@Module({
  imports: [
    TypeOrmModule.forFeature([AiProvider, AiModel, AiGlobalConfig]),
    forwardRef(() => ChatModule),
  ],
  controllers: [
    AdminAiProviderController,
    AdminAiModelController,
    AdminAiGlobalController,
    PublicAiController,
  ],
  providers: [
    AiSeedService,
    ProviderCacheService,
    AdminAiProviderService,
    AdminAiModelService,
    AdminAiGlobalService,
  ],
  exports: [
    ProviderCacheService,
    TypeOrmModule.forFeature([AiProvider, AiModel, AiGlobalConfig]),
  ],
})
export class AiModule {}
