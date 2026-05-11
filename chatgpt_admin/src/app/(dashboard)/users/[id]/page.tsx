'use client';

import { useParams } from 'next/navigation';
import { useQuery } from '@tanstack/react-query';
import { Card, CardBody, CardHeader, Chip, Skeleton, Table, TableHeader, TableColumn, TableBody, TableRow, TableCell } from '@heroui/react';
import { userApi } from '@/lib/api/user';
import { usageApi } from '@/lib/api/usage';
import { fmtTokens, fmtDate } from '@/lib/utils/format';
import { ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid } from 'recharts';

export default function UserDetailPage() {
  const params = useParams();
  const id = Number(params.id);

  const { data: user, isLoading } = useQuery({
    queryKey: ['user', id],
    queryFn: () => userApi.detail(id),
  });

  const { data: series } = useQuery({
    queryKey: ['usage', 'series', 'user', id],
    queryFn: () => usageApi.series(),
  });

  const { data: usageList } = useQuery({
    queryKey: ['usage', 'list', id],
    queryFn: () => usageApi.list({ userId: id, page: 1, pageSize: 20 }),
  });

  if (isLoading) return <Skeleton className="h-64 rounded" />;
  if (!user) return <p>用户不存在</p>;

  return (
    <div className="space-y-6">
      <h1 className="text-xl font-bold">用户详情</h1>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <Card>
          <CardHeader>基本信息</CardHeader>
          <CardBody className="space-y-2">
            {user.avatar && (
              <img src={user.avatar} className="w-16 h-16 rounded-full" alt="" />
            )}
            <p><span className="text-default-500">用户名:</span> {user.userName}</p>
            <p>
              <span className="text-default-500">角色:</span>{' '}
              <Chip size="sm" color={user.role === 'admin' ? 'warning' : 'default'}>
                {user.role === 'admin' ? '管理员' : '用户'}
              </Chip>
            </p>
            <p>
              <span className="text-default-500">状态:</span>{' '}
              <Chip size="sm" color={user.banned ? 'danger' : 'success'}>
                {user.banned ? '已封禁' : '正常'}
              </Chip>
            </p>
          </CardBody>
        </Card>

        <Card className="lg:col-span-2">
          <CardBody className="p-4">
            <h3 className="font-semibold mb-4">近 30 天用量</h3>
            <ResponsiveContainer width="100%" height={220}>
              <LineChart data={series?.list || []}>
                <CartesianGrid strokeDasharray="3 3" />
                <XAxis dataKey="date" tick={{ fontSize: 11 }} />
                <YAxis tick={{ fontSize: 11 }} />
                <Tooltip />
                <Line type="monotone" dataKey="tokens" stroke="#006FEE" strokeWidth={2} />
              </LineChart>
            </ResponsiveContainer>
          </CardBody>
        </Card>
      </div>

      <Card>
        <CardBody className="p-4">
          <h3 className="font-semibold mb-4">用量明细</h3>
          <Table aria-label="用户用量">
            <TableHeader>
              <TableColumn>ID</TableColumn>
              <TableColumn>Provider</TableColumn>
              <TableColumn>Model</TableColumn>
              <TableColumn>Prompt</TableColumn>
              <TableColumn>Completion</TableColumn>
              <TableColumn>Total</TableColumn>
              <TableColumn>时间</TableColumn>
            </TableHeader>
            <TableBody items={usageList?.list || []} emptyContent="暂无记录">
              {(r) => (
                <TableRow key={r.id}>
                  <TableCell>{r.id}</TableCell>
                  <TableCell>{r.provider}</TableCell>
                  <TableCell>{r.model}</TableCell>
                  <TableCell>{fmtTokens(r.promptTokens)}</TableCell>
                  <TableCell>{fmtTokens(r.completionTokens)}</TableCell>
                  <TableCell>{fmtTokens(r.totalTokens)}</TableCell>
                  <TableCell>{fmtDate(r.createdAt)}</TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </CardBody>
      </Card>
    </div>
  );
}
