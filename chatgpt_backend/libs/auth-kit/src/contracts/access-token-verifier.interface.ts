export interface AuthenticatedPrincipal {
  userId: number;
  userName: string;
  role: string;
}

/**
 * 访问令牌校验由宿主实现，auth-kit 不直接依赖宿主用户表或 JWT 库。
 * 返回值必须反映当前用户状态，而不是仅复用令牌内的角色声明。
 */
export interface IAccessTokenVerifier {
  verify(token: string): Promise<AuthenticatedPrincipal | null>;
}
