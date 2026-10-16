import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
  OneToMany,
  Index,
} from 'typeorm';
import { Message } from './message.entity';

@Entity('conversations')
@Index(['userId', 'updatedAt'])
export class Conversation {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  userId: number;

  @Column({ default: '' })
  title: string;

  @Column()
  model: string;

  // 旧会话不猜测所属服务商；删除服务商也保留历史选择。
  @Column({ type: 'varchar', nullable: true })
  providerCode: string | null;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;

  @OneToMany(() => Message, (m) => m.conversation, { cascade: true })
  messages: Message[];
}
