'use client';

import { useState, useEffect } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import {
  Table, TableHeader, TableColumn, TableBody, TableRow, TableCell,
  Button, Chip, Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
  Input, Switch, Pagination,
} from '@heroui/react';
import { addToast } from '@heroui/react';
import { bannerApi } from '@/lib/api/banner';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { bannerSchema, type BannerForm } from '@/schemas/banner';
import { fmtDate } from '@/lib/utils/format';

export default function BannersPage() {
  const queryClient = useQueryClient();
  const [page, setPage] = useState(1);
  const [editId, setEditId] = useState<number | null>(null);
  const [deleteId, setDeleteId] = useState<number | null>(null);
  const [isCreate, setIsCreate] = useState(false);

  const { data, isLoading } = useQuery({
    queryKey: ['banners', page],
    queryFn: () => bannerApi.list({ page, pageSize: 10 }),
  });

  const form = useForm<BannerForm>({
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    resolver: zodResolver(bannerSchema) as any,
    defaultValues: { title: '', subtitle: '', cover: '', url: '', sticky: 0, enabled: true, type: 'banner' },
  });

  const { data: editData } = useQuery({
    queryKey: ['banner', editId],
    queryFn: () => bannerApi.detail(editId!),
    enabled: editId !== null && !isCreate,
  });

  useEffect(() => {
    if (editData && editId !== null && !isCreate) {
      form.reset({
        title: editData.title,
        subtitle: editData.subtitle || '',
        cover: editData.cover || '',
        url: editData.url || '',
        sticky: editData.sticky,
        enabled: editData.enabled,
        type: editData.type,
      });
    }
  }, [editData, editId, isCreate, form]);

  const saveMutation = useMutation({
    mutationFn: (body: BannerForm) =>
      isCreate ? bannerApi.create(body) : bannerApi.edit(editId!, body),
    onSuccess: () => {
      addToast({ title: isCreate ? '创建成功' : '编辑成功', severity: 'success' });
      queryClient.invalidateQueries({ queryKey: ['banners'] });
      setEditId(null);
      setIsCreate(false);
      form.reset();
    },
    onError: (e: Error) => addToast({ title: e.message, severity: 'danger' }),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => bannerApi.delete(id),
    onSuccess: () => {
      addToast({ title: '删除成功', severity: 'success' });
      queryClient.invalidateQueries({ queryKey: ['banners'] });
      setDeleteId(null);
    },
    onError: (e: Error) => addToast({ title: e.message, severity: 'danger' }),
  });

  const openCreate = () => {
    form.reset({ title: '', subtitle: '', cover: '', url: '', sticky: 0, enabled: true, type: 'banner' });
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
        <h1 className="text-xl font-bold">Banner 管理</h1>
        <Button color="primary" onPress={openCreate}>新建 Banner</Button>
      </div>

      <Table
        aria-label="Banner 列表"
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
          <TableColumn>封面</TableColumn>
          <TableColumn>标题</TableColumn>
          <TableColumn>副标题</TableColumn>
          <TableColumn>置顶</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>创建时间</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody isLoading={isLoading} items={data?.list || []} emptyContent="暂无 Banner">
          {(b) => (
            <TableRow key={b.id}>
              <TableCell>
                {b.cover ? <img src={b.cover} className="w-12 h-8 object-cover rounded" alt="" /> : '-'}
              </TableCell>
              <TableCell>{b.title}</TableCell>
              <TableCell>{b.subtitle || '-'}</TableCell>
              <TableCell>{b.sticky}</TableCell>
              <TableCell>
                <Chip size="sm" color={b.enabled ? 'success' : 'default'}>
                  {b.enabled ? '上架' : '下架'}
                </Chip>
              </TableCell>
              <TableCell>{fmtDate(b.createTime)}</TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Button size="sm" variant="flat" onPress={() => openEdit(b.id)}>编辑</Button>
                  <Button size="sm" variant="flat" color="danger" onPress={() => setDeleteId(b.id)}>删除</Button>
                </div>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      {/* Create/Edit Modal */}
      <Modal isOpen={editId !== null} onClose={() => { setEditId(null); setIsCreate(false); form.reset(); }} size="lg">
        <ModalContent>
          <ModalHeader>{isCreate ? '新建 Banner' : '编辑 Banner'}</ModalHeader>
          <ModalBody>
            <form className="space-y-3">
              <Input label="标题" {...form.register('title')} isInvalid={!!form.formState.errors.title} errorMessage={form.formState.errors.title?.message} />
              <Input label="副标题" {...form.register('subtitle')} />
              <Input label="封面 URL" {...form.register('cover')} />
              <Input label="链接 URL" {...form.register('url')} />
              <Input label="置顶权重" type="number" {...form.register('sticky', { valueAsNumber: true })} />
              <Controller
                name="enabled"
                control={form.control}
                render={({ field }) => (
                  <Switch isSelected={field.value} onValueChange={field.onChange}>启用</Switch>
                )}
              />
            </form>
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => { setEditId(null); setIsCreate(false); form.reset(); }}>取消</Button>
            <Button color="primary" isLoading={saveMutation.isPending} onPress={() => form.handleSubmit((d) => saveMutation.mutate(d))()}>保存</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      {/* Delete Confirm */}
      <Modal isOpen={deleteId !== null} onClose={() => setDeleteId(null)}>
        <ModalContent>
          <ModalHeader>确认删除</ModalHeader>
          <ModalBody><p>确认删除此 Banner？</p></ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setDeleteId(null)}>取消</Button>
            <Button color="danger" isLoading={deleteMutation.isPending} onPress={() => deleteMutation.mutate(deleteId!)}>删除</Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
