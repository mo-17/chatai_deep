import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  Index,
  CreateDateColumn,
} from 'typeorm';

/** 验证码记录，表 ak_verification_codes */
@Entity('ak_verification_codes')
@Index(['channel', 'identifier', 'purpose', 'createdAt'])
export class VerificationCode {
  @PrimaryGeneratedColumn()
  id: number;

  /** 通道：email / sms */
  @Column({ type: 'varchar', length: 20 })
  channel: 'email' | 'sms';

  /** 标识（邮箱地址或 E.164 手机号） */
  @Column({ type: 'varchar', length: 320 })
  identifier: string;

  /** 用途：login / register / bind / reset_password */
  @Column({ type: 'varchar', length: 20 })
  purpose: 'login' | 'register' | 'bind' | 'reset_password';

  /** bcrypt(code)，不存明文 */
  @Column({ type: 'varchar', length: 100 })
  codeHash: string;

  /** 过期时间 = now + TTL */
  @Column()
  expiresAt: Date;

  /** 消费时间，null 表示未消费 */
  @Column({ type: 'timestamptz', nullable: true, default: null })
  consumedAt: Date | null;

  /** 校验失败次数，>=5 锁定 */
  @Column({ default: 0 })
  attempts: number;

  /** 请求 IP */
  @Column({ type: 'varchar', nullable: true, default: null })
  ipAddress: string | null;

  /** 仅 mock 阶段使用：SMS mock 记 'MOCK'，正式服务商留空 */
  @Column({ type: 'varchar', nullable: true, default: null })
  note: string | null;

  @CreateDateColumn()
  createdAt: Date;
}
