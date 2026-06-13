import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
  Index,
} from 'typeorm';

@Entity('ai_models')
@Index('idx_provider_model', ['providerId', 'modelId'], { unique: true })
export class AiModel {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  providerId: number;

  @Column()
  modelId: string;

  @Column()
  displayName: string;

  @Column({ type: 'text', nullable: true })
  description: string;

  @Column({ default: true })
  enabled: boolean;

  @Column({ default: false })
  isDefault: boolean;

  @Column({ default: 0 })
  sortOrder: number;

  @Column({ type: 'decimal', precision: 10, scale: 6, nullable: true })
  inputPrice: number;

  @Column({ type: 'decimal', precision: 10, scale: 6, nullable: true })
  outputPrice: number;

  // 能力位：显式下发给客户端做能力探测（catalog）。默认 false（synchronize 自动加列）。
  // 语义为「加法覆盖」——客户端在 modelId 家族启发式之上把这些位强制打开，
  // 故迁移后存量模型即使全为 false 也不会丢失启发式已识别的能力。
  @Column({ default: false })
  supportsVision: boolean;

  @Column({ default: false })
  supportsTool: boolean;

  @Column({ default: false })
  supportsReasoning: boolean;

  @Column({ default: false })
  supportsPdf: boolean;

  @CreateDateColumn()
  createTime: Date;

  @UpdateDateColumn()
  updateTime: Date;
}
