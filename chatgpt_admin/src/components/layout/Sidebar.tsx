'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useUiStore } from '@/store/uiStore';
import { useAuthStore } from '@/store/authStore';
import {
  LayoutDashboard,
  Users,
  Image,
  Smartphone,
  BarChart3,
  ChevronLeft,
  LogOut,
  Server,
  Boxes,
  Settings2,
  Plug,
  MessageCircle,
  Mail,
  KeyRound,
  FileText,
  Lock,
  Cloud,
} from 'lucide-react';
import { clsx } from 'clsx';

const menuItems = [
  { href: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { href: '/operations', label: '运行监控', icon: BarChart3 },
  { href: '/users', label: '用户管理', icon: Users },
  { href: '/banners', label: 'Banner', icon: Image },
  { href: '/versions', label: '版本管理', icon: Smartphone },
  { href: '/access', label: '试用与额度', icon: Settings2 },
  { href: '/feedback', label: '用户反馈', icon: MessageCircle },
  { href: '/usage', label: '用量明细', icon: BarChart3 },
  { href: '/ocr', label: 'OCR 管理', icon: FileText },
  { href: '/ai-chat', label: 'AI 对话', icon: MessageCircle },
  { href: '/cloud-tasks', label: '我的云任务', icon: Cloud },
];

const aiMenuItems = [
  { href: '/ai/providers', label: '服务商', icon: Server },
  { href: '/ai/models', label: '模型', icon: Boxes },
  { href: '/ai/global', label: '全局配置', icon: Settings2 },
  { href: '/mcp', label: 'MCP 服务', icon: Plug },
];

const authMenuItems = [
  { href: '/auth/providers', label: 'SMTP 服务商', icon: Mail },
  { href: '/auth/codes', label: '验证码记录', icon: KeyRound },
  { href: '/auth/settings', label: '认证策略', icon: Lock },
  { href: '/auth/templates', label: '邮件模板', icon: FileText },
];

export function Sidebar() {
  const pathname = usePathname();
  const collapsed = useUiStore((s) => s.sidebarCollapsed);
  const toggle = useUiStore((s) => s.toggleSidebar);
  const admin = useAuthStore((s) => s.admin);
  const logout = useAuthStore((s) => s.logout);

  return (
    <aside
      className={clsx(
        'flex h-full min-h-0 shrink-0 flex-col bg-default-100 border-r border-default-200 transition-all duration-200',
        collapsed ? 'w-16' : 'w-56',
      )}
    >
      <div className="flex shrink-0 items-center h-14 px-3 border-b border-default-200">
        {!collapsed && (
          <span className="font-bold text-lg text-primary">ChatGPT Admin</span>
        )}
        <button
          onClick={toggle}
          className={clsx(
            'p-1 rounded hover:bg-default-200 transition-transform',
            collapsed && 'mx-auto rotate-180',
          )}
        >
          <ChevronLeft size={18} />
        </button>
      </div>

      <nav className="min-h-0 flex-1 overflow-y-auto overscroll-contain py-2">
        {menuItems.map((item) => {
          const active = pathname.startsWith(item.href);
          return (
            <Link
              key={item.href}
              href={item.href}
              className={clsx(
                'flex items-center gap-3 px-3 py-2.5 mx-2 rounded-lg text-sm transition-colors',
                active
                  ? 'bg-primary text-white'
                  : 'text-default-700 hover:bg-default-200',
              )}
            >
              <item.icon size={18} />
              {!collapsed && <span>{item.label}</span>}
            </Link>
          );
        })}

        {!collapsed && (
          <div className="px-3 pt-3 pb-1 text-xs font-semibold text-default-400 uppercase tracking-wide">
            AI 配置
          </div>
        )}
        {collapsed && <div className="border-t border-default-200 mx-2 my-2" />}
        {aiMenuItems.map((item) => {
          const active = pathname.startsWith(item.href);
          return (
            <Link
              key={item.href}
              href={item.href}
              className={clsx(
                'flex items-center gap-3 px-3 py-2.5 mx-2 rounded-lg text-sm transition-colors',
                active
                  ? 'bg-primary text-white'
                  : 'text-default-700 hover:bg-default-200',
              )}
            >
              <item.icon size={18} />
              {!collapsed && <span>{item.label}</span>}
            </Link>
          );
        })}

        {!collapsed && (
          <div className="px-3 pt-3 pb-1 text-xs font-semibold text-default-400 uppercase tracking-wide">
            认证管理
          </div>
        )}
        {collapsed && <div className="border-t border-default-200 mx-2 my-2" />}
        {authMenuItems.map((item) => {
          const active = pathname.startsWith(item.href);
          return (
            <Link
              key={item.href}
              href={item.href}
              className={clsx(
                'flex items-center gap-3 px-3 py-2.5 mx-2 rounded-lg text-sm transition-colors',
                active
                  ? 'bg-primary text-white'
                  : 'text-default-700 hover:bg-default-200',
              )}
            >
              <item.icon size={18} />
              {!collapsed && <span>{item.label}</span>}
            </Link>
          );
        })}
      </nav>

      <div className="shrink-0 border-t border-default-200 p-3">
        {!collapsed && (
          <div className="text-sm text-default-600 mb-2">
            {admin?.userName}
          </div>
        )}
        <button
          onClick={logout}
          className="flex items-center gap-2 text-sm text-danger hover:underline w-full"
        >
          <LogOut size={16} />
          {!collapsed && '退出登录'}
        </button>
      </div>
    </aside>
  );
}
