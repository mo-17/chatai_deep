import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { SyncV2Controller } from './sync-v2.controller';
import { SyncV2AccessPolicy } from './sync-v2-access.policy';
import { SyncV2EventEntity } from './sync-v2-event.entity';
import { SyncV2HeadEntity } from './sync-v2-head.entity';
import { SyncV2ReceiptEntity } from './sync-v2-receipt.entity';
import { SyncV2Service } from './sync-v2.service';
import { SYNC_V2_STORE, TypeOrmSyncV2Store } from './sync-v2.store';

@Module({
  imports: [
    TypeOrmModule.forFeature([
      SyncV2EventEntity,
      SyncV2HeadEntity,
      SyncV2ReceiptEntity,
    ]),
  ],
  controllers: [SyncV2Controller],
  providers: [
    SyncV2AccessPolicy,
    SyncV2Service,
    { provide: SYNC_V2_STORE, useClass: TypeOrmSyncV2Store },
  ],
})
export class SyncV2Module {}
