'use client';

import { usePathname } from 'next/navigation';
import { useAuthStore } from '@/store/authStore';
import { User } from 'lucide-react';

const breadcrumbMap: Record<string, string> = {
  dashboard: 'Dashboard',
  users: '用户管理',
  banners: 'Banner 管理',
  versions: '版本管理',
  usage: '用量明细',
  settings: '设置',
};

export function Topbar() {
  const pathname = usePathname();
  const admin = useAuthStore((s) => s.admin);

  const segments = pathname.split('/').filter(Boolean);
  let label = 'Dashboard';
  for (const seg of segments) {
    if (breadcrumbMap[seg]) {
      label = breadcrumbMap[seg];
      break;
    }
  }

  return (
    <header className="h-14 border-b border-default-200 flex items-center justify-between px-6 bg-default-50">
      <span className="text-sm text-default-600">/ {label}</span>
      <div className="flex items-center gap-2 text-sm text-default-700">
        <User size={16} />
        <span>{admin?.userName}</span>
      </div>
    </header>
  );
}
