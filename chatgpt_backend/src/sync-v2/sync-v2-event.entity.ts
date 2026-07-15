import {
  Check,
  Column,
  CreateDateColumn,
  Entity,
  PrimaryGeneratedColumn,
  Unique,
} from 'typeorm';
import type { SyncV2Operation } from './dto/sync-v2.dto';

@Entity({ name: 'sync_v2_events', synchronize: false })
@Unique('UQ_sync_v2_events_user_change', ['userId', 'changeId'])
@Unique('UQ_sync_v2_events_user_sequence', ['userId', 'sequence'])
@Unique('UQ_sync_v2_events_user_entity_revision', [
  'userId',
  'entity',
  'syncId',
  'revision',
])
@Check('CHK_sync_v2_events_revision', '"revision"::numeric >= 1')
@Check('CHK_sync_v2_events_op', "\"op\" IN ('upsert', 'delete')")
@Check(
  'CHK_sync_v2_events_payload',
  '("op" = \'delete\' AND "payload" IS NULL) OR ' +
    '("op" = \'upsert\' AND "payload" IS NOT NULL AND jsonb_typeof("payload") = \'object\')',
)
export class SyncV2EventEntity {
  @PrimaryGeneratedColumn({ type: 'bigint' })
  sequence: string;

  @Column({ name: 'user_id', type: 'int' })
  userId: number;

  @Column({ name: 'change_id', type: 'uuid' })
  changeId: string;

  @Column({ type: 'varchar', length: 64 })
  entity: string;

  @Column({ name: 'sync_id', type: 'uuid' })
  syncId: string;

  @Column({ name: 'parent_change_id', type: 'uuid', nullable: true })
  parentChangeId: string | null;

  @Column({ type: 'bigint' })
  revision: string;

  @Column({ type: 'varchar', length: 8 })
  op: SyncV2Operation;

  @Column({ type: 'jsonb', nullable: true })
  payload: Record<string, unknown> | null;

  @Column({ name: 'device_id', type: 'uuid' })
  deviceId: string;

  @CreateDateColumn({ name: 'server_created_at', type: 'timestamptz' })
  serverCreatedAt: Date;
}
