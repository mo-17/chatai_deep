'use client';

import { useState } from 'react';
import {
  Table,
  TableHeader,
  TableColumn,
  TableBody,
  TableRow,
  TableCell,
  Button,
  Chip,
  Switch,
  Input,
  Textarea,
  Modal,
  ModalContent,
  ModalHeader,
  ModalBody,
  ModalFooter,
} from '@heroui/react';
import { Wrench, Pencil, Trash2, Plus, Store } from 'lucide-react';
import { useMcpServers, useMcpMutations } from '@/hooks/useMcp';
import type { McpServer, McpServerInput } from '@/types/mcp';
import {
  MCP_STORE,
  mcpStoreGrouped,
  authBadge,
  type McpStoreEntry,
} from '@/lib/mcpStore';

interface FormState {
  code: string;
  name: string;
  transport: 'http' | 'stdio';
  url: string;
  command: string;
  args: string;
  headers: string;
  env: string;
  enabled: boolean;
  sortOrder: number;
}

const emptyForm: FormState = {
  code: '',
  name: '',
  transport: 'http',
  url: '',
  command: '',
  args: '',
  headers: '',
  env: '',
  enabled: true,
  sortOrder: 0,
};

/** 每行 "Key: Value" → 对象；空串返回 undefined（更新时表示「保留原值」）。 */
function parseKv(text: string): Record<string, string> | undefined {
  const t = text.trim();
  if (!t) return undefined;
  const out: Record<string, string> = {};
  for (const line of t.split('\n')) {
    const i = line.indexOf(':');
    if (i <= 0) continue;
    const k = line.slice(0, i).trim();
    const v = line.slice(i + 1).trim();
    if (k) out[k] = v;
  }
  return out;
}

