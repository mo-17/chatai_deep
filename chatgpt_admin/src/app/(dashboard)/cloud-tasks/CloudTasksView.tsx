'use client';

import { useEffect, useSyncExternalStore } from 'react';
import { CloudController } from '../../../lib/cloud-workflow/controller';
import { bytes, CLOUD_DISABLED_NOTICE, CLOUD_ROLES, Role, stateLabel } from '../../../lib/cloud-workflow/model';

const roleName: Record<Role, string> = { analysis: '分析', writing: '撰写', review: '审阅' };
const button = 'min-h-11 px-4 py-2 rounded border border-default-300 disabled:opacity-40 disabled:cursor-not-allowed';
const input = 'w-full rounded border border-default-300 bg-default-50 p-2';
const group = 'rounded-xl border border-default-200 p-4 space-y-3';
/** 生产page与合成页面验证使用同一view及被测controller，不执行模型HTML。 */
export function CloudTasksView({ controller: c }: { controller: CloudController }) {
  const s = useSyncExternalStore(c.subscribe, c.getSnapshot, c.getSnapshot);
  const act = async (action: () => Promise<unknown>, taskRead = false) => {
    let scope = taskRead ? c.noticeScope() : undefined;
    try {
      const pending = action();
      // open在首次await前推进选择代次；异常归属必须绑定这次读取而非上个任务。
      if (taskRead) scope = c.noticeScope();
      await pending;
    } catch (e) { c.report(e, scope); }
  };
  useEffect(() => {
    const visible = () => c.setVisible(document.visibilityState === 'visible');
    const hidden = () => c.setVisible(false);
    visible(); document.addEventListener('visibilitychange', visible);
    window.addEventListener('pagehide', hidden); window.addEventListener('pageshow', visible);
    return () => { document.removeEventListener('visibilitychange', visible); window.removeEventListener('pagehide', hidden); window.removeEventListener('pageshow', visible); hidden(); };
  }, [c]);
  const d = s.draft, p = s.preview, result = c.finalResult;
  return <div className="mx-auto max-w-4xl space-y-5" data-testid="cloud-tasks-view">
    <h1 className="text-2xl font-semibold">我的云任务</h1>
    <p role="note">{CLOUD_DISABLED_NOTICE}</p>
    <p>本页仅管理当前登录身份的云任务。关闭页面只停止观察，不代表远端已停止。</p>
    {s.notice && <p role="status" className="p-3 bg-default-100 rounded">{s.notice}</p>}
    <section className={group}>
      <h2 className="font-semibold">独立任务草稿</h2>
      <fieldset disabled={s.busy || !!p} className="space-y-3">
        <label className="block">本次任务全文<textarea data-testid="cloud-task" className={input} rows={4} value={d.task} onChange={e => c.edit(v => { v.task = e.target.value; })}/></label>
        <p>仅上传本人在本页输入的任务和下列显式文本；不读取聊天、记忆、本地key、路径或附件。</p>
        {d.inputs.map((i, n) => <div key={n} className="space-y-2 border rounded p-3">
          <label className="block">输入标题<input className={input} value={i.title} onChange={e => c.edit(v => { v.inputs[n].title = e.target.value; })}/></label>
          <label className="block">输入全文<textarea className={input} rows={3} value={i.text} onChange={e => c.edit(v => { v.inputs[n].text = e.target.value; })}/></label>
          <button className={button} onClick={() => c.edit(v => { v.inputs.splice(n, 1); })}>移除输入 {n + 1}</button>
        </div>)}
        <button className={button} disabled={d.inputs.length >= 4} onClick={() => c.edit(v => { v.inputs.push({ title: '', text: '' }); })}>添加文本快照（最多4份）</button>
        {CLOUD_ROLES.map(role => <label className="block" key={role}>{roleName[role]}服务端模型
          <select data-testid={`cloud-profile-${role}`} className={input} value={d.profiles[role] ? `${d.profiles[role]!.providerId}:${d.profiles[role]!.modelRowId}` : ''} onChange={e => c.edit(v => { const choice = s.profiles.find(p => `${p.providerId}:${p.modelRowId}` === e.target.value); if (choice) v.profiles[role] = choice; else delete v.profiles[role]; })}>
            <option value="">请明确选择</option>{s.profiles.map(p => <option value={`${p.providerId}:${p.modelRowId}`} key={`${p.providerId}:${p.modelRowId}`}>{p.providerName} · {p.modelName}</option>)}
          </select>
        </label>)}
        {!s.profiles.length && <p>服务端模型清单不可用，不能提交。</p>}
        <div className="grid gap-3 sm:grid-cols-2">
          <label>输出格式<select className={input} value={d.acceptance.format} onChange={e => c.edit(v => { v.acceptance.format = e.target.value as 'txt' | 'md' | 'csv'; v.acceptance.outputName = `result.${e.target.value}`; })}>{['txt', 'md', 'csv'].map(f => <option key={f}>{f}</option>)}</select></label>
          <label>输出名<input className={input} value={d.acceptance.outputName} onChange={e => c.edit(v => { v.acceptance.outputName = e.target.value; })}/></label>
          <label>最少Unicode字符<input type="number" className={input} value={d.acceptance.minChars} onChange={e => c.edit(v => { v.acceptance.minChars = e.target.valueAsNumber; })}/></label>
          <label>最多Unicode字符<input type="number" className={input} value={d.acceptance.maxChars} onChange={e => c.edit(v => { v.acceptance.maxChars = e.target.valueAsNumber; })}/></label>
        </div>
        <label className="block">必含内容（每行一项）<textarea className={input} value={d.requiredTermsText ?? d.acceptance.requiredTerms.join('\n')} onChange={e => c.edit(v => { v.requiredTermsText = e.target.value; })}/></label>
        <label className="block"><input type="checkbox" checked={d.acceptance.requireFullRead} onChange={e => c.edit(v => { v.acceptance.requireFullRead = e.target.checked; })}/> 完整文本快照进入请求（不证明模型认知已阅读）</label>
        <label className="block"><input type="checkbox" checked={d.budget.reworks === 1} onChange={e => c.edit(v => { v.budget.reworks = e.target.checked ? 1 : 0; })}/> 最多一次自动返工</label>
        {([
          ['attempts', '尝试次数', [1, 2, 3, 4, 5, 6, 7, 8]],
          ['estimatedTokens', '累计估算token，非账单硬上限', [8000, 16000, 32000]],
          ['outputTokens', '单次输出token', [512, 1024, 2048]],
          ['durationMs', '本次授权技术上限（分钟，最多10分钟）', [60000, 300000, 600000]],
        ] as const).map(([key, label, values]) => <label className="block" key={key}>{label}<select className={input} value={d.budget[key]} onChange={e => c.edit(v => { v.budget[key] = Number(e.target.value); })}>{values.map(n => <option key={n} value={n}>{key === 'durationMs' ? n / 60000 : n}</option>)}</select></label>)}
        <div className="flex flex-wrap gap-2">
          <button data-testid="cloud-preview" className={button} onClick={() => void act(() => c.prepare())}>预览本次上传</button>
          <button className={button} onClick={() => c.newDraft()}>新任务草稿</button>
        </div>
      </fieldset>
    </section>
    <section className={group}>
      <h2 className="font-semibold">当前身份任务与回执</h2>
      {s.receipts.filter(r => r.status === 'submission_unknown').map(r => <div key={r.key}><p>提交结果未知，查询不会重新发送</p><button className={button} disabled={s.busy} onClick={() => void act(() => c.resolveAndOpen(r))}>按原提交身份查询</button></div>)}
      {s.tasks.map(t => <button className={`${button} block w-full text-left`} key={t.id} onClick={() => void act(() => c.open(t.id), true)}>{stateLabel(t.state)} · 任务 {t.id}</button>)}
      {s.nextCursor && <button className={button} onClick={() => void act(() => c.loadNextPage())}>加载下一页</button>}
      {!s.tasks.length && !s.receipts.length && <p>暂无云任务</p>}
    </section>
    {s.detail && <section className={group} data-testid="cloud-detail">
      <h2 className="font-semibold">{stateLabel(s.detail.state)}</h2>
      {s.detail.steps.map(step => <p key={step.id}>{roleName[step.role]}：{stateLabel(step.state)} · 结果版本 {step.resultVersion}</p>)}
      <p>实际尝试 {s.detail.attemptsUsed}；累计估算 {s.detail.estimatedTokens} token。费用及未提供的实际用量未知。</p>
      {typeof s.detail.payload?.task === 'string' && <details><summary>本次任务全文</summary><pre className="whitespace-pre-wrap break-words">{s.detail.payload.task}</pre></details>}
      {result && <><h3>已通过的最终撰写成果</h3><pre data-testid="cloud-result" className="whitespace-pre-wrap break-words">{result.content}</pre><button className={button} onClick={() => void act(() => c.copyResult(text => navigator.clipboard.writeText(text)))}>明确复制成果</button></>}
      <div className="flex flex-wrap gap-2"><button className={button} onClick={() => void act(() => c.refresh(), true)}>刷新状态</button>
        {!['complete', 'cancelled', 'deleted', 'failed', 'unknown'].includes(s.detail.state) && <button data-testid="cloud-stop" className={button} disabled={s.busy} onClick={() => void act(() => c.stop(s.stopNeedsNewIntent))}>{s.stopNeedsNewIntent ? '按新状态明确停止' : '请求停止'}</button>}
      </div>
      <p>成果保留在此页，不自动写回或覆盖后台AI对话；本页不执行文件/工具。</p>
    </section>}
    {p && <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"><section role="dialog" aria-modal="true" aria-labelledby="cloud-confirm-title" className="max-h-[90vh] w-full max-w-2xl overflow-auto bg-background rounded-xl p-5 space-y-3">
      <h2 id="cloud-confirm-title" className="font-semibold">确认本次上传</h2><p>目的地：{c.api.session.origin}</p><p>费用未知。授权技术上限不超过本次选择、JWT截止及服务器上限。</p>
      <pre className="whitespace-pre-wrap break-words">{p.payload.task}</pre>
      {p.payload.inputs.map((i, n) => <details key={n}><summary>{i.title} · {bytes(i.text)} UTF-8字节</summary><pre className="whitespace-pre-wrap break-words">{i.text}</pre></details>)}
      {CLOUD_ROLES.map(r => <p key={r}>{roleName[r]}：{p.profiles[r].providerName} · {p.profiles[r].modelName}</p>)}
      <p>验收 {p.payload.acceptance.format} / {p.payload.acceptance.outputName}；{p.payload.acceptance.minChars}–{p.payload.acceptance.maxChars} Unicode字符；必含内容 {p.payload.acceptance.requiredTerms.join('、') || '无'}。</p>
      <p>完整快照进入请求：{String(p.payload.acceptance.requireFullRead)}，不代表模型认知已阅读。</p>
      <p>最多 {p.payload.budget.attempts} 次尝试 / 累计估算 {p.payload.budget.estimatedTokens} token（非账单硬上限）/ 单次输出 {p.payload.budget.outputTokens} token / 授权技术上限 {p.payload.grantDurationMs / 60000} 分钟 / 最多 {p.payload.budget.reworks} 次返工。</p>
      <p>{CLOUD_DISABLED_NOTICE}</p><div className="flex gap-2"><button className={button} disabled={s.busy} onClick={() => c.cancelPreview()}>取消</button><button data-testid="cloud-confirm" className={button} disabled={!c.canCreate || s.busy} onClick={() => void act(() => c.confirm(p))}>确认并提交</button></div>
    </section></div>}
  </div>;
}
