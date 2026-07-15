import {
  Check,
  Column,
  Entity,
  PrimaryGeneratedColumn,
  Unique,
  UpdateDateColumn,
} from 'typeorm';
import type { SyncV2Operation } from './dto/sync-v2.dto';

@Entity({ name: 'sync_v2_heads', synchronize: false })
@Unique('UQ_sync_v2_heads_user_entity_sync', ['userId', 'entity', 'syncId'])
@Check('CHK_sync_v2_heads_revision', '"revision"::numeric >= 1')
@Check('CHK_sync_v2_heads_op', "\"op\" IN ('upsert', 'delete')")
export class SyncV2HeadEntity {
  @PrimaryGeneratedColumn({ type: 'bigint' })
  id: string;

  @Column({ name: 'user_id', type: 'int' })
  userId: number;

  @Column({ type: 'varchar', length: 64 })
  entity: string;

  @Column({ name: 'sync_id', type: 'uuid' })
  syncId: string;

  @Column({ name: 'change_id', type: 'uuid' })
  changeId: string;

  @Column({ type: 'bigint' })
  revision: string;

  @Column({ name: 'event_sequence', type: 'bigint' })
  eventSequence: string;

  @Column({ type: 'varchar', length: 8 })
  op: SyncV2Operation;

  @UpdateDateColumn({ name: 'updated_at', type: 'timestamptz' })
  updatedAt: Date;
}
