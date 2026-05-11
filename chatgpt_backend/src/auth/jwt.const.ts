const secret = process.env.JWT_SECRET;

if (!secret) {
  throw new Error(
    'JWT_SECRET 未配置。请在 chatgpt_backend/.env 中设置，' +
      '推荐用 `openssl rand -base64 48` 生成 ≥ 32 字节随机值。' +
      '示例文件：chatgpt_backend/.env.example',
  );
}
if (secret.length < 32) {
  throw new Error(
    `JWT_SECRET 长度仅 ${secret.length} 字节，必须 ≥ 32。` +
      '推荐用 `openssl rand -base64 48` 重新生成。',
  );
}

export const JWT_SECRET = secret;

export interface JwtPayload {
  userId: number;
  userName: string;
  role?: string;
}
