'use client';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { MicrosoftAuthorization as Controller } from '@/lib/microsoft-auth/controller';
import type { ProviderReconciler } from '@/lib/microsoft-auth/controller';
export const MICROSOFT_LABELS = { not_configured: '未配置', not_connected: '待授权', connected: '已连接', needs_reauth: '需重新授权' };
const FLOW_LABELS = { started: '等待微软回调', received: '已收到回调，等待完成授权', exchanging: '兑换中，请刷新状态', connected: '已连接', failed: '授权失败，请重新发起', unknown: '兑换结果未知，仅可查询状态', cancelled: '授权已取消', expired: '授权已过期' };
export function MicrosoftAuthorizationView({ controller }: { controller: Controller }) {
  const s = useSyncExternalStore(controller.subscribe, controller.getSnapshot, controller.getSnapshot);
  return <div className="space-y-2 text-sm">
    <p>个人 Outlook / Hotmail：<b>{s.connection ? MICROSOFT_LABELS[s.connection.status] : '读取状态中'}</b></p>
    {s.connection?.emailHint && <p>微软展示账号：{s.connection.emailHint}（发件地址以保存配置为准）</p>}
    {s.flow && <p>{FLOW_LABELS[s.flow]}</p>}
    <div className="flex flex-wrap gap-2">
      <button className="auth-button" disabled={s.busy || !s.connection?.configured} onClick={() => void controller.start()}>发起微软授权</button>
      <button className="auth-button" disabled={s.busy} onClick={() => void controller.refresh()}>刷新授权状态</button>
      <button className="auth-button" disabled={s.busy || s.attempted || s.flow !== 'received'} onClick={() => void controller.complete()}>完成授权</button>
      <button className="auth-button" disabled={s.busy || s.connection?.status === 'not_configured'} onClick={() => void controller.disconnect()}>断开连接</button>
    </div>
    {s.notice && <p role="status">{s.notice}</p>}
  </div>;
}
export default function MicrosoftAuthorization({ onProviderRefresh }: { onProviderRefresh?: ProviderReconciler }) {
  const [controller, setController] = useState<Controller | null>(null);
  useEffect(() => {
    const c = Controller.browser(onProviderRefresh);
    // 每次 effect setup 创建独立控制器，StrictMode cleanup 不复用已关闭实例。
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setController(c); void c.refresh();
    const returned = (event: MessageEvent) => c.returned(event);
    window.addEventListener('message', returned);
    return () => { window.removeEventListener('message', returned); c.close(); };
  }, [onProviderRefresh]);
  return controller ? <MicrosoftAuthorizationView controller={controller} /> : <p>读取授权状态中</p>;
}
