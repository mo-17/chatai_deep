/** JWT 签发接口 —— 宿主项目实现，lib 在登录成功后调用 */
export interface IJwtSigner {
  sign(user: { userId: number; userName: string; role?: string }): string;
}
