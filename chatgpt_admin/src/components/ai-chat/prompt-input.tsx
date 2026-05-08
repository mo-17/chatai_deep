'use client';

import type { TextAreaProps } from '@nextui-org/react';

import React from 'react';
import { Textarea, cn } from '@nextui-org/react';

const PromptInput = React.forwardRef<HTMLTextAreaElement, TextAreaProps>(
  ({ classNames = {}, ...props }, ref) => {
    return (
      <Textarea
        ref={ref}
        aria-label="Prompt"
        className="min-h-[40px]"
        classNames={{
          ...classNames,
          label: cn('hidden', classNames?.label),
          input: cn('py-0', classNames?.input),
        }}
        minRows={1}
        placeholder="输入消息..."
        radius="lg"
        variant="bordered"
        {...props}
      />
    );
  },
);

PromptInput.displayName = 'PromptInput';

export default PromptInput;
