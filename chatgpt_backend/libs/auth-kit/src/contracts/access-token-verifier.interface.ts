export interface AuthenticatedPrincipal {
  userId: number;
  userName: string;
  role: string;
  /** 本次已验证 JWT 的版本，锁后复核时不得用新用户值补签。 */
  tokenVersion: number;
  /** 已验证 JWT 有 exp 时保留其原截止；旧无 exp 令牌仍沿普通认证兼容。 */
  expiresAt?: number;
}

/**
 * 访问令牌校验由宿主实现，auth-kit 不直接依赖宿主用户表或 JWT 库。
 * 返回值必须反映当前用户状态，而不是仅复用令牌内的角色声明。
 */
export interface IAccessTokenVerifier {
  verify(token: string): Promise<AuthenticatedPrincipal | null>;
}
