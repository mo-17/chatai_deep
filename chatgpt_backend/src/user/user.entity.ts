import { Entity, Column, PrimaryGeneratedColumn, Index } from 'typeorm';

@Entity('users')
@Index(['countryCode', 'phoneNumber'], {
  unique: true,
  where: '"phoneNumber" IS NOT NULL',
})
export class User {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true })
  userName: string;

  /** bcrypt 哈希；验证码登录用户不强制密码，设为 nullable */
  @Column({ type: 'varchar', nullable: true })
  password: string | null;

  @Column({ nullable: true })
  avatar: string;

  @Column({ nullable: true })
  imoocId: string;

  @Column({ default: 'user' })
  role: string;

  @Column({ default: false })
  banned: boolean;

  /** 安全状态版本；密码/角色/封禁变化时递增，使旧 JWT 立即失效。 */
  @Column({ default: 0 })
  tokenVersion: number;

  // ---- 多通道登录新增字段 ----

  @Column({ type: 'varchar', unique: true, nullable: true })
  email: string | null;

  @Column({ type: 'timestamptz', nullable: true })
  emailVerifiedAt: Date | null;

  /** E.164 国家区号，如 +86 */
  @Column({ type: 'varchar', nullable: true })
  countryCode: string | null;

  /** 手机号（不含区号），如 13800000000 */
  @Column({ type: 'varchar', nullable: true })
  phoneNumber: string | null;

  @Column({ type: 'timestamptz', nullable: true })
  phoneVerifiedAt: Date | null;

  @Column({ type: 'varchar', unique: true, nullable: true })
  huaweiUnionId: string | null;

  @Column({ type: 'varchar', nullable: true })
  huaweiOpenId: string | null;

  /** Apple id_token sub claim */
  @Column({ type: 'varchar', unique: true, nullable: true })
  appleSubject: string | null;

  /** Apple 私密中继邮箱 */
  @Column({ type: 'varchar', nullable: true })
  appleEmailRelay: string | null;
}
