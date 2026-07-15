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

  /// direct APK 的可选完整性摘要。旧记录保持 null，客户端继续按历史方式更新；
  /// 新发布记录配置后，下载端会在安装前强制校验。
  @Column({ type: 'varchar', length: 64, nullable: true })
  sha256: string | null;

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
