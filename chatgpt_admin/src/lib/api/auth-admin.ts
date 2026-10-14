import { api } from './client';
import { captureAuthSession, assertAuthSession, type AuthSession } from './auth-session';

async function request<T>(method: 'GET' | 'PUT' | 'POST', url: string, data?: unknown, params?: unknown, session = captureAuthSession()): Promise<T> {
  assertAuthSession(session);
  const response = await api.request<T>({ method, url, data, params, ...{ authSession: session, authScoped: true } });
  assertAuthSession(session);
  return response.data;
}
export type SmtpProviderKey = 'generic' | 'aliyun_dm' | 'tencent_ses';
export interface SmtpProvider {
  id: number; key: SmtpProviderKey; displayName: string;
  authMode: 'password' | 'microsoft_oauth'; configRevision: number;
  microsoftClientId: string; hasMicrosoftClientSecret: boolean; hasPassword: boolean;
  host: string; port: number; secure: boolean; username: string;
  fromName: string; fromAddress: string; configured: boolean; enabled: boolean;
  lastTestedAt: string | null; lastTestStatus: 'ok' | 'failed' | null;
  lastTestError: string | null; lastTestRevision: number | null;
}
export interface ProviderDraft {
  displayName: string; authMode: SmtpProvider['authMode']; host: string; port: number; secure: boolean;
  username: string; fromName: string; fromAddress: string; password: string; clearPassword: boolean;
  microsoftClientId: string; microsoftClientSecret: string; clearMicrosoftClientSecret: boolean;
}
export function providerDraft(p: SmtpProvider): ProviderDraft {
  return { displayName: p.displayName, authMode: p.authMode, host: p.host, port: p.port, secure: p.secure,
    username: p.username, fromName: p.fromName, fromAddress: p.fromAddress, password: '', clearPassword: false,
    microsoftClientId: p.microsoftClientId || '', microsoftClientSecret: '', clearMicrosoftClientSecret: false };
}
export const MICROSOFT_CLIENT_ID_INVALID = 'Microsoft Client ID 必须填写微软应用的“应用程序（客户端）ID”（UUID）';
// 与后端 IsUUID() 的版本/variant 范围一致；空值由 required 与 serializer 同时拒绝。
export const MICROSOFT_CLIENT_ID_PATTERN = '(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|[fF]{8}-[fF]{4}-[fF]{4}-[fF]{4}-[fF]{12})';
export function providerPayload(d: ProviderDraft): Partial<ProviderDraft> {
  if (d.authMode === 'microsoft_oauth' && !new RegExp('^' + MICROSOFT_CLIENT_ID_PATTERN + '$').test(d.microsoftClientId.trim()))
    throw new Error(MICROSOFT_CLIENT_ID_INVALID);
  const common = { displayName: d.displayName.trim(), authMode: d.authMode, fromName: d.fromName.trim(), fromAddress: d.fromAddress.trim() };
  if (d.authMode === 'microsoft_oauth') return { ...common, microsoftClientId: d.microsoftClientId.trim(),
    ...(d.microsoftClientSecret ? { microsoftClientSecret: d.microsoftClientSecret } : {}),
    ...(d.clearMicrosoftClientSecret ? { clearMicrosoftClientSecret: true } : {}) };
  return { ...common, host: d.host.trim(), port: d.port, secure: d.secure, username: d.username.trim(),
    ...(d.password ? { password: d.password } : {}), ...(d.clearPassword ? { clearPassword: true } : {}) };
}
export const fetchProviders = () => request<SmtpProvider[]>('GET', '/admin/auth/providers');
export const updateProvider = (key: SmtpProviderKey, body: Partial<ProviderDraft>) => request<SmtpProvider>('PUT', `/admin/auth/providers/${key}`, body);
export const activateProvider = (key: SmtpProviderKey) => request<null>('POST', `/admin/auth/providers/${key}/activate`);
export interface TestResult { status: 'ok' | 'failed' | null; error: string | null; persisted: boolean; configRevision: number }
export const testProvider = (key: SmtpProviderKey, to: string) => request<TestResult>('POST', `/admin/auth/providers/${key}/test`, { to });

