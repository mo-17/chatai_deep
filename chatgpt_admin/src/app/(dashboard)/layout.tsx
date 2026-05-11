'use client';

import { useAuthStore } from '@/store/authStore';
import { useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';
import { Sidebar } from '@/components/layout/Sidebar';
import { Topbar } from '@/components/layout/Topbar';
import { Spinner } from '@heroui/react';

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const token = useAuthStore((s) => s.token);
  const router = useRouter();
  // Zustand persist 的 hydration 是异步的，使用懒初始化检查是否已完成
  const [hydrated, setHydrated] = useState(() => useAuthStore.persist.hasHydrated());

  useEffect(() => {
    if (hydrated) return;
    const unsub = useAuthStore.persist.onFinishHydration(() => {
      setHydrated(true);
    });
    // 兜底：如果 hydration 未运行（例如 SSR 跳过了），手动触发
    useAuthStore.persist.rehydrate();
    return () => unsub();
  }, [hydrated]);

  useEffect(() => {
    if (hydrated && !token) router.replace('/login');
  }, [hydrated, token, router]);

  // 等待 hydration 完成，避免刷新时 token 尚未恢复就误判为未登录
  if (!hydrated) {
    return (
      <div className="flex h-screen items-center justify-center bg-default-50">
        <Spinner size="lg" />
      </div>
    );
  }

  if (!token) return null;

  return (
    <div className="flex h-screen bg-default-50">
      <Sidebar />
      <div className="flex-1 flex flex-col overflow-hidden">
        <Topbar />
        <main className="flex-1 overflow-auto p-6">{children}</main>
      </div>
    </div>
  );
}
