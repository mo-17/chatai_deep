import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { SyncController } from './sync.controller';
import { SyncChangeEntity } from './sync-change.entity';
import { SyncService } from './sync.service';

@Module({
  imports: [TypeOrmModule.forFeature([SyncChangeEntity])],
  controllers: [SyncController],
  providers: [SyncService],
  exports: [SyncService],
})
export class SyncModule {}
