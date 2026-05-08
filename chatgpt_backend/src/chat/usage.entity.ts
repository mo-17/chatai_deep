import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
} from 'typeorm';

@Entity()
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
