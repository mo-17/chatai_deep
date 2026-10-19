import {
  Column,
  CreateDateColumn,
  Entity,
  Index,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';
@Entity('user_feedback')
@Index(['userId', 'createdAt'])
@Index(['userId', 'requestId'], { unique: true })
export class UserFeedback {
  @PrimaryGeneratedColumn() id: number;
  @Column() userId: number;
  @Column('uuid') requestId: string;
  @Column({ type: 'varchar', length: 20 }) category: string;
  @Column({ type: 'text' }) content: string;
  @Column({ type: 'jsonb', default: {} }) diagnostics: Record<string, string>;
  @Column({ default: 'open' }) status: string;
  @Column({ type: 'text', default: '' }) reply: string;
  @CreateDateColumn() createdAt: Date;
  @UpdateDateColumn() updatedAt: Date;
}
