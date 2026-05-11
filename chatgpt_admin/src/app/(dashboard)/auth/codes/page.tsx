'use client';

import { useState, useEffect } from 'react';
import { Table, TableHeader, TableColumn, TableBody, TableRow, TableCell, Chip, Select, SelectItem } from '@nextui-org/react';
import { fetchCodes } from '@/lib/api/auth-admin';
import type { CodeRecord } from '@/lib/api/auth-admin';

export default function AuthCodesPage() {
  const [items, setItems] = useState<CodeRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [channel, setChannel] = useState<string | undefined>();
  const [purpose, setPurpose] = useState<string | undefined>();

  useEffect(() => {
    fetchCodes({ page, pageSize: 20, channel, purpose })
      .then(r => { setItems(r.items); setTotal(r.total); })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [page, channel, purpose]);

  const purposeLabel = (p: string) => {
    const map: Record<string, string> = { login: '登录', register: '注册', bind: '绑定', reset_password: '重置密码' };
    return map[p] || p;
  };

  const prevPage = () => { setLoading(true); setPage(p => Math.max(1, p - 1)); };
  const nextPage = () => { setLoading(true); setPage(p => p + 1); };
  const changeChannel = (k: Iterable<unknown>) => { setLoading(true); setChannel(Array.from(k)[0] as string); setPage(1); };
  const changePurpose = (k: Iterable<unknown>) => { setLoading(true); setPurpose(Array.from(k)[0] as string); setPage(1); };

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">验证码记录</h1>
      <div className="flex gap-3">
        <Select label="通道" size="sm" className="w-32" selectedKeys={channel ? [channel] : []} onSelectionChange={changeChannel}>
          <SelectItem key="email">邮箱</SelectItem>
          <SelectItem key="sms">短信</SelectItem>
        </Select>
        <Select label="用途" size="sm" className="w-32" selectedKeys={purpose ? [purpose] : []} onSelectionChange={changePurpose}>
          <SelectItem key="login">登录</SelectItem>
          <SelectItem key="register">注册</SelectItem>
          <SelectItem key="bind">绑定</SelectItem>
          <SelectItem key="reset_password">重置密码</SelectItem>
        </Select>
      </div>
      <Table aria-label="验证码记录" bottomContent={
        <div className="flex justify-between w-full text-sm">
          <span>共 {total} 条</span>
          <div className="flex gap-2">
            <button onClick={prevPage} disabled={page <= 1} className="px-2 py-1 rounded hover:bg-default-200 disabled:opacity-30">上一页</button>
            <button onClick={nextPage} disabled={items.length < 20} className="px-2 py-1 rounded hover:bg-default-200 disabled:opacity-30">下一页</button>
          </div>
        </div>
      }>
        <TableHeader>
          <TableColumn>通道</TableColumn>
          <TableColumn>标识</TableColumn>
          <TableColumn>用途</TableColumn>
          <TableColumn>尝试次数</TableColumn>
          <TableColumn>IP</TableColumn>
          <TableColumn>状态</TableColumn>
          <TableColumn>备注</TableColumn>
          <TableColumn>创建时间</TableColumn>
        </TableHeader>
        <TableBody isLoading={loading} items={items} emptyContent="暂无记录">
          {(r) => (
            <TableRow key={r.id} className={r.note === 'MOCK' ? 'bg-yellow-50' : undefined}>
              <TableCell><Chip size="sm" variant="flat" color={r.channel === 'email' ? 'primary' : 'secondary'}>{r.channel}</Chip></TableCell>
              <TableCell className="text-sm">{r.identifier}</TableCell>
              <TableCell><Chip size="sm">{purposeLabel(r.purpose)}</Chip></TableCell>
              <TableCell>{r.attempts}</TableCell>
              <TableCell className="text-xs text-default-500">{r.ipAddress}</TableCell>
              <TableCell>{r.consumedAt ? <Chip size="sm" color="success">已消费</Chip> : new Date(r.expiresAt) < new Date() ? <Chip size="sm" color="danger">已过期</Chip> : <Chip size="sm" color="warning">待验证</Chip>}</TableCell>
              <TableCell className={r.note === 'MOCK' ? 'text-yellow-600 font-semibold text-xs' : 'text-xs text-default-400'}>{r.note || '-'}</TableCell>
              <TableCell className="text-xs text-default-500">{new Date(r.createdAt).toLocaleString()}</TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  );
}
