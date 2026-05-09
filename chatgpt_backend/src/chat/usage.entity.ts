import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  Index,
} from 'typeorm';

@Entity()
@Index(['userId', 'createdAt'])
@Index(['provider', 'createdAt'])
@Index(['createdAt'])
export class Usage {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  userId: number;

  @Column()
  provider: string;

  @Column()
  model: string;

  @Column()
  promptTokens: number;

  @Column()
  completionTokens: number;

  @Column()
  totalTokens: number;

  @CreateDateColumn()
  createdAt: Date;
}
