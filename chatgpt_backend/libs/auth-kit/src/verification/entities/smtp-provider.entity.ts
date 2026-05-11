import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';

/** SMTP 邮件服务商凭据，表 ak_smtp_providers */
@Entity('ak_smtp_providers')
export class SmtpProvider {
  @PrimaryGeneratedColumn()
  id: number;

  /** 服务商标识：generic / aliyun_dm / tencent_ses */
  @Column({ type: 'varchar', length: 50, unique: true })
  key: 'generic' | 'aliyun_dm' | 'tencent_ses';

  /** 展示名 */
  @Column({ type: 'varchar', length: 100 })
  displayName: string;

  /** SMTP 主机 */
  @Column({ type: 'varchar', length: 255 })
  host: string;

  /** SMTP 端口 */
  @Column()
  port: number;

  /** 是否 SSL（465=true，587/25=false 即 StartTLS） */
  @Column()
  secure: boolean;

  /** SMTP 用户名 */
  @Column({ type: 'varchar', length: 255 })
  username: string;

  /** AES-256-GCM 加密的密码 */
  @Column({ type: 'varchar', length: 500 })
  passwordEncrypted: string;

  /** 发件人显示名 */
  @Column({ type: 'varchar', length: 100 })
  fromName: string;

  /** 发件人地址 */
  @Column({ type: 'varchar', length: 320 })
  fromAddress: string;

  /** 是否启用（同时仅一条为 true） */
  @Column({ default: false })
  enabled: boolean;

  /** 上次测试时间 */
  @Column({ type: 'timestamptz', nullable: true, default: null })
  lastTestedAt: Date | null;

  /** 上次测试状态 */
  @Column({ type: 'varchar', length: 20, nullable: true, default: null })
  lastTestStatus: 'ok' | 'failed' | null;

  /** 上次测试错误信息 */
  @Column({ type: 'varchar', nullable: true, default: null })
  lastTestError: string | null;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}
