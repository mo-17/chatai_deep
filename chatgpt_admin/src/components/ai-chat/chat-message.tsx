'use client';

import React from 'react';
import { Avatar, cn } from '@nextui-org/react';

export interface ChatMessageProps {
  avatar: string;
  name: string;
  message: string;
  time?: string;
  isAI?: boolean;
  classNames?: Record<'base', string>;
}

const ChatMessage = React.forwardRef<HTMLDivElement, ChatMessageProps>(
  ({ avatar, name, time, message, isAI, className, classNames, ...props }, ref) => {
    const initials = name?.charAt(0)?.toUpperCase() || '?';

    return (
      <div
        {...props}
        ref={ref}
        className={cn('flex gap-3', { 'flex-row-reverse': !isAI }, className)}
      >
        <div className="relative flex-none">
          <Avatar
            name={initials}
            src={avatar || undefined}
            className={isAI ? 'bg-[#2E7D32] text-white' : 'bg-[#0F3460] text-white'}
          />
        </div>
        <div className="flex max-w-[70%] flex-col gap-4">
          <div
            className={cn(
              'rounded-medium bg-content2 text-default-600 relative w-full px-4 py-3',
              classNames?.base,
            )}
          >
            <div className="flex items-center gap-2">
              <div className="text-small text-default-foreground w-full font-semibold">
                {name}
              </div>
              {time && (
                <div className="flex-end text-tiny text-default-400 shrink-0">
                  {time}
                </div>
              )}
            </div>
            <div className="text-small text-default-900 mt-2">
              <div className="whitespace-pre-wrap break-words">{message}</div>
            </div>
          </div>
        </div>
      </div>
    );
  },
);

ChatMessage.displayName = 'ChatMessage';

export default ChatMessage;
