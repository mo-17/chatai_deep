import axios, { AxiosError, AxiosResponse } from 'axios';
import { useAuthStore } from '@/store/authStore';
import { captureAuthSession, assertAuthSession, isAuthSessionCurrent, type AuthSession } from './auth-session';
import type { InternalAxiosRequestConfig } from 'axios';

export type SessionRequest = InternalAxiosRequestConfig & { authSession?: AuthSession; authScoped?: boolean };

interface ApiEnvelope<T = unknown> {
  code: number;
  data: T;
  message?: string;
}

export const api = axios.create({
  baseURL: '/api',
  timeout: 15000,
});

api.interceptors.request.use((config) => {
  const request = config as SessionRequest;
  if (request.authScoped) assertAuthSession(request.authSession!);
  const token = useAuthStore.getState().token;
  if (token && !request.authSession) request.authSession = captureAuthSession();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

api.interceptors.response.use(
  (res: AxiosResponse<ApiEnvelope>) => {
    const config = res.config as SessionRequest;
    if (config.authScoped) assertAuthSession(config.authSession!);
    const body = res.data;
    if (body && typeof body === 'object' && 'code' in body) {
      if (body.code === 0) {
        return { ...res, data: body.data } as AxiosResponse;
      }
      throw new Error(body.message || '请求失败');
    }
    return res;
  },
  (err: AxiosError<{ message?: string }>) => {
    if (err.response?.status === 401) {
      const session = (err.config as SessionRequest | undefined)?.authSession;
      if (session && isAuthSessionCurrent(session)) useAuthStore.getState().logout();
      return Promise.reject(Object.assign(new Error('未登录或登录已过期'), { isAuthError: true }));
    }
    const msg = err.response?.data?.message ?? err.message ?? '网络错误';
    return Promise.reject(new Error(msg));
  },
);

export type ApiResult<T> = AxiosResponse<T>;
