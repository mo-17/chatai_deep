'use client';

import React, { useState, useRef, useEffect } from 'react';
import {
  ScrollShadow,
  Button,
  Tooltip,
  cn,
  Select,
  SelectItem,
} from '@heroui/react';
import { ArrowUp, Paperclip, Mic, Menu } from 'lucide-react';

import ChatSidebar from '@/components/ai-chat/chat-sidebar';
import ChatMessage from '@/components/ai-chat/chat-message';
import PromptInput from '@/components/ai-chat/prompt-input';
import { useChatService } from '@/hooks/useChatService';
import { useAuthStore } from '@/store/authStore';
import { captureChatScope, chatScopeCurrent } from '@/lib/chat/scope';

export default function AiChatPage() {
  const {
    conversations,
    activeId,
    messages,
    isLoading,
    error,
    newConversation,
    selectConversation,
    deleteConversation,
    renameConversation,
    sendMessage,
    cancelRequest,
    selectionKey: model,
    selectionLabel: modelLabel,
    choices: models,
    metadataStatus,
    metadataError,
    canSend,
    contextKey,
    chooseSelection,
    refreshMetadata,
    refreshConversations,
  } = useChatService();

  const admin = useAuthStore((s) => s.admin);
  const [prompt, setPrompt] = useState('');
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [listening, setListening] = useState(false);
  const [speechSupported, setSpeechSupported] = useState(false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const recognitionRef = useRef<any>(null);
  const promptBeforeSpeech = useRef('');
  const listeningRef = useRef(false);
  const currentPrompt = useRef(prompt);
  useEffect(() => {
    currentPrompt.current = prompt;
  }, [prompt]);
  const scrollRef = useRef<HTMLDivElement>(null);

  // 初始化语音识别
  useEffect(() => {
    const SpeechRecognition =
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (window as any).SpeechRecognition ||
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (window as any).webkitSpeechRecognition;
    if (!SpeechRecognition) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setSpeechSupported(true);

    let scope;
    try {
      scope = captureChatScope();
    } catch {
      return;
    }
    const recognition = new SpeechRecognition();
    recognition.lang = 'zh-CN';
    recognition.interimResults = true;

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onresult = (event: any) => {
      if (!chatScopeCurrent(scope)) return;
      // 从 0 遍历全部 results，保证间隔后的识别追加而非覆盖
      let transcript = '';
      for (let i = 0; i < event.results.length; i++) {
        transcript += event.results[i][0].transcript;
      }
      setPrompt(promptBeforeSpeech.current + transcript);
    };

    recognition.onend = () => {
      if (chatScopeCurrent(scope) && listeningRef.current) {
        // 续接前更新基准值，避免覆盖已识别内容
        // console.log('recognition.onend');
        promptBeforeSpeech.current = currentPrompt.current;
        try {
          recognition.start();
        } catch {
          setListening(false);
        }
      } else {
        setListening(false);
      }
    };

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    recognition.onerror = (event: any) => {
      if (!chatScopeCurrent(scope)) return;
      if (event?.error === 'aborted' && listeningRef.current) {
        promptBeforeSpeech.current = currentPrompt.current;
        try {
          recognition.start();
        } catch {
          setListening(false);
        }
      } else {
        listeningRef.current = false;
        setListening(false);
      }
    };

    recognitionRef.current = recognition;
    return () => {
      listeningRef.current = false;
      recognition.onresult = null;
      recognition.onend = null;
      recognition.onerror = null;
      recognition.stop();
    };
  }, [contextKey]);

  const toggleMic = () => {
    if (listening) {
      listeningRef.current = false;
      recognitionRef.current?.stop();
      setListening(false);
    } else {
      promptBeforeSpeech.current = prompt;
      listeningRef.current = true;
      setListening(true);
      recognitionRef.current?.start();
    }
  };

  // 账号范围变化清空输入与语音；旧识别结果不能写进新会话。
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setPrompt('');
    listeningRef.current = false;
    recognitionRef.current?.stop();
    setListening(false);
  }, [contextKey]);

  const handleModelChange = (keys: Set<string>) => {
    const value = Array.from(keys)[0];
    if (value) void chooseSelection(value);
  };

  // 自动滚动到底部
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages]);

  const activeConv = conversations.find((c) => c.id === activeId) || null;

  const handleSend = () => {
    if (!prompt.trim() || isLoading || !canSend) return;
    if (!activeId) {
      const id = newConversation();
      void sendMessage(prompt.trim(), model || undefined, id);
    } else {
      void sendMessage(prompt.trim(), model || undefined);
    }
    setPrompt('');
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  return (
    <div className="h-[calc(100vh-64px)] w-full max-w-full flex">
      {/* Desktop sidebar — hidden on mobile */}
      <div className="hidden sm:flex h-full shrink-0 border-r border-default-200 bg-default-50">
        <ChatSidebar
          conversations={conversations}
          activeId={activeId}
          onSelect={selectConversation}
          onNew={newConversation}
          onDelete={deleteConversation}
          onRename={renameConversation}
          user={admin ? { name: admin.userName, avatar: admin.avatar } : null}
        />
      </div>

      {/* Mobile sidebar drawer */}
      {sidebarOpen && (
        <div className="fixed inset-0 z-50 sm:hidden">
          <div
            className="absolute inset-0 bg-black/50"
            onClick={() => setSidebarOpen(false)}
          />
          <div className="absolute left-0 top-0 h-full bg-default-50">
            <ChatSidebar
              conversations={conversations}
              activeId={activeId}
              onSelect={(id) => {
                selectConversation(id);
                setSidebarOpen(false);
              }}
              onNew={() => {
                newConversation();
                setSidebarOpen(false);
              }}
              onDelete={deleteConversation}
              onRename={renameConversation}
              user={
                admin ? { name: admin.userName, avatar: admin.avatar } : null
              }
            />
          </div>
        </div>
      )}

      {/* Main chat area */}
      <div className="flex-1 flex flex-col min-w-0">
        {/* Header */}
        <header className="rounded-t-medium border-small border-divider flex h-16 min-h-16 items-center justify-between gap-2 rounded-none px-4 py-3">
          {/* Mobile menu button */}
          <Button
            isIconOnly
            className="flex sm:hidden"
            size="sm"
            variant="light"
            onPress={() => setSidebarOpen(true)}
          >
            <Menu size={24} />
          </Button>

          <div className="w-full min-w-[120px] sm:w-auto">
            <div className="text-small text-foreground truncate leading-5 font-semibold">
              {activeConv?.title || 'AI 对话'}
            </div>
            <div className="text-small text-default-500 truncate leading-5 font-normal">
              {modelLabel}
            </div>
          </div>

          <div className="flex items-center gap-2">
            <Select
              aria-label="选择模型"
              className="w-[260px]"
              size="sm"
              isDisabled={isLoading}
              disabledKeys={[
                ...(model && !models.some((m) => m.key === model)
                  ? [model]
                  : []),
                'status',
              ]}
              selectedKeys={model ? [model] : []}
              onSelectionChange={(keys) =>
                handleModelChange(keys as Set<string>)
              }
            >
              {[
                ...models.map((m) => (
                  <SelectItem key={m.key} textValue={m.label}>
                    {m.label}
                  </SelectItem>
                )),
                ...(model && !models.some((m) => m.key === model)
                  ? [
                      <SelectItem key={model} textValue={modelLabel}>
                        {modelLabel}
                      </SelectItem>,
                    ]
                  : []),
                ...(models.length === 0
                  ? [
                      <SelectItem
                        key="status"
                        textValue={
                          metadataStatus === 'loading'
                            ? '加载中'
                            : metadataStatus === 'failed'
                              ? '清单读取失败'
                              : '暂无可用模型'
                        }
                      >
                        {metadataStatus === 'loading'
                          ? '加载中'
                          : metadataStatus === 'failed'
                            ? '清单读取失败'
                            : '暂无可用模型'}
                      </SelectItem>,
                    ]
                  : []),
              ]}
            </Select>
            <Button
              size="sm"
              variant="light"
              onPress={() => {
                void refreshMetadata();
                void refreshConversations();
              }}
            >
              刷新清单与记录
            </Button>
          </div>
        </header>

        {/* Messages */}
        <div className="flex-1 flex flex-col min-h-0 rounded-b-medium border-b border-l border-r border-divider">
          <ScrollShadow
            ref={scrollRef}
            className="flex h-full max-h-full flex-col gap-6 overflow-y-auto p-6 pb-8"
          >
            {!activeId && messages.length === 0 && (
              <div className="flex-1 flex items-center justify-center">
                <div className="text-center space-y-2">
                  <div className="bg-default-100 rounded-full w-16 h-16 flex items-center justify-center mx-auto">
                    <svg
                      className="text-default-400"
                      fill="none"
                      height="32"
                      viewBox="0 0 32 32"
                      width="32"
                    >
                      <path
                        clipRule="evenodd"
                        d="M17.6482 10.1305L15.8785 7.02583L7.02979 22.5499H10.5278L17.6482 10.1305ZM19.8798 14.0457L18.11 17.1983L19.394 19.4511H16.8453L15.1056 22.5499H24.7272L19.8798 14.0457Z"
                        fill="currentColor"
                        fillRule="evenodd"
                      />
                    </svg>
                  </div>
                  <p className="text-default-500 font-medium">
                    选择或新建一个对话开始聊天
                  </p>
                </div>
              </div>
            )}

            {messages.map((msg, idx) => (
              <ChatMessage
                key={idx}
                avatar=""
                name={msg.role === 'user' ? admin?.userName || 'Me' : 'AI'}
                message={msg.content}
                isAI={msg.role === 'assistant'}
                time={
                  idx === messages.length - 1 &&
                  isLoading &&
                  msg.role === 'assistant'
                    ? '输入中...'
                    : undefined
                }
                classNames={{
                  base: msg.role === 'assistant' ? 'bg-default-50' : '',
                }}
              />
            ))}

            {metadataError && (
              <p role="status" className="text-danger text-small">
                清单读取失败：{metadataError}。可手动刷新。
              </p>
            )}
            {error && (
              <div className="text-center text-danger text-small py-2">
                错误: {error}
              </div>
            )}
          </ScrollShadow>

          {/* Input area */}
          <div className="mt-auto flex max-w-full flex-col gap-2 px-6 pb-4">
            <form
              className="flex w-full items-start gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                handleSend();
              }}
            >
              <PromptInput
                classNames={{
                  innerWrapper: 'items-center',
                  input:
                    'text-medium data-[has-start-content=true]:ps-0 data-[has-start-content=true]:pe-0',
                }}
                endContent={
                  <div className="flex gap-2">
                    {speechSupported && (
                      <Tooltip
                        showArrow
                        content={listening ? '停止' : '语音输入'}
                      >
                        <Button
                          isIconOnly
                          color={listening ? 'danger' : 'default'}
                          radius="full"
                          variant={listening ? 'solid' : 'light'}
                          onPress={toggleMic}
                        >
                          <Mic
                            className={
                              listening ? 'text-white' : 'text-default-500'
                            }
                            size={20}
                          />
                        </Button>
                      </Tooltip>
                    )}
                    {isLoading ? (
                      <Tooltip showArrow content="停止">
                        <Button
                          isIconOnly
                          color="danger"
                          radius="full"
                          onPress={cancelRequest}
                        >
                          <div className="w-3 h-3 bg-white rounded-sm" />
                        </Button>
                      </Tooltip>
                    ) : (
                      <Tooltip showArrow content="发送">
                        <Button
                          isIconOnly
                          className="bg-default-foreground opacity-100 w-[30px] h-[30px] min-w-[30px] self-center"
                          color={!prompt ? 'default' : 'primary'}
                          isDisabled={!prompt || !canSend}
                          radius="full"
                          variant={!prompt ? 'flat' : 'solid'}
                          onPress={handleSend}
                        >
                          <ArrowUp
                            className={cn(
                              '[&>path]:stroke-[2px]',
                              !prompt ? 'text-default-500' : 'text-background',
                            )}
                            size={20}
                          />
                        </Button>
                      </Tooltip>
                    )}
                  </div>
                }
                placeholder="输入消息..."
                startContent={
                  <Tooltip showArrow content="添加文件">
                    <Button
                      isIconOnly
                      className="p-[10px]"
                      radius="full"
                      variant="light"
                    >
                      <Paperclip className="text-default-500" size={20} />
                    </Button>
                  </Tooltip>
                }
                value={prompt}
                onValueChange={setPrompt}
                onKeyDown={handleKeyDown}
              />
            </form>
            <p className="text-small text-default-500 px-2 text-center leading-5 font-medium">
              AI 可能产生不准确的信息，请核实重要内容。
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
