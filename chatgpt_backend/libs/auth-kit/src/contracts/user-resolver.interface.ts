import {
  AuthUser,
  CreateUserInput,
  AuthChannel,
  ThirdPartyProvider,
} from './auth-user.types';

/**
 * 用户解析器接口 —— 宿主项目必须实现。
 * lib 通过此接口访问用户表，不直接依赖宿主 User 实体。
 */
export interface IUserResolver {
  /** 按邮箱查找用户 */
  findByEmail(email: string): Promise<AuthUser | null>;

  /** 按手机号查找用户（countryCode + phoneNumber） */
  findByPhone(
    countryCode: string,
    phoneNumber: string,
  ): Promise<AuthUser | null>;

  /** 按华为 unionId 查找 */
  findByHuaweiUnionId(unionId: string): Promise<AuthUser | null>;

  /** 按 Apple subject 查找 */
  findByAppleSubject(subject: string): Promise<AuthUser | null>;

  /** 按 userName 查找（兼容旧登录） */
  findByUserName(userName: string): Promise<AuthUser | null>;

  /** 按 ID 查找 */
  findById(id: number): Promise<AuthUser | null>;

  /**
   * 创建用户。用于验证码登录无现存用户时自动创建。
   * password 可选——验证码登录不强制密码。
   */
  createUser(input: CreateUserInput): Promise<AuthUser>;

  /**
   * 创建待绑定用户（第三方首次登录，尚未绑定邮箱/手机号）。
   * 仅写入第三方标识，不签发 JWT。
   */
  createPendingThirdPartyUser(params: {
    provider: ThirdPartyProvider;
    unionId?: string;
    openId?: string;
    subject?: string;
    emailRelay?: string;
  }): Promise<AuthUser>;

  /**
   * 给已存在用户绑定额外通道（邮箱 / 手机号 / 华为 / Apple）。
   */
  bindIdentifier(
    userId: number,
    params: {
      channel?: AuthChannel;
      email?: string;
      countryCode?: string;
      phoneNumber?: string;
      provider?: ThirdPartyProvider;
      unionId?: string;
      openId?: string;
      subject?: string;
      emailRelay?: string;
    },
  ): Promise<AuthUser>;

  /**
   * 原子消费第三方待绑定账号并绑定已验证标识。
   * 实现必须锁定用户行，并拒绝已绑定或 provider 不匹配的待绑定账号。
   */
  bindPendingThirdPartyIdentifier(
    userId: number,
    provider: ThirdPartyProvider,
    params: {
      channel: AuthChannel;
      email?: string;
      countryCode?: string;
      phoneNumber?: string;
    },
  ): Promise<AuthUser>;

  /** 解绑第三方 */
  unbindThirdParty(userId: number, provider: ThirdPartyProvider): Promise<void>;

  /** 解绑邮箱 */
  unbindEmail(userId: number): Promise<void>;

  /** 解绑手机号 */
  unbindPhone(userId: number): Promise<void>;

  /** 更新密码 */
  updatePassword(userId: number, newPasswordHash: string): Promise<void>;

  /** 标记邮箱已验证 */
  markEmailVerified(userId: number): Promise<void>;

  /** 标记手机号已验证 */
  markPhoneVerified(userId: number): Promise<void>;
}
