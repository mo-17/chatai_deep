'use client';

import { useEffect, useState } from 'react';
import { useAuthStore } from '@/store/authStore';
import { CloudApi, CloudSession, CloudSessionStale } from '@/lib/cloud-workflow/api';
import { CloudController } from '@/lib/cloud-workflow/controller';
import { CLOUD_DISABLED_NOTICE } from '@/lib/cloud-workflow/model';
import { CloudTasksView } from './CloudTasksView';

function backendOrigin(): string | null {
  try {
    const u = new URL(process.env.NEXT_PUBLIC_BACKEND || 'http://localhost:3000');
    return ['http:', 'https:'].includes(u.protocol) && !u.username && !u.password ? u.origin : null;
  } catch { return null; }
}
function currentSession(): CloudSession {
  const auth = useAuthStore.getState();
  const origin = backendOrigin();
  if (!origin) throw new Error('云后端地址不可用');
  return { token: auth.token, epoch: auth.sessionEpoch,
    origin,
    frontendOrigin: window.location.origin };
}
function OwnedCloudPage({ session }: { session: CloudSession }) {
  const { token, epoch, origin, frontendOrigin } = session;
  const [controller, setController] = useState<CloudController | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    let api: CloudApi;
    try {
      // 使用当前render捕获的会话；effect延后不能认领后来登录的身份。
      api = new CloudApi({ session: { token, epoch, origin, frontendOrigin }, current: currentSession,
        onCurrent401: () => { api.verify(); useAuthStore.getState().logout(); } });
    } catch (e) {
      if (!(e instanceof CloudSessionStale)) {
        queueMicrotask(() => { if (active) setError('云观察会话不可用，请重新打开'); });
      }
      return () => { active = false; };
    }
    // 生产构造固定禁用，无env/localStorage/query或表单开启参数。
    const c = new CloudController(api, sessionStorage);
    c.setVisible(document.visibilityState === 'visible');
    void c.initialize().then(() => { if (active) setController(c); }).catch(() => {
      if (active) { try { c.verify(); setError('云任务读取失败，请重新打开查询'); } catch { /* 旧会话不显示迟到错误 */ } }
    });
    return () => { active = false; c.close(); };
  }, [token, epoch, origin, frontendOrigin]);
  if (error) return <p role="alert">{error}</p>;
  if (!controller) return <p role="status">正在读取我的云任务…</p>;
  return <CloudTasksView controller={controller}/>;
}
export default function CloudTasksPage() {
  const token = useAuthStore(s => s.token), epoch = useAuthStore(s => s.sessionEpoch);
  if (!token || token === 'guest-mode') return <div><h1>我的云任务</h1><p>{CLOUD_DISABLED_NOTICE}</p><p>请先登录；登录不代表云能力已启用。</p></div>;
  const origin = backendOrigin();
  if (!origin) return <p>{CLOUD_DISABLED_NOTICE}；云后端地址不可用。</p>;
  // A→B→A、同token重登录和hydrate均创建全新的可见观察页。
  return <OwnedCloudPage key={`${epoch}:${origin}`} session={{ token, epoch, origin,
    frontendOrigin: typeof window === 'undefined' ? '' : window.location.origin }}/>;
}
