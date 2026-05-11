import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  UpdateDateColumn,
} from 'typeorm';

/** 认证策略开关与参数，表 ak_auth_settings（单行，id=1） */
@Entity('ak_auth_settings')
export class AuthSettings {
  @PrimaryGeneratedColumn()
  id: number;

  /** 华为默认入口 */
  @Column({ type: 'varchar', length: 20, default: 'getAuthCode' })
  huaweiPrimaryFlow: 'getAuthCode' | 'quickLogin';

  /** 华为一键登录开关（默认 false——凭据未申请前禁用） */
  @Column({ default: false })
  huaweiQuickLoginEnabled: boolean;

  /** 华为账号授权码模式开关（默认 false） */
  @Column({ default: false })
  huaweiGetAuthCodeEnabled: boolean;

  /** Sign in with Apple 开关（默认 false） */
  @Column({ default: false })
  appleSignInEnabled: boolean;

  /** SMS mock 高亮开关 */
  @Column({ default: true })
  smsMockHighlight: boolean;

  /** 验证码有效期（秒），默认 300 */
  @Column({ default: 300 })
  codeTtlSeconds: number;

  /** 重发间隔（秒），默认 60 */
  @Column({ default: 60 })
  codeResendIntervalSeconds: number;

  /** 单条验证码最大错误尝试次数，默认 5 */
  @Column({ default: 5 })
  codeMaxAttempts: number;

  /** 同标识日限，默认 10 */
  @Column({ default: 10 })
  codeDailyLimitPerIdentifier: number;

  @UpdateDateColumn()
  updatedAt: Date;
}
