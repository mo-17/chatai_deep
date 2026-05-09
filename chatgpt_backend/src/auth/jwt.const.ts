const fallback = 'chatgpt-flutter-secret-key';
const secret = process.env.JWT_SECRET ?? fallback;

if (process.env.NODE_ENV === 'production' && secret === fallback) {
  throw new Error('生产环境必须显式配置 JWT_SECRET，不允许使用默认值');
}
if (secret.length < 32) {
  // eslint-disable-next-line no-console
  console.warn(`[security] JWT_SECRET 长度仅 ${secret.length}，建议 ≥ 32 字节`);
}

export const JWT_SECRET = secret;

export interface JwtPayload {
  userId: number;
  userName: string;
  role?: string;
}
