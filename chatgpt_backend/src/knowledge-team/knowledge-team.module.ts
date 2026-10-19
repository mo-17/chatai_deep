import { Module } from '@nestjs/common';
import { KnowledgeTeamService } from './knowledge-team.service';
import { KnowledgeTeamController } from './knowledge-team.controller';
@Module({
  providers: [KnowledgeTeamService],
  controllers: [KnowledgeTeamController],
})
export class KnowledgeTeamModule {}
