import { api } from './client';

// SMTP 服务商
export interface SmtpProvider {
  id: number;
  key: string;
  host: string;
  port: number;
  secure: boolean;
  username: string;
  fromName: string;
  fromAddress: string;
  enabled: boolean;
  lastTestedAt: string | null;
  lastTestStatus: string | null;
  createdAt: string;
}

// 验证码记录
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

// 邮件模板
export interface EmailTemplate {
  id: number;
  code: string;
  name: string;
  subject: string;
  html: string;
  updatedAt: string;
}

// Auth 设置
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

// ---- SMTP 服务商 API ----

export async function fetchProviders() {
  const { data } = await api.get<SmtpProvider[]>('/uapi/admin/auth/providers');
  return data as unknown as SmtpProvider[];
}

export async function createProvider(body: Partial<SmtpProvider>) {
  const { data } = await api.post<SmtpProvider>('/uapi/admin/auth/providers', body);
  return data as unknown as SmtpProvider;
}

export async function updateProvider(id: number, body: Partial<SmtpProvider>) {
  const { data } = await api.patch<SmtpProvider>(`/uapi/admin/auth/providers/${id}`, body);
  return data as unknown as SmtpProvider;
}

export async function deleteProvider(id: number) {
  await api.delete(`/uapi/admin/auth/providers/${id}`);
}

export async function activateProvider(key: string) {
  const { data } = await api.post(`/uapi/admin/auth/providers/${key}/activate`);
  return data;
}

export async function testProvider(id: number) {
  const { data } = await api.post<SmtpProvider>(`/uapi/admin/auth/providers/${id}/test`);
  return data as unknown as SmtpProvider;
}

// ---- 验证码记录 API ----

export async function fetchCodes(params?: { page?: number; pageSize?: number; channel?: string; purpose?: string }) {
  const { data } = await api.get<{ items: CodeRecord[]; total: number }>('/uapi/admin/auth/codes', { params });
  return data as unknown as { items: CodeRecord[]; total: number };
}

// ---- 邮件模板 API ----

export async function fetchTemplates() {
  const { data } = await api.get<EmailTemplate[]>('/uapi/admin/auth/templates');
  return data as unknown as EmailTemplate[];
}

export async function updateTemplate(id: number, body: Partial<EmailTemplate>) {
  const { data } = await api.patch<EmailTemplate>(`/uapi/admin/auth/templates/${id}`, body);
  return data as unknown as EmailTemplate;
}

// ---- Auth 设置 API ----

export async function fetchAuthSettings() {
  const { data } = await api.get<AuthSettings>('/uapi/admin/auth/settings');
  return data as unknown as AuthSettings;
}

export async function updateAuthSettings(body: Partial<AuthSettings>) {
  const { data } = await api.patch<AuthSettings>('/uapi/admin/auth/settings', body);
  return data as unknown as AuthSettings;
}
