'use client';

import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { productGet } from '@/lib/api/product-session';
import { captureAuthSession } from '@/lib/api/auth-session';
import { useAuthStore } from '@/store/authStore';

interface Snapshot {
  sampledAt: string; uptimeSeconds: number;
  database: { ok: boolean; latencyMs: number };
  memory: { rssBytes: number; heapUsedBytes: number; heapTotalBytes: number };
  budget: { requests: number; tokens: number; active: number; tokenLimit: number; requestLimit: number; concurrencyLimit: number; limitsEnabled: boolean; trialEnabled: boolean };
  http: Array<{ group: string; requests: number; serverErrors: number; rejected: number; aborted: number; averageMs: number; maxMs: number }>;
  alerts: Array<{ code: string; message: string }>;
  countingRule: string;
}
const names: Record<string, string> = { auth: '登录与认证', chat: '聊天', sync: '云同步', update: '更新检查', admin: '管理接口', other: '其它' };
const mib = (bytes: number) => `${(bytes / 1048576).toFixed(1)} MiB`;

export default function OperationsPage() {
  const epoch = useAuthStore(s => s.sessionEpoch);
  return <OperationsView key={epoch} epoch={epoch} />;
}
function OperationsView({ epoch }: { epoch: number }) {
  const [session] = useState(captureAuthSession);
  const [auto, setAuto] = useState(true);
  const query = useQuery({ queryKey: ['operations', epoch], queryFn: () => productGet<Snapshot>('/admin/operations', session), refetchInterval: auto ? 30000 : false, retry: false });
  const data = query.data;
  return <div className="space-y-6 min-w-0" aria-label="运行监控">
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div><h1 className="text-2xl font-bold">运行监控</h1><p className="text-sm text-default-500 mt-1">服务健康、今日预算与最近一小时的 HTTP 请求统计</p></div>
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <label className="flex items-center gap-2"><input type="checkbox" checked={auto} onChange={e => setAuto(e.target.checked)} />每 30 秒刷新</label>
        <button className="auth-button" disabled={query.isFetching} onClick={() => void query.refetch()}>{query.isFetching ? '读取中…' : '刷新状态'}</button>
      </div>
    </div>
    {query.isError && <p role="alert" className="rounded-xl bg-danger-50 text-danger p-4">状态读取失败，请检查网络、登录状态或 API 服务。{data && ' 下方为上次成功读取的数据。'}</p>}
    {query.isPending && <p role="status">正在读取服务状态…</p>}
    {data && <>
      <p className="text-xs text-default-500">采样时间：{new Date(data.sampledAt).toLocaleString()} · 页面中的警告不会自动发送邮件</p>
      <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">
        <Stat title="数据库" value={data.database.ok ? `正常 · ${data.database.latencyMs} ms` : '异常'} />
        <Stat title="API 已运行" value={`${Math.floor(data.uptimeSeconds / 3600)} 小时 ${Math.floor(data.uptimeSeconds % 3600 / 60)} 分钟`} />
        <Stat title="API 进程内存 RSS" value={mib(data.memory.rssBytes)} />
        <Stat title="JS 堆已用 / 已分配" value={`${mib(data.memory.heapUsedBytes)} / ${mib(data.memory.heapTotalBytes)}`} />
      </div>
      <section className="rounded-xl border border-default-200 p-5 space-y-3" aria-label="今日预算">
        <h2 className="font-semibold">今日全站预算（含预留）</h2>
        <p>官方试用{data.budget.trialEnabled ? '已开放' : '未开放'} · 服务端额度{data.budget.limitsEnabled ? '已启用' : '未启用'}</p>
        <p>Token：{data.budget.tokens.toLocaleString()} / {data.budget.tokenLimit.toLocaleString()} · 请求：{data.budget.requests} / {data.budget.requestLimit} · 进行中：{data.budget.active} / {data.budget.concurrencyLimit}</p>
        {data.alerts.length ? data.alerts.map(alert => <p key={alert.code} role="alert" className="rounded-lg bg-warning-50 text-warning-800 p-3">{alert.message}</p>) : <p className="text-success-700">当前没有达到警告阈值的项目</p>}
      </section>
      <section className="min-w-0 space-y-3"><h2 className="font-semibold">HTTP 请求</h2>
        <div className="overflow-x-auto rounded-xl border border-default-200"><table className="w-full text-sm whitespace-nowrap"><thead className="bg-default-100"><tr>{['接口类别', '请求', 'HTTP 5xx', '401/403/429', '中断连接', '平均 / 最长耗时'].map(label => <th key={label} className="p-3 text-left">{label}</th>)}</tr></thead>
          <tbody>{data.http.map(row => <tr key={row.group} className="border-t border-default-200"><td className="p-3">{names[row.group] ?? row.group}</td><td className="p-3">{row.requests}</td><td className="p-3">{row.serverErrors}</td><td className="p-3">{row.rejected}</td><td className="p-3">{row.aborted}</td><td className="p-3">{row.averageMs} / {row.maxMs} ms</td></tr>)}</tbody></table></div>
        <p className="text-sm text-default-500 leading-relaxed">{data.countingRule}</p>
        <p className="text-sm text-default-500">仅统计固定接口类别；不采集聊天内容、Key、密码、邮箱或 IP。内存为 API 进程数据，不是整台服务器内存。</p>
      </section>
    </>}
  </div>;
}
function Stat({ title, value }: { title: string; value: string }) {
  return <section className="rounded-xl border border-default-200 bg-content1 p-5"><h2 className="text-sm text-default-500">{title}</h2><p className="mt-3 font-semibold break-words">{value}</p></section>;
}
