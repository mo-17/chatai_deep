'use client';
import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { productGet, productPatch } from '@/lib/api/product-session';
import { captureAuthSession } from '@/lib/api/auth-session';
import { useAuthStore } from '@/store/authStore';
interface Feedback { id:number; userId:number; category:string; content:string; status:string; reply:string; createdAt:string; diagnostics: Record<string,string> }
export default function FeedbackPage() {
  const epoch=useAuthStore(s=>s.sessionEpoch);
  return <FeedbackEditor key={epoch} epoch={epoch}/>;
}
function FeedbackEditor({epoch}:{epoch:number}) {
  const [session]=useState(captureAuthSession);
  const [page,setPage] = useState(1);
  const [edit,setEdit] = useState<Feedback|null>(null);
  const qc = useQueryClient();
  const query = useQuery({queryKey:['feedback',epoch,page],queryFn:()=>productGet<{list:Feedback[];total:number}>('/admin/feedback',session,{page})});
  const save = useMutation({mutationFn:(item:Feedback)=>productPatch(`/admin/feedback/${item.id}`,{status:item.status,reply:item.reply},session),onSuccess:()=>{setEdit(null);qc.invalidateQueries({queryKey:['feedback']});}});
  return <div className="space-y-4"><h1 className="text-xl font-bold">用户反馈</h1>
    {(query.isError||save.isError)&&<p role="alert">{(query.error??save.error)?.message}</p>}
    {query.data?.list.map(item=><article key={item.id} className="rounded-xl border border-default-200 p-4 space-y-3">
      <p>#{item.id} · 用户 {item.userId} · {item.category} · {item.status} · {item.createdAt}</p>
      <p className="whitespace-pre-wrap break-words">{item.content}</p>
      <p className="text-sm text-default-500">{Object.entries(item.diagnostics).map(([k,v])=>`${k}: ${v}`).join(' · ')}</p>
      {item.reply&&<p className="whitespace-pre-wrap">回复：{item.reply}</p>}
      <button className="auth-button" onClick={()=>{save.reset();setEdit(item);}}>处理与回复</button>
    </article>)}
    {query.data?.list.length===0&&<p>暂无反馈</p>}
    <nav aria-label="反馈分页" className="flex items-center gap-3"><button className="auth-button" disabled={page<=1} onClick={()=>setPage(page-1)}>上一页</button><span>第 {page} 页</span><button className="auth-button" disabled={page*20>=(query.data?.total??0)} onClick={()=>setPage(page+1)}>下一页</button></nav>
    {edit&&<section className="auth-form rounded-xl border p-4 space-y-3"><h2>处理 #{edit.id}</h2>
      <label>处理状态<select value={edit.status} onChange={e=>setEdit({...edit,status:e.target.value})}>
        <option value="open">待处理</option><option value="in_progress">处理中</option><option value="resolved">已解决</option><option value="closed">已关闭</option>
      </select></label>
      <label>用户可见回复<textarea value={edit.reply} maxLength={4000} onChange={e=>setEdit({...edit,reply:e.target.value})}/></label>
      <button className="auth-button" onClick={()=>setEdit(null)}>取消</button><button className="auth-button" disabled={save.isPending} onClick={()=>save.mutate(edit)}>保存回复</button>
    </section>}
  </div>;
}
