'use client';
import { useEffect, useState } from 'react';
import { fetchAuthSettings, updateAuthSettings, type AuthSettings } from '@/lib/api/auth-admin';
import { AuthAdminBoundary } from '@/lib/auth-admin-boundary';
const NUMBER_FIELDS = [
  ['codeTtlSeconds', '验证码有效期（秒）', 60, 1800], ['codeMaxAttempts', '最大重试次数', 1, 10],
  ['codeDailyLimitPerIdentifier', '每个标识当日最大发送量（UTC）', 1, 100],
  ['codeResendIntervalSeconds', '重发间隔（秒）', 30, 600], ['codeHourlyLimitPerIp', '单 IP 每小时上限', 1, 100],
] as const;
function SettingsView() {
  const [saved, setSaved] = useState<AuthSettings | null>(null), [draft, setDraft] = useState<AuthSettings | null>(null);
  const [busy, setBusy] = useState(false), [notice, setNotice] = useState('');
  useEffect(() => { let live = true; fetchAuthSettings().then(s => { if (live) { setSaved(s); setDraft(s); } }).catch(() => { if (live) setNotice('加载失败，请刷新页面'); }); return () => { live = false; }; }, []);
  const change = (p: Partial<AuthSettings>) => setDraft(s => s && ({ ...s, ...p }));
  const save = async () => {
    if (!draft || busy) return;
    setBusy(true); setNotice('');
    try { const s = await updateAuthSettings(draft); setSaved(s); setDraft(s); setNotice('策略已保存'); }
    catch { setNotice('保存失败，草稿未生效；可以重试或恢复已保存值'); }
    finally { setBusy(false); }
  };
  return <form className="auth-form max-w-2xl space-y-5" onSubmit={e => { e.preventDefault(); void save(); }}>
    <h1 className="text-xl font-bold">认证策略设置</h1><p role="status">{notice}</p>
    {draft && <fieldset disabled={busy} className="space-y-3">
      <h2 className="font-semibold">第三方账号</h2>
      <label><input type="checkbox" checked={draft.huaweiGetAuthCodeEnabled} onChange={e => change({ huaweiGetAuthCodeEnabled: e.target.checked })} /> 华为 Authorization Code 登录</label>
      <label><input type="checkbox" checked={draft.huaweiQuickLoginEnabled} onChange={e => change({ huaweiQuickLoginEnabled: e.target.checked })} /> 华为一键登录</label>
      <label>华为主流程<select value={draft.huaweiPrimaryFlow} onChange={e => change({ huaweiPrimaryFlow: e.target.value as AuthSettings['huaweiPrimaryFlow'] })}><option value="getAuthCode">getAuthCode</option><option value="quickLogin">quickLogin</option></select></label>
      <label><input type="checkbox" checked={draft.appleSignInEnabled} onChange={e => change({ appleSignInEnabled: e.target.checked })} /> Sign in with Apple</label>
      <h2 className="font-semibold">验证码策略</h2>
      {NUMBER_FIELDS.map(([key, label, min, max]) => <label key={key}>{label}<input type="number" required min={min} max={max} step={1} value={Number.isNaN(draft[key]) ? '' : draft[key]} onChange={e => change({ [key]: e.target.value === '' ? NaN : Number(e.target.value) })} /></label>)}
      <label><input type="checkbox" checked={draft.smsMockHighlight} onChange={e => change({ smsMockHighlight: e.target.checked })} /> SMS Mock 高亮</label>
      <button className="auth-button" type="submit">保存策略</button> <button className="auth-button" type="button" onClick={() => { setDraft(saved); setNotice('已恢复保存值'); }}>恢复已保存值</button>
    </fieldset>}
  </form>;
}
export default function AuthSettingsPage() { return <AuthAdminBoundary><SettingsView /></AuthAdminBoundary>; }
