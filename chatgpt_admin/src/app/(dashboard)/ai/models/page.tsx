'use client';

import { useState, useCallback } from 'react';
import {
  Table, TableHeader, TableColumn, TableBody, TableRow, TableCell,
  Button, Chip, Switch, Select, SelectItem, Input, Tooltip, Spinner,
  Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
} from '@heroui/react';
import { Pencil, Trash2, Circle, CheckCircle } from 'lucide-react';
import { useModels, useProviders, useAiMutations } from '@/hooks/useAi';
import { ModelForm } from '@/components/ai/ModelForm';
import type { AiModel } from '@/types/ai';
import type { ModelForm as ModelFormType } from '@/schemas/ai';

export default function AiModelsPage() {
  const { data: providers } = useProviders();
  const {
    createModel, updateModel, deleteModel, setDefaultModel,
  } = useAiMutations();

  const [filters, setFilters] = useState<{
    providerId?: string;
    enabled?: string;
    keyword?: string;
  }>({});

  const [keywordValue, setKeywordValue] = useState('');
  const [searchTimer, setSearchTimer] = useState<ReturnType<typeof setTimeout> | null>(null);

  const { data: models, isLoading } = useModels(filters);

  const [isCreate, setIsCreate] = useState(false);
  const [editModel, setEditModel] = useState<AiModel | null>(null);
  const [deleteId, setDeleteId] = useState<number | null>(null);
  const [enabledSwitches, setEnabledSwitches] = useState<Set<number>>(new Set());
  const [defaultRadios, setDefaultRadios] = useState<Set<number>>(new Set());

  const handleKeywordChange = useCallback(
    (val: string) => {
      setKeywordValue(val);
      if (searchTimer) clearTimeout(searchTimer);
      const timer = setTimeout(() => {
        setFilters((f) => ({ ...f, keyword: val || undefined }));
      }, 400);
      setSearchTimer(timer);
    },
    [searchTimer],
  );

  const handleCreate = (data: ModelFormType) => {
    createModel.mutate(data, {
      onSuccess: () => setIsCreate(false),
    });
  };

  const handleEdit = (data: ModelFormType) => {
    if (!editModel) return;
    updateModel.mutate(
      { id: editModel.id, ...data },
      { onSuccess: () => setEditModel(null) },
    );
  };

  const handleDelete = () => {
    if (deleteId === null) return;
    deleteModel.mutate(deleteId, { onSuccess: () => setDeleteId(null) });
  };

  const handleToggleEnabled = (model: AiModel) => {
    setEnabledSwitches((prev) => {
      const next = new Set(prev);
      next.add(model.id);
      return next;
    });
    updateModel.mutate(
      { id: model.id, enabled: !model.enabled },
      {
        onSettled: () => {
          setEnabledSwitches((prev) => {
            const next = new Set(prev);
            next.delete(model.id);
            return next;
          });
        },
      },
    );
  };

  const handleSetDefault = (model: AiModel) => {
    setDefaultRadios((prev) => {
      const next = new Set(prev);
      next.add(model.id);
      return next;
    });
    setDefaultModel.mutate(model.id, {
      onSettled: () => {
        setDefaultRadios((prev) => {
          const next = new Set(prev);
          next.delete(model.id);
          return next;
        });
      },
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-xl font-bold">模型管理</h1>
        <Button color="primary" onPress={() => setIsCreate(true)}>新增模型</Button>
      </div>

      {/* Filters */}
      <div className="flex gap-3 items-end flex-wrap">
        <Select
          label="服务商"
          placeholder="全部"
          className="w-44"
          size="sm"
          onSelectionChange={(keys) => {
            const val = Array.from(keys as Set<string>)[0];
            setFilters((f) => ({ ...f, providerId: val === 'all' ? undefined : val }));
          }}
        >
          {[
            <SelectItem key="all">全部</SelectItem>,
            ...(providers || []).map((p) => (
              <SelectItem key={String(p.id)}>{p.displayName}</SelectItem>
            )),
          ]}
        </Select>
        <Select
          label="状态"
          placeholder="全部"
          className="w-32"
          size="sm"
          onSelectionChange={(keys) => {
            const val = Array.from(keys as Set<string>)[0];
            setFilters((f) => ({
              ...f,
              enabled: val === 'all' ? undefined : val,
            }));
          }}
        >
          <SelectItem key="all">全部</SelectItem>
          <SelectItem key="true">启用</SelectItem>
          <SelectItem key="false">停用</SelectItem>
        </Select>
        <Input
          label="关键词"
          placeholder="搜索 modelId / 名称"
          className="w-56"
          size="sm"
          value={keywordValue}
          onValueChange={handleKeywordChange}
        />
      </div>

      <Table aria-label="模型列表">
        <TableHeader>
          <TableColumn>模型</TableColumn>
          <TableColumn>服务商</TableColumn>
          <TableColumn>描述</TableColumn>
          <TableColumn>能力</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>默认</TableColumn>
          <TableColumn>排序</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody isLoading={isLoading} items={models || []} emptyContent="暂无模型">
          {(m) => (
            <TableRow key={m.id}>
              <TableCell>
                <div>
                  <div className="font-medium text-sm">{m.displayName}</div>
                  <div className="text-xs text-default-400">{m.modelId}</div>
                </div>
              </TableCell>
              <TableCell>
                <Chip size="sm" variant="flat">{m.providerCode || '-'}</Chip>
              </TableCell>
              <TableCell>
                <div className="max-w-48 text-sm text-default-500 line-clamp-2">
                  {m.description || '-'}
                </div>
              </TableCell>
              <TableCell>
                {(() => {
                  const caps = [
                    m.supportsVision && '视觉',
                    m.supportsTool && '工具',
                    m.supportsReasoning && '推理',
                    m.supportsPdf && 'PDF',
                  ].filter(Boolean) as string[];
                  if (caps.length === 0) {
                    return <span className="text-xs text-default-300">-</span>;
                  }
                  return (
                    <div className="flex flex-wrap gap-1">
                      {caps.map((cap) => (
                        <Chip key={cap} size="sm" variant="flat" color="secondary">
                          {cap}
                        </Chip>
                      ))}
                    </div>
                  );
                })()}
              </TableCell>
              <TableCell>
                <Switch
                  isSelected={m.enabled}
                  onValueChange={() => handleToggleEnabled(m)}
                  isDisabled={enabledSwitches.has(m.id)}
                  size="sm"
                />
              </TableCell>
              <TableCell>
                <button
                  onClick={() => handleSetDefault(m)}
                  disabled={defaultRadios.has(m.id)}
                  className="p-1 rounded hover:bg-default-200 disabled:opacity-50"
                  title="设为默认模型"
                >
                  {m.isDefault
                    ? <CheckCircle size={18} className="text-primary" />
                    : <Circle size={18} className="text-default-300" />
                  }
                </button>
              </TableCell>
              <TableCell>{m.sortOrder}</TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Tooltip content="编辑">
                    <Button
                      size="sm"
                      variant="flat"
                      isIconOnly
                      onPress={() => setEditModel(m)}
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
                      onPress={() => setDeleteId(m.id)}
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
      <ModelForm
        open={isCreate}
        isCreate
        onClose={() => setIsCreate(false)}
        onSave={handleCreate}
        loading={createModel.isPending}
      />

      {/* Edit Modal */}
      <ModelForm
        open={editModel !== null}
        isCreate={false}
        model={editModel}
        onClose={() => setEditModel(null)}
        onSave={handleEdit}
        loading={updateModel.isPending}
      />

      {/* Delete Confirm */}
      <Modal isOpen={deleteId !== null} onClose={() => setDeleteId(null)}>
        <ModalContent>
          <ModalHeader>确认删除</ModalHeader>
          <ModalBody><p>确认删除此模型？</p></ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setDeleteId(null)}>取消</Button>
            <Button
              color="danger"
              isLoading={deleteModel.isPending}
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
