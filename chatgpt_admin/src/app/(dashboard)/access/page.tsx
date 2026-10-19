'use client';
import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { productGet, productPatch } from '@/lib/api/product-session';
import { captureAuthSession } from '@/lib/api/auth-session';
import { useAuthStore } from '@/store/authStore';
interface Policy {
  id: number; limitsEnabled: boolean; trialEnabled: boolean; trialProviderCode: string; trialModel: string;
  dailyRequests: number; dailyTokens: number; globalDailyTokens: number; globalDailyRequests: number; maxConcurrent: number; maxOutputTokens: number;
  requireVerifiedEmail: boolean; requestsPerMinute: number; globalMaxConcurrent: number;
}
export default function AccessPage() {
  const epoch=useAuthStore(s=>s.sessionEpoch);
  return <AccessEditor key={epoch} epoch={epoch}/>;
}
function AccessEditor({epoch}:{epoch:number}) {
  const [session]=useState(captureAuthSession);
  const qc = useQueryClient();
  const [draft, setDraft] = useState<Policy | null>(null);
  const query = useQuery({ queryKey: ['access-policy',epoch], queryFn: () => productGet<Policy>('/admin/access-policy',session) });
  const data = draft ?? query.data;
  const save = useMutation({ mutationFn: (value: Policy) => productPatch<Policy>('/admin/access-policy', value,session), onSuccess: () => { setDraft(null); qc.invalidateQueries({queryKey:['access-policy']}); } });
  const change = (key: keyof Policy, value: unknown) => data && setDraft({...data, [key]:value});
  return <div className="auth-form max-w-2xl space-y-4"><h1 className="text-xl font-bold">官方试用与额度</h1>
    <p>每日 UTC 0 点重置，输入、输出与思考 Token 均计入。请求先预留额度，收到 usage 后结算；中断或无回执保留预留。预算模式暂支持纯文本。</p>
    {(query.isError || save.isError) && <p role="alert">{(query.error ?? save.error)?.message}</p>}
    {data && <>
      <label><input type="checkbox" checked={data.limitsEnabled} onChange={e=>change('limitsEnabled',e.target.checked)}/>启用服务端额度</label>
      <label><input type="checkbox" checked={data.trialEnabled} onChange={e=>change('trialEnabled',e.target.checked)}/>开放官方试用</label>
      <label><input type="checkbox" checked={data.requireVerifiedEmail} onChange={e=>change('requireVerifiedEmail',e.target.checked)}/>官方服务要求已验证邮箱（管理员除外）</label>
      <p className="text-sm text-default-500">邮箱资格在试用开放时覆盖普通用户所有后端推理请求，避免通过直接提交模型 ID 绕过。邮箱验证码发送仍受 IP、每日次数与冷却间隔保护。</p>
      <label>服务商 code<input value={data.trialProviderCode} onChange={e=>change('trialProviderCode',e.target.value)}/><span>先在服务商页面配置 Key；此处不保存 Key</span></label>
      <label>模型 ID<input value={data.trialModel} onChange={e=>change('trialModel',e.target.value)}/><span>V4.1 Flash 使用 deepseek-flash，需在模型管理中启用</span></label>
      {([['dailyTokens','每人每日 Token'],['globalDailyTokens','全站每日 Token 上限'],['dailyRequests','每人每日请求上限'],['globalDailyRequests','全站每日请求上限'],['requestsPerMinute','每人每分钟请求上限'],['maxConcurrent','每人最大并发'],['globalMaxConcurrent','全站最大并发'],['maxOutputTokens','单次最大输出 Token']] as const).map(([key,label]) => <label key={key}>{label}<input type="number" min="1" value={String(data[key])} onChange={e=>change(key,Number(e.target.value))}/></label>)}
      <button className="auth-button" disabled={save.isPending} onClick={()=>save.mutate(data)}>{save.isPending?'保存中…':'保存政策'}</button>
      {save.isSuccess && <p role="status">已保存。真实推理和邮件投递需要分别验收。</p>}
    </>}
  </div>;
}
