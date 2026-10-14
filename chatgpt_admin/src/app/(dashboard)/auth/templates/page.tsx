'use client';
import { useEffect, useState } from 'react';
import { fetchTemplates, updateTemplate, TEMPLATE_LABELS, type EmailTemplate, type TemplateKey } from '@/lib/api/auth-admin';
import { AuthAdminBoundary } from '@/lib/auth-admin-boundary';
import { templatePreview, validTemplate } from '@/lib/mail-template-preview';
function TemplatesView() {
  const [rows, setRows] = useState<EmailTemplate[]>([]), [edit, setEdit] = useState<EmailTemplate | null>(null);
  const [busy, setBusy] = useState(false), [notice, setNotice] = useState('');
  useEffect(() => { let live = true; fetchTemplates().then(s => { if (live) setRows(s); }).catch(() => { if (live) setNotice('加载失败，请刷新页面'); }); return () => { live = false; }; }, []);
  const save = async () => {
    if (!edit || busy) return;
    if (!validTemplate(edit.subject, edit.body)) { setNotice('主题不能换行；仅支持 code、purposeLabel、ttlMinutes 三个占位符'); return; }
    setBusy(true); setNotice('');
    try { const t = await updateTemplate(edit.key, { subject: edit.subject, body: edit.body }); setRows(s => [...s.filter(x => x.key !== t.key), t]); setEdit(null); setNotice('模板已保存'); }
    catch { setNotice('保存失败，草稿未生效，可重试或取消'); }
    finally { setBusy(false); }
  };
  return <div className="space-y-4 max-w-4xl"><h1 className="text-xl font-bold">验证码邮件模板</h1><p role="status">{notice}</p>
    <p>未保存的用途使用默认模板。只支持 {'{{code}}、{{purposeLabel}}、{{ttlMinutes}}'}；不执行表达式。</p>
    {(Object.keys(TEMPLATE_LABELS) as TemplateKey[]).map(key => { const t = rows.find(t => t.key === key); return <section key={key} className="flex gap-4 items-center border rounded p-3">
      <b>{TEMPLATE_LABELS[key]}</b><span className="flex-1">{t?.subject || '默认模板'}</span>
      <button className="auth-button" disabled={busy} onClick={() => { setEdit(t || { key, subject: 'ChatAI Deep - {{purposeLabel}}验证码', body: '<p>您正在进行 {{purposeLabel}} 操作。</p><p>验证码：<b>{{code}}</b>，{{ttlMinutes}} 分钟内有效。</p>' }); setNotice(''); }}>编辑 {TEMPLATE_LABELS[key]}模板</button></section>; })}
    {edit && <form className="auth-form space-y-3 border rounded p-4" onSubmit={e => { e.preventDefault(); void save(); }}>
      <h2>编辑 {TEMPLATE_LABELS[edit.key]}模板</h2><fieldset disabled={busy} className="space-y-3">
        <label>邮件主题<input required maxLength={200} value={edit.subject} onChange={e => setEdit({ ...edit, subject: e.target.value })} /></label>
        <label>HTML 正文<textarea required maxLength={65536} rows={10} value={edit.body} onChange={e => setEdit({ ...edit, body: e.target.value })} /></label>
        <p>隔离预览（脚本和外部资源禁用）</p><iframe title="邮件隔离预览" sandbox="" referrerPolicy="no-referrer" className="w-full h-48 border" srcDoc={templatePreview(edit.body, TEMPLATE_LABELS[edit.key])} />
        <button className="auth-button" type="submit">保存模板</button> <button className="auth-button" type="button" onClick={() => { setEdit(null); setNotice('草稿已取消'); }}>取消模板编辑</button>
      </fieldset></form>}
  </div>;
}
export default function AuthTemplatesPage() { return <AuthAdminBoundary><TemplatesView /></AuthAdminBoundary>; }
