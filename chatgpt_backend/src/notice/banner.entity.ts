import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
  Index,
} from 'typeorm';

@Entity('banners')
@Index(['enabled', 'sticky', 'createTime'])
export class Banner {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  title: string;

  @Column({ nullable: true })
  subtitle: string;

  @Column({ nullable: true })
  cover: string;

  @Column({ nullable: true })
  url: string;

  @Column({ default: 0 })
  sticky: number;

  @Column({ default: true })
  enabled: boolean;

  @Column({ default: 'banner' })
  type: string;

  @CreateDateColumn()
  createTime: Date;

  @UpdateDateColumn()
  updateTime: Date;
}
