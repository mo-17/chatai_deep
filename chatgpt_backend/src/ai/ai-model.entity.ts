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

  @CreateDateColumn()
  createTime: Date;

  @UpdateDateColumn()
  updateTime: Date;
}
