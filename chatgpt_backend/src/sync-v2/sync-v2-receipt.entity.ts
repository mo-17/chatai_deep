import {
  Check,
  Column,
  CreateDateColumn,
  Entity,
  PrimaryGeneratedColumn,
  Unique,
} from 'typeorm';
import type { SyncV2Operation } from './dto/sync-v2.dto';

export type SyncV2ReceiptResult =
  | 'accepted'
  | 'conflict'
  | 'rejected'
  | 'blocked';
export type SyncV2ReceiptReason =
  | 'remote_ahead'
  | 'revision_gap'
  | 'blocked_by_ancestor';

@Entity({ name: 'sync_v2_receipts', synchronize: false })
@Unique('UQ_sync_v2_receipts_user_change', ['userId', 'changeId'])
@Check(
  'CHK_sync_v2_receipts_result',
  "\"result\" IN ('accepted', 'conflict', 'rejected', 'blocked')",
)
@Check(
  'CHK_sync_v2_receipts_reason',
  "\"reason\" IS NULL OR \"reason\" IN ('remote_ahead', 'revision_gap', 'blocked_by_ancestor')",
)
@Check(
  'CHK_sync_v2_receipts_links',
  '("result" = \'accepted\' AND "accepted_sequence" IS NOT NULL AND "remote_sequence" IS NULL AND "reason" IS NULL) OR ' +
    '("result" = \'conflict\' AND "accepted_sequence" IS NULL AND "remote_sequence" IS NOT NULL AND "reason" IS NOT NULL AND "reason" = \'remote_ahead\') OR ' +
    '("result" = \'rejected\' AND "accepted_sequence" IS NULL AND "reason" IS NOT NULL AND "reason" = \'revision_gap\') OR ' +
    '("result" = \'blocked\' AND "accepted_sequence" IS NULL AND "reason" IS NOT NULL AND "reason" = \'blocked_by_ancestor\')',
)
export class SyncV2ReceiptEntity {
  @PrimaryGeneratedColumn({ type: 'bigint' })
  id: string;

  @Column({ name: 'user_id', type: 'int' })
  userId: number;

  @Column({ name: 'change_id', type: 'uuid' })
  changeId: string;

  @Column({ name: 'request_hash', type: 'char', length: 64 })
  requestHash: string;

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

  @Column({ type: 'varchar', length: 16 })
  result: SyncV2ReceiptResult;

  @Column({ type: 'varchar', length: 32, nullable: true })
  reason: SyncV2ReceiptReason | null;

  @Column({ name: 'expected_revision', type: 'bigint' })
  expectedRevision: string;

  @Column({ name: 'accepted_sequence', type: 'bigint', nullable: true })
  acceptedSequence: string | null;

  @Column({ name: 'remote_sequence', type: 'bigint', nullable: true })
  remoteSequence: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt: Date;
}
