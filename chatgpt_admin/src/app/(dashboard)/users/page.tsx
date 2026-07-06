'use client';

import { useState, useCallback } from 'react';
import Image from 'next/image';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useSearchParams, useRouter } from 'next/navigation';
import { useDebounce } from 'ahooks';
import {
  Table,
  TableHeader,
  TableColumn,
  TableBody,
  TableRow,
  TableCell,
  Input,
  Button,
  Chip,
  Pagination,
  Modal,
  ModalContent,
  ModalHeader,
  ModalBody,
  ModalFooter,
  Select,
  SelectItem,
} from '@heroui/react';
import { userApi } from '@/lib/api/user';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { resetPasswordSchema, type ResetPasswordForm } from '@/schemas/user';

export default function UsersPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const queryClient = useQueryClient();

  const [keyword, setKeyword] = useState(searchParams.get('keyword') || '');
  const debouncedKeyword = useDebounce(keyword, { wait: 400 });
  const [page, setPage] = useState(Number(searchParams.get('page')) || 1);
  const [role, setRole] = useState(searchParams.get('role') || '');
  const [banned, setBanned] = useState(searchParams.get('banned') || '');
  const [resetId, setResetId] = useState<number | null>(null);
  const [deleteId, setDeleteId] = useState<number | null>(null);

  const updateUrl = useCallback(
    (p: number, kw: string) => {
      const params = new URLSearchParams();
      if (kw) params.set('keyword', kw);
      if (p > 1) params.set('page', String(p));
      if (role) params.set('role', role);
      if (banned) params.set('banned', banned);
      router.replace(`/users?${params.toString()}`);
    },
    [router, role, banned],
  );

  const { data, isLoading } = useQuery({
    queryKey: ['users', debouncedKeyword, page, role, banned],
    queryFn: () =>
      userApi.list({ keyword: debouncedKeyword, page, pageSize: 10, role: role || undefined, banned: banned || undefined }),
  });

  const banMutation = useMutation({
    mutationFn: ({ id, ban }: { id: number; ban: boolean }) =>
      userApi.edit(id, { banned: ban }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['users'] }),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => userApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['users'] });
      setDeleteId(null);
    },
  });

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<ResetPasswordForm>({ resolver: zodResolver(resetPasswordSchema) });

  const resetMutation = useMutation({
    mutationFn: ({ id, password }: { id: number; password: string }) =>
      userApi.resetPassword(id, password),
    onSuccess: () => {
      console.log('密码已重置');
      setResetId(null);
      reset();
    },
  });

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">用户管理</h1>

      <div className="flex gap-3 flex-wrap">
        <Input
          placeholder="搜索用户名..."
          value={keyword}
          onValueChange={(v) => {
            setKeyword(v);
            setPage(1);
          }}
          className="max-w-xs"
        />
        <Select
          label="角色"
          selectedKeys={role ? [role] : []}
          onSelectionChange={(keys) => {
            const first = keys === 'all' ? '' : (Array.from(keys)[0] as string | undefined);
            setRole(first ?? '');
          }}
          className="max-w-32"
        >
          <SelectItem key="">全部</SelectItem>
          <SelectItem key="user">用户</SelectItem>
          <SelectItem key="admin">管理员</SelectItem>
        </Select>
        <Select
          label="状态"
          selectedKeys={banned ? [banned] : []}
          onSelectionChange={(keys) => {
            const first = keys === 'all' ? '' : (Array.from(keys)[0] as string | undefined);
            setBanned(first ?? '');
          }}
          className="max-w-32"
        >
          <SelectItem key="">全部</SelectItem>
          <SelectItem key="false">正常</SelectItem>
          <SelectItem key="true">已封禁</SelectItem>
        </Select>
      </div>

      <Table
        aria-label="用户列表"
        bottomContent={
          data && data.total > 0 ? (
            <div className="flex justify-center">
              <Pagination
                total={Math.ceil(data.total / data.pageSize)}
                page={page}
                onChange={(p) => {
                  setPage(p);
                  updateUrl(p, debouncedKeyword);
                }}
              />
            </div>
          ) : null
        }
      >
        <TableHeader>
          <TableColumn>ID</TableColumn>
          <TableColumn>头像</TableColumn>
          <TableColumn>用户名</TableColumn>
          <TableColumn>邮箱</TableColumn>
          <TableColumn>手机号</TableColumn>
          <TableColumn>角色</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>操作</TableColumn>
        </TableHeader>
        <TableBody
          isLoading={isLoading}
          items={data?.list || []}
          emptyContent="暂无用户"
        >
          {(user) => (
            <TableRow key={user.id}>
              <TableCell>{user.id}</TableCell>
              <TableCell>
                {user.avatar ? (
                  <Image
                    src={user.avatar}
                    width={32}
                    height={32}
                    unoptimized
                    className="w-8 h-8 rounded-full object-cover"
                    alt=""
                  />
                ) : null}
              </TableCell>
              <TableCell>{user.userName}</TableCell>
              <TableCell className="text-xs">{user.email || '-'}</TableCell>
              <TableCell className="text-xs">
                {user.phoneNumber ? `${user.countryCode ?? ''} ${user.phoneNumber}` : '-'}
              </TableCell>
              <TableCell>
                <Chip size="sm" color={user.role === 'admin' ? 'warning' : 'default'}>
                  {user.role === 'admin' ? '管理员' : '用户'}
                </Chip>
              </TableCell>
              <TableCell>
                <Chip size="sm" color={user.banned ? 'danger' : 'success'}>
                  {user.banned ? '已封禁' : '正常'}
                </Chip>
              </TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Button
                    size="sm"
                    variant="flat"
                    onPress={() => router.push(`/users/${user.id}`)}
                  >
                    查看
                  </Button>
                  <Button
                    size="sm"
                    variant="flat"
                    onPress={() => setResetId(user.id)}
                  >
                    重置密码
                  </Button>
                  <Button
                    size="sm"
                    variant="flat"
                    color={user.banned ? 'success' : 'warning'}
                    onPress={() =>
                      banMutation.mutate({ id: user.id, ban: !user.banned })
                    }
                  >
                    {user.banned ? '解封' : '封禁'}
                  </Button>
                  <Button
                    size="sm"
                    variant="flat"
                    color="danger"
                    onPress={() => setDeleteId(user.id)}
                  >
                    删除
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      <Modal isOpen={resetId !== null} onClose={() => setResetId(null)}>
        <ModalContent>
          <ModalHeader>重置密码</ModalHeader>
          <ModalBody>
            <form id="reset-form" onSubmit={handleSubmit((d) => resetMutation.mutate({ id: resetId!, password: d.password }))}>
              <Input
                label="新密码"
                type="password"
                {...register('password')}
                isInvalid={!!errors.password}
                errorMessage={errors.password?.message}
              />
            </form>
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setResetId(null)}>
              取消
            </Button>
            <Button
              color="primary"
              isLoading={resetMutation.isPending}
              onPress={() => document.getElementById('reset-form')?.dispatchEvent(new Event('submit', { cancelable: true, bubbles: true }))}
            >
              确认
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>

      <Modal isOpen={deleteId !== null} onClose={() => setDeleteId(null)}>
        <ModalContent>
          <ModalHeader>确认删除</ModalHeader>
          <ModalBody>
            <p className="text-danger">
              将同时删除该用户的全部用量记录，此操作不可撤销。
            </p>
          </ModalBody>
          <ModalFooter>
            <Button variant="flat" onPress={() => setDeleteId(null)}>
              取消
            </Button>
            <Button
              color="danger"
              isLoading={deleteMutation.isPending}
              onPress={() => deleteMutation.mutate(deleteId!)}
            >
              确认删除
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </div>
  );
}
