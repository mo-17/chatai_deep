'use client';
import { useEffect, useState } from 'react';
import { fetchCodes, type CodeRecord } from '@/lib/api/auth-admin';
import { AuthAdminBoundary } from '@/lib/auth-admin-boundary';
import { codeState } from '@/lib/auth-code-state';
const DELIVERY = { legacy: '历史记录，投递未确认', pending: '发送中', sent: '已发送', failed: '发送失败', unknown: '投递未知' };
const PURPOSE: Record<string, string> = { login: '登录', register: '注册', bind: '绑定', reset_password: '重置密码' };
function CodesView() {
  const [items, setItems] = useState<CodeRecord[]>([]), [total, setTotal] = useState(0), [notice, setNotice] = useState('');
  const [page, setPage] = useState(1), [channel, setChannel] = useState(''), [purpose, setPurpose] = useState('');
  useEffect(() => {
    let live = true;
    fetchCodes({ page, pageSize: 20, channel: channel || undefined, purpose: purpose || undefined }).then(r => { if (live) { setItems(r.items); setTotal(r.total); } }).catch(() => { if (live) setNotice('加载失败，请刷新页面'); });
    return () => { live = false; };
  }, [page, channel, purpose]);
  return <div className="space-y-4"><h1 className="text-xl font-bold">验证码记录</h1><p role="status">{notice}</p>
    <div className="auth-form flex gap-3"><label>通道<select value={channel} onChange={e => { setChannel(e.target.value); setPage(1); }}><option value="">全部</option><option value="email">邮箱</option><option value="sms">短信</option></select></label>
    <label>用途<select value={purpose} onChange={e => { setPurpose(e.target.value); setPage(1); }}><option value="">全部</option>{Object.entries(PURPOSE).map(([key, label]) => <option key={key} value={key}>{label}</option>)}</select></label></div>
    <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr>{['通道','标识','用途','尝试次数','IP','投递状态','验证码状态','创建时间'].map(t => <th className="text-left p-2" key={t}>{t}</th>)}</tr></thead>
    <tbody>{items.map(r => <tr key={r.id}><td className="p-2">{r.channel}</td><td>{r.identifier}</td><td>{PURPOSE[r.purpose] || r.purpose}</td><td>{r.attempts}</td><td>{r.ipAddress}</td><td>{DELIVERY[r.deliveryStatus]}</td><td>{codeState(r)}</td><td>{new Date(r.createdAt).toLocaleString()}</td></tr>)}</tbody></table></div>
    <p>共 {total} 条 · 第 {page} 页</p><button className="auth-button" disabled={page <= 1} onClick={() => setPage(p => p - 1)}>上一页</button> <button className="auth-button" disabled={page * 20 >= total} onClick={() => setPage(p => p + 1)}>下一页</button>
  </div>;
}
export default function AuthCodesPage() { return <AuthAdminBoundary><CodesView /></AuthAdminBoundary>; }
