'use client';

import { useQuery } from '@tanstack/react-query';
import { Card, CardBody, Skeleton } from '@heroui/react';
import { usageApi } from '@/lib/api/usage';
import { fmtTokens, fmtNum } from '@/lib/utils/format';
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
  ResponsiveContainer,
  BarChart,
  Bar,
} from 'recharts';

export default function DashboardPage() {
  const { data: summary, isLoading: sLoading } = useQuery({
    queryKey: ['usage', 'summary'],
    queryFn: () => usageApi.summary(),
  });

  const { data: series, isLoading: seLoading } = useQuery({
    queryKey: ['usage', 'series', 30],
    queryFn: () => usageApi.series(),
  });

  const { data: byProvider, isLoading: pLoading } = useQuery({
    queryKey: ['usage', 'by-provider'],
    queryFn: () => usageApi.byProvider(),
  });

  const { data: topUsers, isLoading: tLoading } = useQuery({
    queryKey: ['usage', 'top-users', 7, 10],
    queryFn: () => usageApi.topUsers(10, 7),
  });

  const kpis = [
    { label: '今日 Token', value: summary?.today.tokens, calls: summary?.today.calls },
    { label: '本周 Token', value: summary?.week.tokens, calls: summary?.week.calls },
    { label: '本月 Token', value: summary?.month.tokens, calls: summary?.month.calls },
    { label: '全部 Token', value: summary?.all.tokens, calls: summary?.all.calls },
  ];

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        {kpis.map((kpi) => (
          <Card key={kpi.label}>
            <CardBody className="p-4">
              {sLoading ? (
                <Skeleton className="h-16 rounded" />
              ) : (
                <>
                  <p className="text-sm text-default-500">{kpi.label}</p>
                  <p className="text-2xl font-bold">{fmtTokens(kpi.value || 0)}</p>
                  <p className="text-xs text-default-400 mt-1">
                    调用次数: {fmtNum(kpi.calls || 0)}
                  </p>
                </>
              )}
            </CardBody>
          </Card>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card>
          <CardBody className="p-4">
            <h3 className="font-semibold mb-4">近 30 天 Token 趋势</h3>
            {seLoading ? (
              <Skeleton className="h-64 rounded" />
            ) : (
              <ResponsiveContainer width="100%" height={280}>
                <LineChart data={series?.list || []}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="date" tick={{ fontSize: 11 }} />
                  <YAxis tick={{ fontSize: 11 }} />
                  <Tooltip />
                  <Line
                    type="monotone"
                    dataKey="tokens"
                    stroke="#006FEE"
                    strokeWidth={2}
                  />
                </LineChart>
              </ResponsiveContainer>
            )}
          </CardBody>
        </Card>

        <Card>
          <CardBody className="p-4">
            <h3 className="font-semibold mb-4">Provider 分布</h3>
            {pLoading ? (
              <Skeleton className="h-64 rounded" />
            ) : (
              <ResponsiveContainer width="100%" height={280}>
                <BarChart data={byProvider?.list || []}>
                  <CartesianGrid strokeDasharray="3 3" />
                  <XAxis dataKey="provider" tick={{ fontSize: 11 }} />
                  <YAxis tick={{ fontSize: 11 }} />
                  <Tooltip />
                  <Bar dataKey="tokens" fill="#17C964" />
                </BarChart>
              </ResponsiveContainer>
            )}
          </CardBody>
        </Card>
      </div>

      <Card>
        <CardBody className="p-4">
          <h3 className="font-semibold mb-4">Top 10 用户 (近 7 天)</h3>
          {tLoading ? (
            <Skeleton className="h-48 rounded" />
          ) : (
            <div className="space-y-2">
              {(topUsers?.list || []).map((u, i) => (
                <div
                  key={u.userId}
                  className="flex items-center justify-between py-2 border-b border-default-100 last:border-0"
                >
                  <div className="flex items-center gap-3">
                    <span className="text-sm text-default-400 w-6">{i + 1}</span>
                    <span className="text-sm font-medium">{u.userName}</span>
                  </div>
                  <span className="text-sm text-default-600">
                    {fmtTokens(u.tokens)} / {fmtNum(u.calls)} 次
                  </span>
                </div>
              ))}
            </div>
          )}
        </CardBody>
      </Card>
    </div>
  );
}
