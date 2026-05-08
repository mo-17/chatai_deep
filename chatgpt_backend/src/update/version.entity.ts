import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';

@Entity('app_versions')
export class AppVersion {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  versionName: string;

  @Column()
  versionCode: number;

  @Column({ nullable: true })
  url: string;

  @Column({ type: 'text', nullable: true })
  description: string;

  @Column({ default: 'all' })
  cid: string;

  @Column({ default: false })
  forceUpdate: boolean;

  @Column({ default: true })
  enabled: boolean;

  @CreateDateColumn()
  createTime: Date;

  @UpdateDateColumn()
  updateTime: Date;
}
