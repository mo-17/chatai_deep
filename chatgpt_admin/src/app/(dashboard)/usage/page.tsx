'use client';

import { useState, useCallback } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useSearchParams, useRouter } from 'next/navigation';
import {
  Table, TableHeader, TableColumn, TableBody, TableRow, TableCell,
  Input, Button, Pagination, Select, SelectItem,
} from '@nextui-org/react';
import { usageApi } from '@/lib/api/usage';
import { fmtTokens, fmtDate } from '@/lib/utils/format';

export default function UsagePage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [page, setPage] = useState(Number(searchParams.get('page')) || 1);
  const [userId, setUserId] = useState(searchParams.get('userId') || '');
  const [provider, setProvider] = useState(searchParams.get('provider') || '');
  const [model, setModel] = useState(searchParams.get('model') || '');
  const [from, setFrom] = useState(searchParams.get('from') || '');
  const [to, setTo] = useState(searchParams.get('to') || '');

  const updateUrl = useCallback(
    (p: number) => {
      const params = new URLSearchParams();
      if (userId) params.set('userId', userId);
      if (provider) params.set('provider', provider);
      if (model) params.set('model', model);
      if (from) params.set('from', from);
      if (to) params.set('to', to);
      if (p > 1) params.set('page', String(p));
      router.replace(`/usage?${params.toString()}`);
    },
    [router, userId, provider, model, from, to],
  );

  const { data, isLoading } = useQuery({
    queryKey: ['usage', 'list', page, userId, provider, model, from, to],
    queryFn: () =>
      usageApi.list({
        page,
        pageSize: 10,
        userId: userId || undefined,
        provider: provider || undefined,
        model: model || undefined,
        from: from || undefined,
        to: to || undefined,
      }),
  });

  const handleExport = () => {
    usageApi.exportCsv({
      userId: userId || undefined,
      provider: provider || undefined,
      model: model || undefined,
      from: from || undefined,
      to: to || undefined,
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-xl font-bold">用量明细</h1>
        <Button color="primary" variant="flat" onPress={handleExport}>
          导出 CSV
        </Button>
      </div>

      <div className="flex gap-3 flex-wrap">
        <Input
          placeholder="用户ID"
          value={userId}
          onValueChange={setUserId}
          className="max-w-28"
        />
        <Select
          label="Provider"
          selectedKey={provider}
          onSelectionChange={(k) => setProvider((k as string) || '')}
          className="max-w-36"
        >
          <SelectItem key="">全部</SelectItem>
          <SelectItem key="openai">OpenAI</SelectItem>
          <SelectItem key="deepseek">DeepSeek</SelectItem>
        </Select>
        <Input
          placeholder="Model"
          value={model}
          onValueChange={setModel}
          className="max-w-36"
        />
        <Input
          label="从"
          type="date"
          value={from}
          onValueChange={setFrom}
          className="max-w-40"
        />
        <Input
          label="到"
          type="date"
          value={to}
          onValueChange={setTo}
          className="max-w-40"
        />
      </div>

      <Table
        aria-label="用量明细"
        bottomContent={
          data && data.total > 0 ? (
            <div className="flex justify-center">
              <Pagination
                total={Math.ceil(data.total / data.pageSize)}
                page={page}
                onChange={(p) => {
                  setPage(p);
                  updateUrl(p);
                }}
              />
            </div>
          ) : null
        }
      >
        <TableHeader>
          <TableColumn>ID</TableColumn>
          <TableColumn>用户名</TableColumn>
          <TableColumn>Provider</TableColumn>
          <TableColumn>Model</TableColumn>
          <TableColumn>Prompt</TableColumn>
          <TableColumn>Completion</TableColumn>
          <TableColumn>Total</TableColumn>
          <TableColumn>时间</TableColumn>
        </TableHeader>
        <TableBody
          isLoading={isLoading}
          items={data?.list || []}
          emptyContent="暂无记录"
        >
          {(r) => (
            <TableRow key={r.id}>
              <TableCell>{r.id}</TableCell>
              <TableCell>{r.userName}</TableCell>
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
    </div>
  );
}
