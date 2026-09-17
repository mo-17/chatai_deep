const KNOWN_INSECURE_SECRETS = new Set([
  'CHANGE_ME',
  'CHANGE_ME_CHANGE_ME_CHANGE_ME_32B',
]);

/** 共享的启动密钥校验，避免各调用点以不同规则接受默认密钥。 */
export function requireAppSecretKey(value: string | undefined): string {
  const secret = value?.trim();
  if (
    !secret ||
    secret.length < 32 ||
    KNOWN_INSECURE_SECRETS.has(secret) ||
    secret.startsWith('CHANGE_ME')
  ) {
    throw new Error('APP_SECRET_KEY 必须配置为至少 32 字符的非默认随机值');
  }
  return secret;
}
