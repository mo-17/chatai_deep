import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';

@Entity('ai_providers')
export class AiProvider {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  code: string;

  @Column()
  displayName: string;

  @Column()
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