export interface CodeRecord {
  id: number; channel: string; identifier: string; purpose: string; expiresAt: string; consumedAt: string | null;
  attempts: number; ipAddress: string; createdAt: string;
  deliveryStatus: 'legacy' | 'pending' | 'sent' | 'failed' | 'unknown'; deliveryErrorCode: string | null;
  sentAt: string | null; invalidatedAt: string | null; invalidationReason: string | null;
}
export async function fetchCodes(params?: { page?: number; pageSize?: number; channel?: string; purpose?: string }) {
  const data = await request<{ list: CodeRecord[]; total: number }>('GET', '/admin/auth/codes', undefined, params);
  return { items: data.list, total: data.total };
}
export type TemplateKey = 'code-login' | 'code-register' | 'code-bind' | 'code-reset_password';
export const TEMPLATE_LABELS: Record<TemplateKey, string> = { 'code-login': '登录', 'code-register': '注册', 'code-bind': '绑定', 'code-reset_password': '重置密码' };
export interface EmailTemplate { id?: number; key: TemplateKey; subject: string; body: string; updatedAt?: string }
export const fetchTemplates = () => request<EmailTemplate[]>('GET', '/admin/auth/templates');
export const updateTemplate = (key: TemplateKey, body: Pick<EmailTemplate, 'subject' | 'body'>) => request<EmailTemplate>('PUT', `/admin/auth/templates/${key}`, body);
export interface AuthSettings {
  huaweiGetAuthCodeEnabled: boolean; huaweiQuickLoginEnabled: boolean; huaweiPrimaryFlow: 'getAuthCode' | 'quickLogin';
  appleSignInEnabled: boolean; smsMockHighlight: boolean; codeTtlSeconds: number; codeMaxAttempts: number;
  codeDailyLimitPerIdentifier: number; codeResendIntervalSeconds: number; codeHourlyLimitPerIp: number;
}
export const fetchAuthSettings = () => request<AuthSettings>('GET', '/admin/auth/settings');
export function settingsPayload(s: AuthSettings): AuthSettings {
  return { huaweiGetAuthCodeEnabled: s.huaweiGetAuthCodeEnabled, huaweiQuickLoginEnabled: s.huaweiQuickLoginEnabled,
    huaweiPrimaryFlow: s.huaweiPrimaryFlow, appleSignInEnabled: s.appleSignInEnabled, smsMockHighlight: s.smsMockHighlight,
    codeTtlSeconds: s.codeTtlSeconds, codeMaxAttempts: s.codeMaxAttempts, codeDailyLimitPerIdentifier: s.codeDailyLimitPerIdentifier,
    codeResendIntervalSeconds: s.codeResendIntervalSeconds, codeHourlyLimitPerIp: s.codeHourlyLimitPerIp };
}
export const updateAuthSettings = (s: AuthSettings) => request<AuthSettings>('PUT', '/admin/auth/settings', settingsPayload(s));

export interface MicrosoftStatus { status: 'not_configured' | 'not_connected' | 'connected' | 'needs_reauth'; configured: boolean; emailHint: string | null }
export type FlowStatus = 'started' | 'received' | 'exchanging' | 'connected' | 'failed' | 'unknown' | 'cancelled' | 'expired';
export interface MicrosoftStart { flowId: string; authorizeUrl: string; expiresAt: number }
const ms = '/admin/auth/providers/generic/microsoft';
export const microsoftStatus = () => request<MicrosoftStatus>('GET', `${ms}/status`);
export const microsoftStart = (session: AuthSession) => request<MicrosoftStart>('POST', `${ms}/start`, undefined, undefined, session);
export const microsoftFlow = (id: string, session: AuthSession) => request<{ status: FlowStatus }>('GET', `${ms}/flow/${encodeURIComponent(id)}`, undefined, undefined, session);
export const microsoftComplete = (id: string, session: AuthSession) => request<{ status: FlowStatus }>('POST', `${ms}/complete/${encodeURIComponent(id)}`, undefined, undefined, session);
export const microsoftDisconnect = (session: AuthSession) => request<null>('POST', `${ms}/disconnect`, undefined, undefined, session);
