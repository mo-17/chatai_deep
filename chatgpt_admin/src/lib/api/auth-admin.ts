import { api } from './client';

// baseURL 是 '/api'，next.config.ts 把 /api/:path* 重写到后端 /uapi/:path*，
// 所以这里的路径不要再带 /uapi/ 前缀。

// ============ SMTP 服务商 ============
// 后端 ak_smtp_providers 表只有 3 个固定 key，不支持新增/删除。
// 暴露的接口：GET list / PUT update / POST activate / POST test
export type SmtpProviderKey = 'generic' | 'aliyun_dm' | 'tencent_ses';

export interface SmtpProvider {
  id: number;
  key: SmtpProviderKey;
  displayName: string;
  host: string;
  port: number;
  secure: boolean;
  username: string;
  /** 后端只返回 '••••••••' 占位或空串，永远不返回明文 */
  passwordEncrypted: string;
  fromName: string;
  fromAddress: string;
  enabled: boolean;
  lastTestedAt: string | null;
  lastTestStatus: 'ok' | 'failed' | null;
  lastTestError: string | null;
  createdAt: string;
  updatedAt: string;
}

export async function fetchProviders() {
  const { data } = await api.get<SmtpProvider[]>('/admin/auth/providers');
  return data;
}

export async function updateProvider(
  key: SmtpProviderKey,
  body: Partial<Omit<SmtpProvider, 'id' | 'key' | 'passwordEncrypted'>> & { password?: string },
) {
  const { data } = await api.put<SmtpProvider>(`/admin/auth/providers/${key}`, body);
  return data;
}

export async function activateProvider(key: SmtpProviderKey) {
  await api.post(`/admin/auth/providers/${key}/activate`);
}

export interface TestResult {
  status: 'ok' | 'failed' | null;
  error: string | null;
}

export async function testProvider(key: SmtpProviderKey, to: string) {
  const { data } = await api.post<TestResult>(
    `/admin/auth/providers/${key}/test`,
    { to },
  );
  return data;
}

// ============ 验证码记录 / 邮件模板 / 设置 ============
// 这几块当前 FE/BE 字段对不齐，不在本次改造范围；保留原签名避免影响 templates/codes/settings 页面。

export interface CodeRecord {
  id: number;
  channel: string;
  identifier: string;
  purpose: string;
  codeHash: string;
  expiresAt: string;
  consumedAt: string | null;
  attempts: number;
  ipAddress: string;
  note: string | null;
  createdAt: string;
}

export interface EmailTemplate {
  id: number;
  code: string;
  name: string;
  subject: string;
  html: string;
  updatedAt: string;
}

export interface AuthSettings {
  id: number;
  huaweiGetAuthCodeEnabled: boolean;
  huaweiQuickLoginEnabled: boolean;
  huaweiPrimaryFlow: string;
  appleSignInEnabled: boolean;
  smsMockHighlight: boolean;
  codeTtlSeconds: number;
  codeMaxAttempts: number;
  codeDailyLimit: number;
  codeResendSeconds: number;
  codeHourlyLimitPerIp: number;
}

export async function fetchCodes(params?: { page?: number; pageSize?: number; channel?: string; purpose?: string }) {
  // 后端实际返回 { list, total, page, pageSize }；这里适配成页面使用的 { items, total } 结构。
  const { data } = await api.get<{ list?: CodeRecord[]; total?: number }>('/admin/auth/codes', { params });
  return { items: data?.list ?? [], total: data?.total ?? 0 };
}

export async function fetchTemplates() {
  const { data } = await api.get<EmailTemplate[]>('/admin/auth/templates');
  return data as unknown as EmailTemplate[];
}

export async function updateTemplate(id: number, body: Partial<EmailTemplate>) {
  const { data } = await api.patch<EmailTemplate>(`/admin/auth/templates/${id}`, body);
  return data as unknown as EmailTemplate;
}

export async function fetchAuthSettings() {
  const { data } = await api.get<AuthSettings>('/admin/auth/settings');
  return data as unknown as AuthSettings;
}

export async function updateAuthSettings(body: Partial<AuthSettings>) {
  const { data } = await api.patch<AuthSettings>('/admin/auth/settings', body);
  return data as unknown as AuthSettings;
}
