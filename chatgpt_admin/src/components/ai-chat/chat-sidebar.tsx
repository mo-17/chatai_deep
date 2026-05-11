'use client';

import React from 'react';
import {
  Avatar,
  Button,
  ScrollShadow,
  Spacer,
  cn,
} from '@heroui/react';
import {
  MessageCircle,
  Plus,
  Info,
  History,
  Settings,
  Trash2,
  Pencil,
  Ellipsis,
  ChevronDown,
} from 'lucide-react';

export interface Conversation {
  id: string;
  title: string;
  updatedAt: number;
}

interface ChatSidebarProps {
  conversations: Conversation[];
  activeId: string | null;
  onSelect: (id: string) => void;
  onNew: () => void;
  onDelete: (id: string) => void;
  onRename: (id: string, title: string) => void;
  user?: { name: string; avatar?: string } | null;
}

export default function ChatSidebar({
  conversations,
  activeId,
  onSelect,
  onNew,
  onDelete,
  onRename,
  user,
}: ChatSidebarProps) {
  const [renamingId, setRenamingId] = React.useState<string | null>(null);
  const [renameValue, setRenameValue] = React.useState('');
  const [menuOpen, setMenuOpen] = React.useState<string | null>(null);

  const sorted = [...conversations].sort((a, b) => b.updatedAt - a.updatedAt);

  return (
    <div className="relative flex h-full w-72 flex-1 flex-col p-6">
      {/* Brand */}
      <div className="flex items-center gap-2 px-2">
        <div className="bg-foreground flex h-8 w-8 items-center justify-center rounded-full">
          <MessageCircle className="text-background" size={18} />
        </div>
        <span className="text-foreground text-base leading-6 font-bold uppercase">
          AI Chat
        </span>
      </div>

      <Spacer y={8} />

      {/* User info */}
      {user && (
        <div className="flex items-center gap-3 px-2 py-3 border-b border-divider mb-4">
          <Avatar
            size="sm"
            name={user.name?.charAt(0)?.toUpperCase()}
            src={user.avatar || undefined}
            className="bg-primary text-white shrink-0"
          />
          <div className="flex flex-col min-w-0">
            <p className="text-small text-foreground leading-5 font-semibold truncate">
              {user.name}
            </p>
          </div>
        </div>
      )}

      <ScrollShadow className="-mr-6 h-full max-h-full pr-6">
        {/* New Chat */}
        <Button
          fullWidth
          className="bg-default-foreground text-default-50 mt-2 mb-6 h-[44px] justify-start gap-3 px-3 py-[10px]"
          startContent={<Plus size={24} />}
          onPress={onNew}
        >
          新建对话
        </Button>

        {/* Conversation list */}
        <div className="flex flex-col gap-1">
          <div className="text-tiny text-default-400 px-2 py-1 font-medium">
            最近对话
          </div>
          {sorted.map((conv) => (
            <div key={conv.id} className="group relative">
              {renamingId === conv.id ? (
                <input
                  autoFocus
                  className="w-full h-[44px] px-3 py-2 text-small bg-default-100 rounded-lg border border-default-300 outline-none"
                  value={renameValue}
                  onBlur={() => {
                    if (renameValue.trim() && renameValue.trim() !== conv.title) {
                      onRename(conv.id, renameValue.trim());
                    }
                    setRenamingId(null);
                  }}
                  onChange={(e) => setRenameValue(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      if (renameValue.trim() && renameValue.trim() !== conv.title) {
                        onRename(conv.id, renameValue.trim());
                      }
                      setRenamingId(null);
                    }
                    if (e.key === 'Escape') setRenamingId(null);
                  }}
                />
              ) : (
                <button
                  className={cn(
                    'w-full text-left h-[44px] px-3 py-2 rounded-lg text-small transition-colors flex items-center justify-between',
                    activeId === conv.id
                      ? 'bg-default-200 text-foreground'
                      : 'text-default-600 hover:bg-default-100',
                  )}
                  onClick={() => onSelect(conv.id)}
                >
                  <span className="truncate flex-1">{conv.title || '新对话'}</span>
                  <div className="relative shrink-0">
                    <button
                      className="opacity-0 group-hover:opacity-100 p-0.5 rounded hover:bg-default-300 transition-opacity"
                      onClick={(e) => {
                        e.stopPropagation();
                        setMenuOpen(menuOpen === conv.id ? null : conv.id);
                      }}
                    >
                      <Ellipsis size={18} />
                    </button>
                    {menuOpen === conv.id && (
                      <div className="absolute right-0 top-8 z-50 bg-content1 border border-default-200 rounded-lg shadow-lg py-1 min-w-[120px]">
                        <button
                          className="w-full text-left px-3 py-2 text-small hover:bg-default-100 flex items-center gap-2"
                          onClick={(e) => {
                            e.stopPropagation();
                            setMenuOpen(null);
                            setRenamingId(conv.id);
                            setRenameValue(conv.title);
                          }}
                        >
                          <Pencil size={14} /> 重命名
                        </button>
                        <button
                          className="w-full text-left px-3 py-2 text-small hover:bg-default-100 flex items-center gap-2 text-danger"
                          onClick={(e) => {
                            e.stopPropagation();
                            setMenuOpen(null);
                            onDelete(conv.id);
                          }}
                        >
                          <Trash2 size={14} /> 删除
                        </button>
                      </div>
                    )}
                  </div>
                </button>
              )}
            </div>
          ))}
          {sorted.length === 0 && (
            <p className="text-tiny text-default-400 px-2 py-4 text-center">
              暂无对话，点击上方按钮新建
            </p>
          )}
          {sorted.length > 10 && (
            <button className="w-full text-left h-[44px] px-3 py-2 rounded-lg text-small text-default-400 hover:bg-default-100 flex items-center gap-2">
              <ChevronDown size={16} /> 显示更多
            </button>
          )}
        </div>
      </ScrollShadow>

      <Spacer y={8} />

      {/* Bottom actions */}
      <div className="mt-auto flex flex-col">
        <Button
          fullWidth
          className="text-default-600 justify-start"
          startContent={<Info size={24} />}
          variant="light"
        >
          帮助
        </Button>
        <Button
          fullWidth
          className="text-default-600 justify-start"
          startContent={<History size={24} />}
          variant="light"
        >
          活动
        </Button>
        <Button
          fullWidth
          className="text-default-600 justify-start"
          startContent={<Settings size={24} />}
          variant="light"
        >
          设置
        </Button>
      </div>
    </div>
  );
}
