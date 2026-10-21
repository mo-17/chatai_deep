'use client';

import { usePathname } from 'next/navigation';
import { useAuthStore } from '@/store/authStore';
import { User } from 'lucide-react';

const breadcrumbMap: Record<string, string> = {
  '/dashboard': 'Dashboard',
  '/operations': '运行监控',
  '/users': '用户管理',
  '/banners': 'Banner 管理',
  '/versions': '版本管理',
  '/access': '试用与额度',
  '/feedback': '用户反馈',
  '/usage': '用量明细',
  '/ocr': 'OCR 管理',
  '/ai-chat': 'AI 对话',
  '/cloud-tasks': '我的云任务',
  '/ai/providers': 'AI 服务商',
  '/ai/models': 'AI 模型',
  '/ai/global': 'AI 全局配置',
  '/mcp': 'MCP 服务',
  '/auth/providers': 'SMTP 服务商',
  '/auth/codes': '验证码记录',
  '/auth/settings': '认证策略',
  '/auth/templates': '邮件模板',
};

export function Topbar() {
  const pathname = usePathname();
  const admin = useAuthStore((s) => s.admin);

  const label = breadcrumbMap[pathname] ?? '管理控制台';

  return (
    <header className="h-14 shrink-0 border-b border-default-200 flex items-center justify-between px-6 bg-default-50">
      <span className="text-sm text-default-600">/ {label}</span>
      <div className="flex items-center gap-2 text-sm text-default-700">
        <User size={16} />
        <span>{admin?.userName}</span>
      </div>
    </header>
  );
}
