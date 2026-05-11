'use client';

import { useState } from 'react';
import {
  Table, TableHeader, TableColumn, TableBody, TableRow, TableCell,
  Button, Chip, Switch, Tooltip, Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
} from '@heroui/react';
import { Eye, EyeOff, Wrench, Pencil, Trash2 } from 'lucide-react';
import { useProviders, useModels, useAiMutations } from '@/hooks/useAi';
import { ProviderForm } from '@/components/ai/ProviderForm';
import type { AiProvider } from '@/types/ai';
import type { ProviderCreateForm, ProviderUpdateForm } from '@/schemas/ai';

export default function AiProvidersPage() {
  const { data: providers, isLoading } = useProviders();
  const { data: allModels } = useModels();
  const {
    createProvider, updateProvider, deleteProvider, testProvider,
  } = useAiMutations();

  const [isCreate, setIsCreate] = useState(false);
  const [editProvider, setEditProvider] = useState<AiProvider | null>(null);
  const [deleteId, setDeleteId] = useState<number | null>(null);
  const [testId, setTestId] = useState<number | null>(null);
  const [testResult, setTestResult] = useState<{ ok: boolean; msg: string } | null>(null);
  const [visibleKeys, setVisibleKeys] = useState<Set<number>>(new Set());
  const [enabledSwitches, setEnabledSwitches] = useState<Set<number>>(new Set());

  const modelCountByProvider = (providerId: number) =>
    allModels?.filter((m) => m.providerId === providerId).length || 0;

  const toggleKeyVisible = (id: number) => {
    const next = new Set(visibleKeys);
    if (next.has(id)) next.delete(id); else next.add(id);
    setVisibleKeys(next);
  };

  const handleCreate = (data: ProviderCreateForm) => {
    createProvider.mutate(data, {
      onSuccess: () => {
        setIsCreate(false);
      },
    });
  };

  const handleEdit = (data: ProviderUpdateForm) => {
    if (!editProvider) return;
    updateProvider.mutate(
      { id: editProvider.id, ...data },
      {
        onSuccess: () => setEditProvider(null),
      },
    );
  };

  const handleDelete = () => {
    if (deleteId === null) return;
    deleteProvider.mutate(deleteId, { onSuccess: () => setDeleteId(null) });
  };

  const handleTest = (id: number) => {
    setTestId(id);
    setTestResult(null);
    testProvider.mutate(id, {
      onSuccess: (data) => {
        setTestResult({
          ok: data.ok,
          msg: data.ok
            ? `✓ 连接成功 (${data.latencyMs}ms)，回复样本: ${data.sample || '(空)'}`
            : `✗ 失败：${data.error}`,
        });
        setTimeout(() => setTestResult(null), 6000);
      },
      onError: (err: Error) => {
        setTestResult({ ok: false, msg: `✗ 失败：${err.message}` });
        setTimeout(() => setTestResult(null), 6000);
      },
      onSettled: () => setTestId(null),
    });
  };

  const handleToggleEnabled = (provider: AiProvider) => {
    setEnabledSwitches((prev) => {
      const next = new Set(prev);
      next.add(provider.id);
      return next;
    });
    updateProvider.mutate(
      { id: provider.id, enabled: !provider.enabled },
      {
        onSettled: () => {
          setEnabledSwitches((prev) => {
            const next = new Set(prev);
            next.delete(provider.id);
            return next;
          });
        },
      },
    );
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-xl font-bold">服务商管理</h1>
        <Button color="primary" onPress={() => setIsCreate(true)}>新增服务商</Button>
      </div>

      {testResult && (
        <div className={`p-3 rounded text-sm ${testResult.ok ? 'bg-success-50 text-success-700' : 'bg-danger-50 text-danger-700'}`}>
          {testResult.msg}
        </div>
      )}

      <Table aria-label="服务商列表">
        <TableHeader>
          <TableColumn>代码</TableColumn>
          <TableColumn>显示名称</TableColumn>
          <TableColumn>API Key</TableColumn>
          <TableColumn>Base URL</TableColumn>
          <TableColumn>模型前缀</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>排序</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody isLoading={isLoading} items={providers || []} emptyContent="暂无服务商">
          {(p) => (
            <TableRow key={p.id}>
              <TableCell>
                <Chip size="sm" variant="flat" color="primary">{p.code}</Chip>
              </TableCell>
              <TableCell>{p.displayName}</TableCell>
              <TableCell>
                <div className="flex items-center gap-1">
                  <code className="text-xs">
                    {visibleKeys.has(p.id) ? p.apiKey : '••••'}
                  </code>
                  <Tooltip content={visibleKeys.has(p.id) ? '隐藏' : '显示'}>
                    <button
                      onClick={() => toggleKeyVisible(p.id)}
                      className="p-0.5 hover:bg-default-200 rounded"
                    >
                      {visibleKeys.has(p.id) ? <EyeOff size={14} /> : <Eye size={14} />}
                    </button>
                  </Tooltip>
                </div>
              </TableCell>
              <TableCell>
                <a href={p.baseUrl} target="_blank" rel="noreferrer" className="text-primary underline text-sm">
                  {p.baseUrl.length > 30 ? p.baseUrl.slice(0, 30) + '...' : p.baseUrl}
                </a>
              </TableCell>
              <TableCell>
                <div className="flex gap-1 flex-wrap">
                  {p.modelPrefixes?.split(',').filter(Boolean).map((pfx) => (
                    <Chip key={pfx} size="sm" variant="flat">{pfx.trim()}</Chip>
                  )) || '-'}
                </div>
              </TableCell>
              <TableCell>
                <Switch
                  isSelected={p.enabled}
                  onValueChange={() => handleToggleEnabled(p)}
                  isDisabled={enabledSwitches.has(p.id)}
                  size="sm"
                />
              </TableCell>
              <TableCell>{p.sortOrder}</TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Tooltip content="测试连接">
                    <Button
                      size="sm"
                      variant="flat"
                      isIconOnly
                      isLoading={testId === p.id}
                      onPress={() => handleTest(p.id)}
                    >
                      <Wrench size={14} />
                    </Button>
                  </Tooltip>
                  <Tooltip content="编辑">
                    <Button
                      size="sm"
                      variant="flat"
                      isIconOnly
                      onPress={() => setEditProvider(p)}
                    >
                      <Pencil size={14} />
                    </Button>
                  </Tooltip>
                  <Tooltip content="删除">
                    <Button
                      size="sm"
                      variant="flat"
                      color="danger"
                      isIconOnly
                      onPress={() => setDeleteId(p.id)}
                    >
                      <Trash2 size={14} />
                    </Button>
                  </Tooltip>
                </div>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      {/* Create Modal */}
      <ProviderForm
        open={isCreate}
        isCreate
        onClose={() => setIsCreate(false)}
        onSave={(data) => handleCreate(data as ProviderCreateForm)}
        loading={createProvider.isPending}
      />

      {/* Edit Modal */}
      <ProviderForm
        open={editProvider !== null}
        isCreate={false}
        provider={editProvider}
        onClose={() => setEditProvider(null)}
        onSave={handleEdit}
        loading={updateProvider.isPending}
      />

      {/* Delete Confirm */}
      <Modal isOpen={deleteId !== null} onClose={() => setDeleteId(null)}>
        <ModalContent>
          <ModalHeader>确认删除</ModalHeader>
          <ModalBody>
            <p>
              将同时删除该服务商下所有模型
              {deleteId !== null && `（${modelCountByProvider(deleteId)} 个）`}。
              此操作不可撤销，确认删除？
            </p>
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setDeleteId(null)}>取消</Button>
            <Button
              color="danger"
              isLoading={deleteProvider.isPending}
              onPress={handleDelete}
            >
              删除
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
