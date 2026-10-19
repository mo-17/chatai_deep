import type { AxiosRequestConfig } from 'axios';
import { api } from './client';
import type { AuthSession } from './auth-session';
export function productGet<T>(path:string,session:AuthSession,params?:Record<string,unknown>):Promise<T> {
  const config={params,authSession:session,authScoped:true} as AxiosRequestConfig;
  return api.get<T>(path,config).then(r=>r.data);
}
export function productPatch<T>(path:string,body:unknown,session:AuthSession):Promise<T> {
  const config={authSession:session,authScoped:true} as AxiosRequestConfig;
  return api.patch<T>(path,body,config).then(r=>r.data);
}
export function productPost<T>(path:string,body:unknown,session:AuthSession):Promise<T> {
  const config={authSession:session,authScoped:true} as AxiosRequestConfig;
  return api.post<T>(path,body,config).then(r=>r.data);
}
export function productDelete(path:string,session:AuthSession):Promise<unknown> {
  const config={authSession:session,authScoped:true} as AxiosRequestConfig;
  return api.delete(path,config);
}
