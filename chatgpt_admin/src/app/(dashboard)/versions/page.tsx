'use client';
import { useEffect, useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useForm, useWatch } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { versionSchema, type VersionForm } from '@/schemas/version';
import { fmtDate } from '@/lib/utils/format';
import { productGet, productPost, productPatch, productDelete } from '@/lib/api/product-session';
import { captureAuthSession } from '@/lib/api/auth-session';
import { useAuthStore } from '@/store/authStore';
import type { AppVersion } from '@/types/entities';
import type { Paged } from '@/types/api';

export default function VersionsPage() {
  const epoch=useAuthStore(s=>s.sessionEpoch);
  return <VersionsEditor key={epoch} epoch={epoch}/>;
}
function VersionsEditor({epoch}:{epoch:number}) {
  const [session]=useState(captureAuthSession);
  const qc=useQueryClient();
  const [page,setPage]=useState(1);
  const [editId,setEditId]=useState<number|null>(null);
  const [importError,setImportError]=useState('');
  const form=useForm({resolver:zodResolver(versionSchema)});
  const artifacts=useWatch({control:form.control,name:'artifacts'});
  const query=useQuery({queryKey:['versions',epoch,page],queryFn:()=>productGet<Paged<AppVersion>>('/admin/versions',session,{page,pageSize:10})});
  const detail=useQuery({queryKey:['version',epoch,editId],enabled:editId!==null&&editId>0,queryFn:()=>productGet<AppVersion>(`/admin/versions/${editId}`,session)});
  useEffect(()=>{
    if(!detail.data||editId===null||editId<0)return;
    form.reset({...detail.data,url:detail.data.url??'',sha256:detail.data.sha256??'',description:detail.data.description??'',rolloutPercent:detail.data.rolloutPercent??100,rolloutSalt:detail.data.rolloutSalt??'',artifacts:detail.data.artifacts??{}});
  },[detail.data,editId,form]);
  const invalidate=()=>qc.invalidateQueries({queryKey:['versions']});
  const save=useMutation({mutationFn:(body:VersionForm)=>editId===-1?productPost('/admin/versions',body,session):productPatch(`/admin/versions/${editId}`,body,session),onSuccess:()=>{invalidate();setEditId(null);form.reset();}});
  const pause=useMutation({mutationFn:(id:number)=>productPatch(`/admin/versions/${id}`,{rolloutPercent:0},session),onSuccess:invalidate});
  const remove=useMutation({mutationFn:(id:number)=>productDelete(`/admin/versions/${id}`,session),onSuccess:invalidate});
  function create() {
    form.reset({versionName:'',versionCode:0,url:'',sha256:'',description:'',cid:'321',forceUpdate:false,enabled:true,rolloutPercent:0,rolloutSalt:'',artifacts:{}});
    save.reset();setEditId(-1);
  }
  const error=query.error??detail.error??save.error??pause.error??remove.error;
  return <div className="space-y-4"><div className="flex items-center justify-between"><h1 className="text-xl font-bold">版本管理</h1><button className="auth-button" onClick={create}>新建版本</button></div>
    <p>新发布默认暂停推送。灰度按安装标识稳定分组；旧客户端仅接收 100% 全量版本。</p>
    <label className="block text-sm">导入构建脚本生成的 release.json<input aria-label="导入发布元数据" type="file" accept="application/json,.json" onChange={async event=>{
      const input=event.currentTarget;
      try {const file=input.files?.[0];if(!file)return;if(file.size>65536)throw Error('too large');const body=versionSchema.parse(JSON.parse(await file.text()));form.reset({...body,rolloutPercent:0});setEditId(-1);setImportError('');}
      catch{setImportError('元数据无效，请使用 release-manifest.py 生成的文件');}finally{input.value='';}
    }}/></label>
    {(error||importError)&&<p role="alert">{importError||error?.message}</p>}
    <div className="overflow-x-auto"><table className="w-full text-left text-sm"><caption className="sr-only">版本列表</caption><thead><tr>{['版本','渠道','推送','创建时间','操作'].map(t=><th key={t} className="border-b p-3">{t}</th>)}</tr></thead><tbody>
      {query.data?.list.map(v=><tr key={v.id}><td className="border-b p-3">{v.versionName}（{v.versionCode}）{v.forceUpdate?' · 强制':''}</td><td className="border-b p-3">{v.cid}</td><td className="border-b p-3">{v.enabled?`${v.rolloutPercent??100}%`:'禁用'}</td><td className="border-b p-3">{fmtDate(v.createTime)}</td><td className="border-b p-3"><div className="flex gap-2"><button className="auth-button" onClick={()=>{save.reset();setEditId(v.id);}}>编辑</button><button className="auth-button" disabled={pause.isPending} onClick={()=>pause.mutate(v.id)}>暂停推送</button><button className="auth-button" disabled={remove.isPending} onClick={()=>{if(window.confirm('确认删除此版本记录？已下载的安装包不会被删除。'))remove.mutate(v.id);}}>删除</button></div></td></tr>)}
    </tbody></table></div>
    {query.data?.total===0&&<p>暂无版本</p>}
    <nav aria-label="版本分页" className="flex gap-3 items-center"><button className="auth-button" disabled={page<=1} onClick={()=>setPage(page-1)}>上一页</button><span>第 {page} 页</span><button className="auth-button" disabled={page*10>=(query.data?.total??0)} onClick={()=>setPage(page+1)}>下一页</button></nav>
    {editId!==null&&<form className="auth-form max-w-2xl space-y-3 rounded-xl border p-5" onSubmit={form.handleSubmit(body=>save.mutate(body))}>
      <h2 className="font-bold">{editId<0?'新建版本':'编辑版本'}</h2>
      <label>版本名（如 1.0.6）<input {...form.register('versionName')}/></label>
      <label>版本码（正整数）<input type="number" min="1" {...form.register('versionCode',{valueAsNumber:true})}/></label>
      <label>通用 APK 下载 URL<input {...form.register('url')}/></label>
      <label>APK SHA-256（direct 新发布必填）<input {...form.register('sha256')}/></label>
      <label>更新说明<textarea {...form.register('description')}/></label>
      <label>渠道<input {...form.register('cid')}/></label>
      <label><input type="checkbox" {...form.register('forceUpdate')}/>强制更新</label>
      <label><input type="checkbox" {...form.register('enabled')}/>启用记录</label>
      <label>灰度比例（0 暂停 / 100 全量）<input type="number" min="0" max="100" {...form.register('rolloutPercent',{valueAsNumber:true})}/></label>
      <label>灰度批次（保持不变可稳定覆盖同一批用户）<input {...form.register('rolloutSalt')}/></label>
      <p>架构安装包：{Object.keys(artifacts??{}).join('、')||'使用通用安装包'}（通过元数据导入）</p>
      {Object.entries(form.formState.errors).map(([key,value])=><p role="alert" key={key}>{String(value?.message??'配置无效')}</p>)}
      <div className="flex gap-3"><button className="auth-button" type="button" onClick={()=>setEditId(null)}>取消</button><button className="auth-button" type="submit" disabled={save.isPending}>{save.isPending?'保存中…':'保存版本'}</button></div>
    </form>}
  </div>;
}
