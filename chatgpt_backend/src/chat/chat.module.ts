import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ChatController } from './chat.controller';
import { ChatService } from './chat.service';
import { Usage } from './usage.entity';
import { Conversation } from './conversation.entity';
import { Message } from './message.entity';
import { AiProvider } from '../ai/ai-provider.entity';
import { AiModel } from '../ai/ai-model.entity';
import { AiGlobalConfig } from '../ai/ai-global-config.entity';

@Module({
  imports: [
    TypeOrmModule.forFeature([
      Usage,
      Conversation,
      Message,
      AiProvider,
      AiModel,
      AiGlobalConfig,
    ]),
  ],
  controllers: [ChatController],
  providers: [ChatService],
  exports: [ChatService],
})
export class ChatModule {}
