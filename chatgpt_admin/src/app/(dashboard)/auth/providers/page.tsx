'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { fetchProviders, updateProvider, activateProvider, testProvider, providerDraft, providerPayload, MICROSOFT_CLIENT_ID_PATTERN, MICROSOFT_CLIENT_ID_INVALID, type SmtpProvider, type ProviderDraft } from '@/lib/api/auth-admin';
import { AuthAdminBoundary } from '@/lib/auth-admin-boundary';
import MicrosoftAuthorization from '@/components/auth/MicrosoftAuthorization';
import { SMTP_PRESETS } from '@/lib/smtp-presets';

function ProvidersView() {
  const [rows, setRows] = useState<SmtpProvider[]>([]);
  const [edit, setEdit] = useState<SmtpProvider | null>(null);
  const [draft, setDraft] = useState<ProviderDraft | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [test, setTest] = useState<SmtpProvider | null>(null);
  const [to, setTo] = useState('');
  const [reload, setReload] = useState(0);
  const [rowsCurrent, setRowsCurrent] = useState(false);
  const readVersion = useRef(0);
  const mounted = useRef(false);
  const invalidateReads = useCallback(() => { readVersion.current++; }, []);
  const reconcileProviders = useCallback(async (isCurrent: () => boolean) => {
    if (!mounted.current || !isCurrent()) return;
    const version = ++readVersion.current;
    setRowsCurrent(false);
    try {
      const rows = await fetchProviders();
      if (mounted.current && isCurrent() && version === readVersion.current) {
        setRows(rows); setRowsCurrent(true);
        setNotice(s => s.startsWith('SMTP 卡片状态读取失败') ? '' : s);
      }
    } catch (e) {
      if (mounted.current && isCurrent() && version === readVersion.current) {
        setNotice('SMTP 卡片状态读取失败，请刷新授权状态；当前显示的是上次配置');
        throw e;
      }
    }
  }, []);
  useEffect(() => {
    mounted.current = true;
    let live = true;
    queueMicrotask(() => { if (live) void reconcileProviders(() => live).catch(() => {}); });
    return () => { live = false; mounted.current = false; invalidateReads(); };
  }, [reload, reconcileProviders, invalidateReads]);
  const update = (patch: Partial<ProviderDraft>) => setDraft(d => d && ({ ...d, ...patch }));
  const action = async (work: () => Promise<unknown>, success: string) => {
    if (busy) return;
    setBusy(true); setNotice('');
    try { await work(); setNotice(success); setReload(n => n + 1); }
    catch (e) { setNotice(e instanceof Error ? e.message : '操作失败，请重试'); }
    finally { setBusy(false); }
  };
  const save = async () => {
    if (!edit || !draft || busy) return;
    let frozen: Partial<ProviderDraft>;
    try { frozen = providerPayload(draft); }
    catch (e) { setNotice(e instanceof Error ? e.message : '配置无效，请检查后重试'); return; }
    await action(async () => { await updateProvider(edit.key, frozen); setDraft(null); setEdit(null); }, '配置已保存。OAuth 配置变更后需要重新授权。');
  };
  const preset = (id: string) => {
    const p = SMTP_PRESETS.find(p => p.id === id); if (!p) return;
    update({ host: p.host, port: p.port, secure: p.secure, authMode: p.id === 'outlook' ? 'microsoft_oauth' : 'password' });
  };
  return <div className="space-y-5 max-w-5xl">
    <h1 className="text-xl font-bold">SMTP 服务商管理</h1>
    <p>同时只能启用一个服务商。保存与授权不会发送邮件；测试邮件需单独点击发送。</p>
    <p role="status">{notice}</p>
    <div className="grid md:grid-cols-3 gap-4">{rows.map(p => <section key={p.key} className="rounded-lg border bg-content1 p-4 space-y-3">
      <h2 className="font-semibold">{p.displayName} {rowsCurrent ? p.enabled && '· 已启用' : '· 启用状态待核对'}</h2>
      <p>{p.configured ? `${p.host}:${p.port}` : '未配置'}</p><p>{p.fromName} {p.fromAddress}</p>
      <p>{p.authMode === 'microsoft_oauth' ? 'OAuth2 · STARTTLS' : '密码 SMTP'}</p>
      {p.lastTestedAt && <p>上次测试：{p.lastTestStatus === 'ok' ? '成功' : '失败'} · {new Date(p.lastTestedAt).toLocaleString()}</p>}
      {p.lastTestError && <p>上次测试失败，请检查已保存配置后明确重试。</p>}
      <div className="flex gap-2 flex-wrap">
        <button className="auth-button" disabled={busy} onClick={() => { setEdit(p); setDraft(providerDraft(p)); setTest(null); setNotice(''); }}>编辑 {p.displayName}</button>
        <button className="auth-button" disabled={busy || !rowsCurrent || !p.configured || p.enabled} onClick={() => void action(() => activateProvider(p.key), '已启用服务商')}>启用 {p.displayName}</button>
        <button className="auth-button" disabled={busy || !rowsCurrent || !p.configured} onClick={() => { setTest(p); setTo(p.fromAddress); setDraft(null); setEdit(null); }}>测试 {p.displayName}</button>
      </div>
      {p.key === 'generic' && p.authMode === 'microsoft_oauth' && <MicrosoftAuthorization key={p.configRevision} onProviderRefresh={reconcileProviders} />}
    </section>)}</div>
    {draft && edit && <form className="auth-form space-y-4 rounded-lg border p-4" onSubmit={e => { e.preventDefault(); void save(); }}>
      <h2 className="font-semibold">配置：{edit.displayName}</h2>
      <fieldset disabled={busy} className="space-y-3">
        <label>显示名称<input required maxLength={100} value={draft.displayName} onChange={e => update({ displayName: e.target.value })} /></label>
        {edit.key === 'generic' && <>
          <label>服务商预设<select defaultValue="" onChange={e => preset(e.target.value)}><option value="">请选择（可选）</option>{SMTP_PRESETS.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
          <label>认证方式<select value={draft.authMode} onChange={e => update({ authMode: e.target.value as ProviderDraft['authMode'] })}><option value="password">SMTP 密码</option><option value="microsoft_oauth">个人 Outlook / Hotmail OAuth2</option></select></label>
        </>}
        {draft.authMode === 'password' ? <>
          <label>主机<input required value={draft.host} onChange={e => update({ host: e.target.value })} /></label>
          <label>端口<input required type="number" min={1} max={65535} value={draft.port} onChange={e => update({ port: Number(e.target.value) })} /></label>
          <label><input type="checkbox" checked={draft.secure} onChange={e => update({ secure: e.target.checked })} /> 直接 TLS（通常为 465）</label>
          <label>用户名<input required value={draft.username} onChange={e => update({ username: e.target.value })} /></label>
          <label>SMTP 密码<input type="password" autoComplete="new-password" value={draft.password} onChange={e => update({ password: e.target.value, clearPassword: false })} placeholder={edit.hasPassword ? '已保存；留空保留' : '尚未保存密码'} /></label>
          <label><input type="checkbox" checked={draft.clearPassword} onChange={e => update({ clearPassword: e.target.checked, password: '' })} /> 明确清除已保存密码</label>
        </> : <>
          <p>个人 Outlook 使用固定 smtp-mail.outlook.com:587 STARTTLS 与微软 consumers 授权。企业 Microsoft 365 不适用此个人账号流程。</p>
          <label>Microsoft Client ID<input required pattern={MICROSOFT_CLIENT_ID_PATTERN} title={MICROSOFT_CLIENT_ID_INVALID} aria-describedby="microsoft-client-id-help" value={draft.microsoftClientId} onInvalid={() => setNotice(MICROSOFT_CLIENT_ID_INVALID)} onChange={e => update({ microsoftClientId: e.target.value.trim() })} /></label>
          <p id="microsoft-client-id-help">本后台需要先注册微软应用。填写应用注册页的“应用程序（客户端）ID”（UUID）；发起授权时再登录邮箱账号。</p>
          <label>Microsoft Client Secret<input type="password" autoComplete="new-password" value={draft.microsoftClientSecret} onChange={e => update({ microsoftClientSecret: e.target.value, clearMicrosoftClientSecret: false })} placeholder={edit.hasMicrosoftClientSecret ? '已保存；留空保留' : '尚未保存密钥'} /></label>
          <label><input type="checkbox" checked={draft.clearMicrosoftClientSecret} onChange={e => update({ clearMicrosoftClientSecret: e.target.checked, microsoftClientSecret: '' })} /> 明确清除已保存密钥</label>
          <p>先保存配置，再发起授权。后台需配置与当前站点匹配的 HTTPS 回调地址。</p>
        </>}
        <label>发件人名称<input maxLength={100} value={draft.fromName} onChange={e => update({ fromName: e.target.value })} /></label>
        <label>发件人地址<input required type="email" value={draft.fromAddress} onChange={e => update({ fromAddress: e.target.value })} /></label>
        <p>发件地址由此配置固定；微软账号展示信息不会替换它。</p>
      </fieldset>
      <button className="auth-button" type="submit" disabled={busy}>保存配置</button> <button className="auth-button" type="button" disabled={busy} onClick={() => { setEdit(null); setDraft(null); }}>取消编辑</button>
    </form>}
    {test && <form className="auth-form space-y-3 rounded-lg border p-4" onSubmit={e => { e.preventDefault(); void action(async () => { const r = await testProvider(test.key, to); if (r.status !== 'ok') throw Error(r.error === 'smtp_delivery_unknown' ? '投递结果未知，请勿自动重发' : '测试失败，请检查已保存配置'); setTest(null); }, '测试邮件已发送'); }}>
      <h2>发送一封测试邮件 · {test.displayName}</h2><label>测试收件地址<input required type="email" value={to} onChange={e => setTo(e.target.value)} disabled={busy} /></label>
      <button className="auth-button" type="submit" disabled={busy}>发送测试邮件</button> <button className="auth-button" type="button" disabled={busy} onClick={() => setTest(null)}>取消测试</button>
    </form>}
  </div>;
}
export default function AuthProvidersPage() { return <AuthAdminBoundary><ProvidersView /></AuthAdminBoundary>; }
