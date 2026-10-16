'use client';

import { useState, useCallback, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useSearchParams, useRouter } from 'next/navigation';
import {
  Table,
  TableHeader,
  TableColumn,
  TableBody,
  TableRow,
  TableCell,
  Input,
  Button,
  Pagination,
  Select,
  SelectItem,
} from '@heroui/react';
import { usageApi } from '@/lib/api/usage';
import { fmtTokens, fmtDate } from '@/lib/utils/format';
import { useAuthStore } from '@/store/authStore';
import {
  captureChatScope,
  chatScopeKey,
  chatContextSignature,
  chatScopeCurrent,
} from '@/lib/chat/scope';

export default function UsagePage() {
  useAuthStore((s) => s.sessionEpoch);
  useAuthStore((s) => s.token);
  useAuthStore((s) => s.admin?.id);
  const signature = chatContextSignature();
  const scope = useMemo(() => {
    try {
      if (signature !== chatContextSignature()) return null;
      return captureChatScope();
    } catch {
      return null;
    }
  }, [signature]);
  const scopeKey = scope
    ? JSON.stringify([chatScopeKey(scope), scope.session.epoch])
    : 'unavailable';
  const [exportError, setExportError] = useState(false);
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

  const {
    data,
    isLoading,
    isError,
    refetch: refetchList,
  } = useQuery({
    enabled: !!scope,
    retry: false,
    queryKey: [
      'usage',
      scopeKey,
      'list',
      page,
      userId,
      provider,
      model,
      from,
      to,
    ],
    queryFn: () =>
      usageApi.list(
        {
          page,
          pageSize: 10,
          userId: userId || undefined,
          provider: provider || undefined,
          model: model || undefined,
          from: from || undefined,
          to: to || undefined,
        },
        scope!,
      ),
  });

  const options = useQuery({
    queryKey: ['usage-provider-options', scopeKey],
    enabled: !!scope,
    retry: false,
    queryFn: () => usageApi.providerOptions(scope!),
  });
  const providerOptions = options.data ? [...options.data] : [];
  if (provider && !providerOptions.some((p) => p.key === provider))
    providerOptions.push({ key: provider, label: `${provider}（原筛选值）` });
  const handleExport = async () => {
    if (!scope || !chatScopeCurrent(scope)) return;
    setExportError(false);
    try {
      await usageApi.exportCsv(
        {
          userId: userId || undefined,
          provider: provider || undefined,
          model: model || undefined,
          from: from || undefined,
          to: to || undefined,
        },
        scope,
      );
    } catch {
      if (chatContextSignature() === signature) setExportError(true);
    }
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
          selectedKeys={provider ? [provider] : []}
          onSelectionChange={(keys) => {
            const first =
              keys === 'all' ? '' : (Array.from(keys)[0] as string | undefined);
            setProvider(first ?? '');
          }}
          className="max-w-36"
        >
          {[
            <SelectItem key="" textValue="全部">
              全部
            </SelectItem>,
            ...providerOptions.map((p) => (
              <SelectItem key={p.key} textValue={p.label}>
                {p.label}
              </SelectItem>
            )),
          ]}
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

      {options.isLoading && <p role="status">服务商筛选加载中</p>}
      {options.isError && (
        <p role="alert">
          服务商筛选读取失败，原筛选值保留。
          <Button
            size="sm"
            onPress={() => {
              void options.refetch();
            }}
          >
            重试筛选读取
          </Button>
        </p>
      )}
      {options.isSuccess && providerOptions.length === 0 && (
        <p role="status">暂无服务商或历史用量</p>
      )}
      {isError && (
        <p role="alert">
          用量列表读取失败，请重新读取。
          <Button
            size="sm"
            onPress={() => {
              if (scope && chatScopeCurrent(scope)) void refetchList();
            }}
          >
            重试用量列表
          </Button>
        </p>
      )}
      {exportError && (
        <p role="alert">
          导出未完成，请明确重试导出。
          <Button size="sm" onPress={handleExport}>
            重试导出
          </Button>
        </p>
      )}
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
