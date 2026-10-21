'use client';

import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { productGet, productPatch } from '@/lib/api/product-session';
import { captureAuthSession, assertAuthSession, type AuthSession } from '@/lib/api/auth-session';
import { useAuthStore } from '@/store/authStore';

interface Settings { ownerHourly: number; globalHourly: number; ownerOverrides: Record<string, number> }
interface Overview {
  uptimeSeconds: number; counts: { completed: number; failed: number; cancelled: number };
  completedPages: number; averageSeconds: number; queueDepth: number; running: number;
  workerRssBytes: number | null; childRssBytes: number | null; settings: Settings;
}
const memory = (value: number | null) => value == null ? '不可用' : `${(value / 1048576).toFixed(1)} MiB`;
export default function OcrPage() {
  const epoch = useAuthStore(state => state.sessionEpoch);
  return <OcrView key={epoch} epoch={epoch} />;
}
function OcrView({ epoch }: { epoch: number }) {
  const [session] = useState(captureAuthSession);
  const query = useQuery({ queryKey: ['ocr-overview', epoch],
    queryFn: () => productGet<Overview>('/admin/ocr/overview', session),
    refetchInterval: 15000, retry: false });
  const data = query.data;
  const total = data ? data.counts.completed + data.counts.failed + data.counts.cancelled : 0;
  return <div className="min-w-0 space-y-6" aria-label="OCR 管理">
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div><h1 className="text-2xl font-bold">OCR 管理</h1><p className="mt-1 text-sm text-default-500">处理质量、资源占用与账号使用额度</p></div>
      <button className="rounded-lg border border-default-200 px-4 py-2" disabled={query.isFetching} onClick={() => query.refetch()}>刷新</button>
    </div>
    {query.isPending && <p role="status">正在读取 OCR 服务…</p>}
    {query.isError && <p role="alert" className="rounded-xl bg-danger-50 p-4 text-danger">OCR 状态读取失败，请检查服务、网络或管理员登录。{data && ' 下方保留上次采样。'}</p>}
    {data && <>
      <p className="text-sm text-default-500">以下统计从 OCR 服务本次启动开始，已运行 {Math.floor(data.uptimeSeconds / 60)} 分钟；服务重启会重置计数。</p>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Stat title="成功 / 失败 / 取消" value={`${data.counts.completed} / ${data.counts.failed} / ${data.counts.cancelled}`} />
        <Stat title="成功率（含取消）" value={total ? `${(data.counts.completed / total * 100).toFixed(1)}%` : '暂无任务'} />
        <Stat title="平均执行耗时" value={`${data.averageSeconds} 秒`} />
        <Stat title="已完成识别页" value={String(data.completedPages)} />
        <Stat title="正在识别 / 排队" value={`${data.running} / ${data.queueDepth}`} />
        <Stat title="Worker RSS" value={memory(data.workerRssBytes)} />
        <Stat title="当前识别子进程 RSS" value={memory(data.childRssBytes)} />
        <Stat title="并发与文件上限" value="串行 · 8 MiB · 20 页" />
      </div>
      <SettingsEditor key={JSON.stringify(data.settings)} initial={data.settings} session={session} onSaved={() => query.refetch()} />
      <p className="text-xs text-default-500">不采集文档正文、文件名或访问令牌。内存为 OCR 进程采样，非整机内存。额度修改只影响后续上传，单任务并发、超时和内存上限保持有界。</p>
    </>}
  </div>;
}
function Stat({ title, value }: { title: string; value: string }) {
  return <section className="rounded-xl border border-default-200 p-5"><h2 className="text-sm text-default-500">{title}</h2><p className="mt-3 break-words font-semibold">{value}</p></section>;
}
function SettingsEditor({ initial, session, onSaved }: { initial: Settings; session: AuthSession; onSaved: () => unknown }) {
  const [owner, setOwner] = useState(String(initial.ownerHourly));
  const [global, setGlobal] = useState(String(initial.globalHourly));
  const [overrides, setOverrides] = useState(Object.entries(initial.ownerOverrides).map(([key,value]) => `${key}=${value}`).join('\n'));
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;
    const ownerHourly = Number(owner), globalHourly = Number(global);
    if (!/^\d+$/.test(owner) || !/^\d+$/.test(global) || ownerHourly > 200 || globalHourly < 1 || globalHourly > 1000) {
      setNotice('账号额度为 0～200，全局额度为 1～1000，均为整数'); return;
    }
    const ownerOverrides: Record<string, number> = {};
    for (const line of overrides.split('\n').map(value => value.trim()).filter(Boolean)) {
      const match = /^(user|admin):([1-9][0-9]{0,15})=(\d{1,3})$/.exec(line);
      if (!match || Number(match[3]) > 200 || `${match[1]}:${match[2]}` in ownerOverrides) { setNotice('账号专属额度格式无效或重复'); return; }
      ownerOverrides[`${match[1]}:${match[2]}`] = Number(match[3]);
    }
    if (Object.keys(ownerOverrides).length > 100) { setNotice('最多设置 100 个账号'); return; }
    setBusy(true); setNotice('');
    try {
      assertAuthSession(session);
      await productPatch('/admin/ocr/settings', { ownerHourly, globalHourly, ownerOverrides }, session);
      assertAuthSession(session);
      setNotice('配置已保存，重启后仍会保留'); onSaved();
    } catch { setNotice('配置未保存，请检查登录、服务或输入后重试'); }
    finally { setBusy(false); }
  }
  return <form onSubmit={save} className="space-y-4 rounded-xl border border-default-200 p-5" aria-label="OCR 额度配置">
    <h2 className="font-semibold">上传额度</h2>
    <div className="grid gap-4 sm:grid-cols-2">
      <label className="space-y-2 text-sm"><span>默认账号每小时次数（0 为停用）</span><input type="number" min="0" max="200" required className="block w-full rounded-lg border border-default-300 bg-content1 p-3" value={owner} onChange={event => setOwner(event.target.value)} /></label>
      <label className="space-y-2 text-sm"><span>全站每小时次数</span><input type="number" min="1" max="1000" required className="block w-full rounded-lg border border-default-300 bg-content1 p-3" value={global} onChange={event => setGlobal(event.target.value)} /></label>
    </div>
    <label className="block space-y-2 text-sm"><span>账号专属额度（每行一个，最多 100 个）</span><textarea rows={4} className="block w-full rounded-lg border border-default-300 bg-content1 p-3 font-mono" placeholder="user:123=10" value={overrides} onChange={event => setOverrides(event.target.value)} /></label>
    {notice && <p role="status" className="text-sm">{notice}</p>}
    <button disabled={busy} className="rounded-lg bg-primary px-4 py-2 text-white disabled:opacity-50">{busy ? '保存中…' : '保存配置'}</button>
  </form>;
}
