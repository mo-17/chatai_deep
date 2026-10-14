'use client';
import { useAuthStore } from '@/store/authStore';
export function AuthAdminBoundary({ children }: { children: React.ReactElement }) {
  const epoch = useAuthStore(s => s.sessionEpoch);
  // 登录/退出/rehydrate 后卸载原草稿与所有原窗口授权状态。
  return <div key={epoch}>{children}</div>;
}
