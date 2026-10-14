'use client';
// 仅复制到自有/tmp Next夹具路由。真实父页/授权组件/控制器/axios；网络与弹窗仅代码替代。
import { useEffect, useState } from 'react';
import ProviderPage from '@/app/(dashboard)/auth/providers/page';
import CodesPage from '@/app/(dashboard)/auth/codes/page';
import { api } from '@/lib/api/client';
import { captureAuthSession, isAuthSessionCurrent } from '@/lib/api/auth-session';
import * as a from '@/lib/api/auth-admin';
import { useAuthStore } from '@/store/authStore';
import { MicrosoftAuthorization as Controller } from '@/lib/microsoft-auth/controller';
import { AxiosError, type InternalAxiosRequestConfig, type AxiosResponse } from 'axios';

type Hook = (isCurrent: () => boolean) => Promise<void>;
type Owner = 'A' | 'B';
const enabled: Record<Owner, boolean> = { A: true, B: false };
const connected: Record<Owner, boolean> = { A: true, B: true };
let unknownDisconnect = false, rejectProviders = false, holdProviders = false, holdComplete = false;
const held: Array<() => void> = [];
const calls: Array<{ method: string; path: string; owner: Owner }> = [];
const instances: Controller[] = [];
const listeners = new Set<() => void>();
const publish = () => listeners.forEach(fn => fn());
function response(config: InternalAxiosRequestConfig, data: unknown): AxiosResponse {
  return { config, data: { code: 0, data }, status: 200, statusText: 'synthetic', headers: {} };
}
function provider(owner: Owner): a.SmtpProvider {
  return { id: 1, key: 'generic', displayName: `合成 ${owner}`, authMode: 'microsoft_oauth', configRevision: 1,
    microsoftClientId: '01234567-1234-4123-8123-123456789abc', hasMicrosoftClientSecret: true, hasPassword: false,
    host: 'smtp-mail.outlook.com', port: 587, secure: false, username: 'fixed@synthetic.invalid', fromName: '合成',
    fromAddress: 'fixed@synthetic.invalid', configured: true, enabled: enabled[owner], lastTestedAt: null,
    lastTestStatus: null, lastTestError: null, lastTestRevision: null };
}
api.defaults.adapter = async config => {
  const owner: Owner = config.headers.Authorization === 'Bearer synthetic-session-B' ? 'B' : 'A';
  const path = config.url || '', method = config.method || '';
  calls.push({ method, path, owner }); publish();
  if (path === '/admin/auth/providers') {
    if (rejectProviders) { rejectProviders = false; throw new AxiosError('synthetic read failed', 'ERR_NETWORK', config); }
    const snapshot = [provider(owner)];
    if (holdProviders) { holdProviders = false; await new Promise<void>(resolve => held.push(resolve)); }
    return response(config, snapshot);
  }
  if (path.endsWith('/microsoft/status')) return response(config, { status: connected[owner] ? 'connected' : 'not_connected', configured: true, emailHint: null });
  if (path.endsWith('/microsoft/disconnect')) {
    enabled[owner] = false; connected[owner] = false; publish();
    if (unknownDisconnect) { unknownDisconnect = false; throw new AxiosError('synthetic response lost', 'ERR_NETWORK', config); }
    return response(config, null);
  }
  if (path.endsWith('/microsoft/start')) {
    connected[owner] = false;
    const url = new URL('https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize');
    url.search = new URLSearchParams({ client_id: '01234567-1234-4123-8123-123456789abc', response_type: 'code', response_mode: 'form_post', redirect_uri: 'https://synthetic-admin.invalid/api/auth/microsoft/callback', scope: 'https://outlook.office.com/SMTP.Send offline_access openid profile email', state: 'a'.repeat(43), nonce: 'b'.repeat(43), code_challenge: 'c'.repeat(43), code_challenge_method: 'S256' }).toString();
    return response(config, { flowId: '01234567-1234-4123-8123-123456789abc', authorizeUrl: url.href, expiresAt: Date.now() + 240000 });
  }
  if (path.includes('/microsoft/flow/')) return response(config, { status: connected[owner] ? 'connected' : 'received' });
  if (path.includes('/microsoft/complete/')) {
    if (holdComplete) { holdComplete = false; await new Promise<void>(resolve => held.push(resolve)); }
    connected[owner] = true; publish(); return response(config, { status: 'connected' });
  }
  if (path.endsWith('/activate')) { enabled[owner] = true; publish(); return response(config, null); }
  if (path === '/admin/auth/codes') return response(config, { list: [{ id: 1, channel: 'email', identifier: 'legacy@synthetic.invalid', purpose: 'login', expiresAt: '2099-01-01', consumedAt: null, attempts: 0, ipAddress: 'synthetic', createdAt: '2026-10-12', deliveryStatus: 'legacy', deliveryErrorCode: null, sentAt: null, invalidatedAt: null, invalidationReason: null }], total: 1 });
  throw new AxiosError('synthetic unexpected route', 'ERR_NETWORK', config);
};
// 浏览器夹具以HTTP运行。只为authorize URL校验注入合成HTTPS origin；真实API仍绑定原HTTP token/epoch/origin。
Controller.browser = (hook?: Hook) => {
  const real = captureAuthSession(), bound = { ...real, origin: 'https://synthetic-admin.invalid' };
  const c = new Controller({ session: () => bound, current: () => isAuthSessionCurrent(real),
    popup: () => ({ source: {}, close: () => {}, navigate: () => {} }),
    start: () => a.microsoftStart(real), flow: id => a.microsoftFlow(id, real), complete: id => a.microsoftComplete(id, real),
    status: a.microsoftStatus, disconnect: () => a.microsoftDisconnect(real), now: Date.now }, hook);
  instances.push(c); return c;
};
export default function ReconciliationFixture() {
  const [ready, setReady] = useState(false), [audit, setAudit] = useState('');
  useEffect(() => {
    const render = () => setAudit(JSON.stringify({ authoritative: enabled, calls, held: held.length }));
    listeners.add(render); useAuthStore.getState().setAuth('synthetic-session-A', { id: 7, userName: '合成A' });
    // 模块初始化后的实际父组件挂载；无真实凭据或外部网络。
    queueMicrotask(() => { setReady(true); render(); });
    return () => { listeners.delete(render); instances.forEach(c => c.close()); };
  }, []);
  return <main className="p-6 space-y-4">
    <p>合成API，弹窗不导航微软；实际父页和授权组件</p>
    <div className="flex flex-wrap gap-2">
      <button onClick={() => { unknownDisconnect = true; }}>下次断开响应未知</button>
      <button onClick={() => { rejectProviders = true; }}>下次卡片查询失败</button>
      <button onClick={() => { holdProviders = true; }}>挂起下次卡片查询</button>
      <button onClick={() => { holdComplete = true; }}>挂起下次兑换</button>
      <button onClick={() => { useAuthStore.getState().setAuth('synthetic-session-B', { id: 8, userName: '合成B' }); }}>切换合成账号B</button>
      <button onClick={() => { instances.at(-1)?.close(); }}>关闭原控制器generation</button>
      <button onClick={() => { held.splice(0).forEach(fn => fn()); publish(); }}>释放合成响应</button>
    </div>
    <pre aria-label="合成审计">{audit}</pre>
    {ready && <><ProviderPage /><CodesPage /></>}
  </main>;
}
