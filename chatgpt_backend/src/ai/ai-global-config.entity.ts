import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';

@Entity('ai_global_config')
export class AiGlobalConfig {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ default: 'deepseek' })
  defaultProviderCode: string;

  @Column({ default: 'deepseek-chat' })
  defaultModelId: string;

  @Column({ default: true })
  catalogPublic: boolean;

  @Column({ type: 'varchar', nullable: true })
  avatarPath: string | null;

  @UpdateDateColumn()
  updateTime: Date;
}
