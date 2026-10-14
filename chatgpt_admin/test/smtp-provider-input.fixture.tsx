'use client';
// 仅在自有/tmp Next夹具复制挂载，使用真实父页和axios；全部API合成。
import { useEffect, useState } from 'react';
import ProviderPage from '@/app/(dashboard)/auth/providers/page';
import { api } from '@/lib/api/client';
import { useAuthStore } from '@/store/authStore';
import { AxiosError, type InternalAxiosRequestConfig } from 'axios';
let saved = { id: 1, key: 'generic', displayName: '合成SMTP', authMode: 'password', configRevision: 1, microsoftClientId: '', hasMicrosoftClientSecret: true, hasPassword: true, host: 'smtp.example.test', port: 587, secure: false, username: 'fixture@example.test', fromName: '合成', fromAddress: 'fixture@example.test', configured: true, enabled: false, lastTestedAt: null, lastTestStatus: null, lastTestError: null, lastTestRevision: null };
let rejectNext = false;
const counts = { puts: 0, activate: 0, test: 0, oauth: 0, gets: 0 };
const listeners = new Set<() => void>();
const publish = () => listeners.forEach(fn => fn());
api.defaults.adapter = async config => {
 const reply = (data: unknown) => ({ config, data: { code: 0, data }, status: 200, statusText: 'synthetic', headers: {} });
 if (config.url === '/admin/auth/providers' && config.method === 'get') { counts.gets++; publish(); return reply([{ ...saved }]); }
 if (config.url?.endsWith('/microsoft/status')) return reply({ status: 'not_connected', configured: true, emailHint: null });
 if (config.url === '/admin/auth/providers/generic' && config.method === 'put') {
  counts.puts++; publish();
  if (rejectNext) { rejectNext = false; throw new AxiosError('synthetic', 'ERR_BAD_REQUEST', config as InternalAxiosRequestConfig, null, { ...reply(null), status: 400, data: { code: -1, message: 'Microsoft Client ID 必须填写微软应用的“应用程序（客户端）ID”（UUID）', errorCode: 'AUTH_MICROSOFT_CLIENT_ID_INVALID' } }); }
  const body = JSON.parse(config.data as string) as Partial<typeof saved>;
  saved = { ...saved, ...body, configRevision: saved.configRevision + 1, enabled: false }; return reply(saved);
 }
 if (config.url?.endsWith('/activate')) counts.activate++;
 if (config.url?.endsWith('/test')) counts.test++;
 if (/microsoft\/(start|complete|disconnect)/.test(config.url || '')) counts.oauth++;
 publish(); throw Error('synthetic unexpected action');
};
export default function InputFixture() {
 const [ready, setReady] = useState(false), [audit, setAudit] = useState('');
 useEffect(() => { const render = () => setAudit(JSON.stringify(counts)); listeners.add(render); useAuthStore.getState().setAuth('synthetic-input-session', { id: 7, userName: '合成' }); queueMicrotask(() => { setReady(true); render(); }); return () => { listeners.delete(render); }; }, []);
 return <main className="p-6"><p>合成API输入验证，真实表单</p><button onClick={() => { rejectNext = true; }}>下次合成服务器拒绝保存</button><pre aria-label="合成请求统计">{audit}</pre>{ready && <ProviderPage />}</main>;
}
