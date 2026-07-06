import {
  Column,
  CreateDateColumn,
  Entity,
  Index,
  PrimaryGeneratedColumn,
} from 'typeorm';

export type SyncOperation = 'upsert' | 'delete';

@Entity('sync_changes')
@Index(['userId', 'id'])
@Index(['userId', 'entity', 'entityId', 'id'])
export class SyncChangeEntity {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  userId: number;

  @Column()
  entity: string;

  @Column()
  entityId: string;

  @Column({ default: 'upsert' })
  op: SyncOperation;

  /// 客户端本地更新时间（毫秒时间戳），用于 LWW 与等时冲突判断。
  @Column({ type: 'bigint' })
  updatedAt: string;

  @Column({ type: 'jsonb', nullable: true })
  payload: Record<string, unknown> | null;

  @Column({ type: 'varchar', nullable: true })
  deviceId: string | null;

  @CreateDateColumn()
  createdAt: Date;
}
