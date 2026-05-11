'use client';

import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  Table, TableHeader, TableColumn, TableBody, TableRow, TableCell,
  Button, Chip, Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
  Input, Switch, Pagination,
} from '@heroui/react';
import { versionApi } from '@/lib/api/version';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { versionSchema, type VersionForm } from '@/schemas/version';
import { fmtDate } from '@/lib/utils/format';

export default function VersionsPage() {
  const queryClient = useQueryClient();
  const [page, setPage] = useState(1);
  const [editId, setEditId] = useState<number | null>(null);
  const [deleteId, setDeleteId] = useState<number | null>(null);
  const [isCreate, setIsCreate] = useState(false);

  const { data, isLoading } = useQuery({
    queryKey: ['versions', page],
    queryFn: () => versionApi.list({ page, pageSize: 10 }),
  });

  const form = useForm({ resolver: zodResolver(versionSchema) });

  const { data: editData } = useQuery({
    queryKey: ['version', editId],
    queryFn: () => versionApi.detail(editId!),
    enabled: editId !== null && !isCreate,
  });

  if (editData && editId !== null && !isCreate) {
    form.reset({
      versionName: editData.versionName,
      versionCode: editData.versionCode,
      url: editData.url || '',
      description: editData.description || '',
      cid: editData.cid,
      forceUpdate: editData.forceUpdate,
      enabled: editData.enabled,
    });
  }

  const saveMutation = useMutation({
    mutationFn: (body: VersionForm) =>
      isCreate ? versionApi.create(body) : versionApi.edit(editId!, body),
    onSuccess: () => {
      console.log(isCreate ? '创建成功' : '编辑成功');
      queryClient.invalidateQueries({ queryKey: ['versions'] });
      setEditId(null);
      setIsCreate(false);
      form.reset();
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => versionApi.delete(id),
    onSuccess: () => {
      console.log('删除成功');
      queryClient.invalidateQueries({ queryKey: ['versions'] });
      setDeleteId(null);
    },
  });

  const openCreate = () => {
    form.reset({ versionName: '', versionCode: 0, url: '', description: '', cid: 'all', forceUpdate: false, enabled: true });
    setIsCreate(true);
    setEditId(-1);
  };

  const openEdit = (id: number) => {
    setIsCreate(false);
    setEditId(id);
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-xl font-bold">版本管理</h1>
        <Button color="primary" onPress={openCreate}>新建版本</Button>
      </div>

      <Table
        aria-label="版本列表"
        bottomContent={
          data && data.total > 0 ? (
            <div className="flex justify-center">
              <Pagination
                total={Math.ceil(data.total / data.pageSize)}
                page={page}
                onChange={setPage}
              />
            </div>
          ) : null
        }
      >
        <TableHeader>
          <TableColumn>版本名</TableColumn>
          <TableColumn>版本码</TableColumn>
          <TableColumn>渠道</TableColumn>
          <TableColumn>强制更新</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>创建时间</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody isLoading={isLoading} items={data?.list || []} emptyContent="暂无版本">
          {(v) => (
            <TableRow key={v.id}>
              <TableCell>{v.versionName}</TableCell>
              <TableCell>{v.versionCode}</TableCell>
              <TableCell>{v.cid}</TableCell>
              <TableCell>
                <Chip size="sm" color={v.forceUpdate ? 'warning' : 'default'}>
                  {v.forceUpdate ? '是' : '否'}
                </Chip>
              </TableCell>
              <TableCell>
                <Chip size="sm" color={v.enabled ? 'success' : 'default'}>
                  {v.enabled ? '启用' : '禁用'}
                </Chip>
              </TableCell>
              <TableCell>{fmtDate(v.createTime)}</TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Button size="sm" variant="flat" onPress={() => openEdit(v.id)}>编辑</Button>
                  <Button size="sm" variant="flat" color="danger" onPress={() => setDeleteId(v.id)}>删除</Button>
                </div>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      <Modal isOpen={editId !== null} onClose={() => { setEditId(null); setIsCreate(false); form.reset(); }} size="lg">
        <ModalContent>
          <ModalHeader>{isCreate ? '新建版本' : '编辑版本'}</ModalHeader>
          <ModalBody>
            <form className="space-y-3">
              <Input label="版本名 (如 1.2.0)" {...form.register('versionName')} isInvalid={!!form.formState.errors.versionName} errorMessage={form.formState.errors.versionName?.message} />
              <Input label="版本码 (正整数)" type="number" {...form.register('versionCode')} isInvalid={!!form.formState.errors.versionCode} errorMessage={form.formState.errors.versionCode?.message} />
              <Input label="下载 URL" {...form.register('url')} />
              <Input label="更新说明" {...form.register('description')} />
              <Input label="渠道" {...form.register('cid')} />
              <Switch {...form.register('forceUpdate')}>强制更新</Switch>
              <Switch {...form.register('enabled')}>启用</Switch>
            </form>
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => { setEditId(null); setIsCreate(false); form.reset(); }}>取消</Button>
            <Button color="primary" isLoading={saveMutation.isPending} onPress={() => form.handleSubmit((d) => saveMutation.mutate(d))()}>保存</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      <Modal isOpen={deleteId !== null} onClose={() => setDeleteId(null)}>
        <ModalContent>
          <ModalHeader>确认删除</ModalHeader>
          <ModalBody><p>确认删除此版本？</p></ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setDeleteId(null)}>取消</Button>
            <Button color="danger" isLoading={deleteMutation.isPending} onPress={() => deleteMutation.mutate(deleteId!)}>删除</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