function parseArgs(text: string): string[] {
  return text
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 商店条目 → 新增表单（header 型预填一行 Authorization 引导）。 */
function presetToForm(e: McpStoreEntry): FormState {
  return {
    code: e.id,
    name: e.name,
    transport: e.transport,
    url: e.url ?? '',
    command: e.command ?? '',
    args: (e.args ?? []).join('\n'),
    headers: e.auth === 'header' ? 'Authorization: Bearer ' : '',
    env: '',
    enabled: true,
    sortOrder: 0,
  };
}

export default function McpServersPage() {
  const { data: servers, isLoading } = useMcpServers();
  const { create, update, remove, test } = useMcpMutations();

  const [mode, setMode] = useState<'create' | 'edit' | null>(null);
  const [editId, setEditId] = useState<number | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [storeOpen, setStoreOpen] = useState(false);
  const [testResult, setTestResult] = useState<{ id: number; msg: string } | null>(
    null,
  );

  const openCreate = () => {
    setForm(emptyForm);
    setEditId(null);
    setMode('create');
  };

  /** 从商店选一条预设：填进新增表单，管理员可改后保存。 */
  const openFromStore = (e: McpStoreEntry) => {
    setForm(presetToForm(e));
    setEditId(null);
    setStoreOpen(false);
    setMode('create');
  };

  const openEdit = (s: McpServer) => {
    setForm({
      code: s.code,
      name: s.name,
      transport: s.transport,
      url: s.url,
      command: s.command,
      args: (s.args ?? []).join('\n'),
      headers: '', // 值已脱敏，留空表示保留原值
      env: '',
      enabled: s.enabled,
      sortOrder: s.sortOrder,
    });
    setEditId(s.id);
    setMode('edit');
  };

  const submit = () => {
    const body: McpServerInput = {
      code: form.code.trim(),
      name: form.name.trim() || form.code.trim(),
      transport: form.transport,
      url: form.transport === 'http' ? form.url.trim() : '',
      command: form.transport === 'stdio' ? form.command.trim() : '',
      args: parseArgs(form.args),
      enabled: form.enabled,
      sortOrder: Number(form.sortOrder) || 0,
    };
    const headers = parseKv(form.headers);
    const env = parseKv(form.env);
    if (headers) body.headers = headers;
    if (env) body.env = env;

    if (mode === 'create') {
      create.mutate(body, { onSuccess: () => setMode(null) });
    } else if (mode === 'edit' && editId != null) {
      update.mutate({ id: editId, ...body }, { onSuccess: () => setMode(null) });
    }
  };

  const runTest = (s: McpServer) => {
    setTestResult({ id: s.id, msg: '测试中…' });
    test.mutate(s.id, {
      onSuccess: (r) =>
        setTestResult({
          id: s.id,
          msg: r.ok
            ? `连通，工具 ${r.toolCount ?? 0} 个${
                r.tools?.length ? '：\n' + r.tools.join('\n') : ''
              }`
            : `失败：${r.error ?? '未知错误'}`,
        }),
      onError: (e: unknown) =>
        setTestResult({ id: s.id, msg: `失败：${(e as Error).message}` }),
    });
  };

  return (
    <div className="p-6">
      <div className="flex items-center justify-between mb-4">
        <div>
          <h1 className="text-2xl font-bold">MCP 服务</h1>
          <p className="text-sm text-default-500 mt-1">
            后端聚合的 MCP server（方案 B）。支持 http（远程）与 stdio（本地子进程）。
            移动端经 /uapi/mcp/* 间接使用。
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="flat"
            startContent={<Store size={16} />}
            onPress={() => setStoreOpen(true)}
          >
            服务商店
          </Button>
          <Button color="primary" startContent={<Plus size={16} />} onPress={openCreate}>
            新增 server
          </Button>
        </div>
      </div>

      <Table aria-label="MCP servers">
        <TableHeader>
          <TableColumn>CODE</TableColumn>
          <TableColumn>名称</TableColumn>
          <TableColumn>传输</TableColumn>
          <TableColumn>地址 / 命令</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody
          items={servers ?? []}
          isLoading={isLoading}
          emptyContent="还没有 MCP server，点右上角新增。"
        >
          {(s) => (
            <TableRow key={s.id}>
              <TableCell>
                <code className="text-xs">{s.code}</code>
              </TableCell>
              <TableCell>{s.name}</TableCell>
              <TableCell>
                <Chip size="sm" variant="flat">
                  {s.transport}
                </Chip>
              </TableCell>
              <TableCell>
                <span className="text-xs text-default-500 break-all">
                  {s.transport === 'http'
                    ? s.url
                    : [s.command, ...(s.args ?? [])].join(' ')}
                </span>
              </TableCell>
              <TableCell>
                <Chip size="sm" color={s.enabled ? 'success' : 'default'} variant="dot">
                  {s.enabled ? '启用' : '停用'}
                </Chip>
              </TableCell>
              <TableCell>
                <div className="flex items-center gap-1">
                  <Button
                    isIconOnly
                    size="sm"
                    variant="light"
                    title="测试连接"
                    onPress={() => runTest(s)}
                  >
                    <Wrench size={16} />
                  </Button>
                  <Button
                    isIconOnly
                    size="sm"
                    variant="light"
                    title="编辑"
                    onPress={() => openEdit(s)}
                  >
                    <Pencil size={16} />
                  </Button>
                  <Button
                    isIconOnly
                    size="sm"
                    variant="light"
                    color="danger"
                    title="删除"
                    onPress={() => remove.mutate(s.id)}
                  >
                    <Trash2 size={16} />
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      {/* 新增 / 编辑 */}
      <Modal isOpen={mode !== null} onClose={() => setMode(null)} size="2xl" scrollBehavior="inside">
        <ModalContent>
          <ModalHeader>{mode === 'create' ? '新增 MCP server' : '编辑 MCP server'}</ModalHeader>
          <ModalBody className="gap-3">
            <div className="grid grid-cols-2 gap-3">
              <Input
                label="code（稳定 id，工具名前缀）"
                value={form.code}
                isDisabled={mode === 'edit'}
                onValueChange={(v) => setForm({ ...form, code: v })}
              />
              <Input
                label="名称"
                value={form.name}
                onValueChange={(v) => setForm({ ...form, name: v })}
              />
            </div>

            <div>
              <label className="text-sm text-default-600 mb-1 block">传输方式</label>
              <select
                className="w-full rounded-medium border border-default-300 bg-default-100 px-3 py-2 text-sm"
                value={form.transport}
                onChange={(e) =>
                  setForm({ ...form, transport: e.target.value as 'http' | 'stdio' })
                }
              >
                <option value="http">http（远程 Streamable HTTP）</option>
                <option value="stdio">stdio（本地子进程）</option>
              </select>
            </div>

            {form.transport === 'http' ? (
              <>
                <Input
                  label="端点 URL"
                  placeholder="https://example.com/mcp"
                  value={form.url}
                  onValueChange={(v) => setForm({ ...form, url: v })}
                />
                <Textarea
                  label="请求头（每行 Key: Value）"
                  placeholder={'Authorization: Bearer xxx'}
                  description={mode === 'edit' ? '已脱敏；留空保留原值，填写则整体替换' : undefined}
                  value={form.headers}
                  onValueChange={(v) => setForm({ ...form, headers: v })}
                />
              </>
            ) : (
              <>
                <Input
                  label="命令"
                  placeholder="npx"
                  value={form.command}
                  onValueChange={(v) => setForm({ ...form, command: v })}
                />
                <Textarea
                  label="参数（每行一个）"
                  placeholder={'-y\n@modelcontextprotocol/server-everything'}
                  value={form.args}
                  onValueChange={(v) => setForm({ ...form, args: v })}
                />
                <Textarea
                  label="环境变量（每行 Key: Value）"
                  description={mode === 'edit' ? '已脱敏；留空保留原值，填写则整体替换' : undefined}
                  value={form.env}
                  onValueChange={(v) => setForm({ ...form, env: v })}
                />
              </>
            )}

            <div className="flex items-center gap-6">
              <Switch
                isSelected={form.enabled}
                onValueChange={(v) => setForm({ ...form, enabled: v })}
              >
                启用
              </Switch>
              <Input
                type="number"
                label="排序（大在前）"
                className="max-w-[160px]"
                value={String(form.sortOrder)}
                onValueChange={(v) => setForm({ ...form, sortOrder: Number(v) || 0 })}
              />
            </div>
          </ModalBody>
          <ModalFooter>
            <Button variant="light" onPress={() => setMode(null)}>
              取消
            </Button>
            <Button
              color="primary"
              isLoading={create.isPending || update.isPending}
              onPress={submit}
            >
              保存
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      {/* 服务商店 */}
      <Modal
        isOpen={storeOpen}
        onClose={() => setStoreOpen(false)}
        size="2xl"
        scrollBehavior="inside"
      >
        <ModalContent>
          <ModalHeader className="flex-col items-start gap-1">
            <span>MCP 服务商店</span>
            <span className="text-xs font-normal text-default-500">
              精选 MCP server，点一条预填进新增表单。远程 HTTP 与本地 stdio 均可（后端宿主需装对应运行时）。
            </span>
          </ModalHeader>
          <ModalBody className="gap-4 pb-6">
            {Object.entries(mcpStoreGrouped()).map(([category, items]) => (
              <div key={category}>
                <div className="text-xs font-semibold text-primary mb-2">{category}</div>
                <div className="flex flex-col gap-2">
                  {items.map((e) => {
                    const badge = authBadge(e.auth);
                    return (
                      <button
                        key={e.id}
                        type="button"
                        onClick={() => openFromStore(e)}
                        className="flex items-start gap-3 rounded-medium border border-default-200 hover:border-primary hover:bg-default-50 p-3 text-left transition-colors"
                      >
                        <span className="text-xl leading-none">{e.emoji}</span>
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-2">
                            <span className="font-medium text-sm">{e.name}</span>
                            <Chip size="sm" variant="flat">
                              {e.transport}
                            </Chip>
                            <Chip size="sm" color={badge.color as 'success'} variant="flat">
                              {badge.label}
                            </Chip>
                          </div>
                          <div className="text-xs text-default-500 mt-0.5 break-words">
                            {e.description}
                          </div>
                          {e.authHint && (
                            <div className="text-[11px] text-warning-600 mt-1 break-words">
                              💡 {e.authHint}
                            </div>
                          )}
                        </div>
                        <Plus size={16} className="mt-1 shrink-0 text-default-400" />
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
            <div className="text-[11px] text-default-400">
              共 {MCP_STORE.length} 个预设。远程 server 均为公开端点；token / 占位需你在表单里补全。
            </div>
          </ModalBody>
          <ModalFooter>
            <Button variant="light" onPress={() => setStoreOpen(false)}>
              关闭
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      {/* 测试结果 */}
      <Modal isOpen={testResult !== null} onClose={() => setTestResult(null)}>
        <ModalContent>
          <ModalHeader>连接测试</ModalHeader>
          <ModalBody>
            <pre className="text-sm whitespace-pre-wrap break-all">{testResult?.msg}</pre>
          </ModalBody>
          <ModalFooter>
            <Button onPress={() => setTestResult(null)}>关闭</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
