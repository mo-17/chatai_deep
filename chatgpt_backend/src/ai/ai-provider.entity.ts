import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';
import { Exclude } from 'class-transformer';

@Entity('ai_providers')
export class AiProvider {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  code: string;

  @Column()
  displayName: string;

  @Column()
  @Exclude({ toPlainOnly: true })
  apiKey: string;

  @Column()
  baseUrl: string;

  @Column({ type: 'text', nullable: true })
  modelPrefixes: string;

  @Column({ default: true })
  enabled: boolean;

  @Column({ default: 0 })
  sortOrder: number;

  @CreateDateColumn()
  createTime: Date;

  @UpdateDateColumn()
  updateTime: Date;
}
