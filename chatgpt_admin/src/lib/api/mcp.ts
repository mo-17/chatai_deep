import { api } from './client';
import type { McpServer, McpServerInput, McpTestResult } from '@/types/mcp';

export const mcpApi = {
  list: () =>
    api.get<{ list: McpServer[] }>('/admin/mcp/servers').then((r) => r.data),

  create: (body: McpServerInput) =>
    api.post<McpServer>('/admin/mcp/servers', body).then((r) => r.data),

  update: (id: number, body: Partial<McpServerInput>) =>
    api.patch<McpServer>(`/admin/mcp/servers/${id}`, body).then((r) => r.data),

  remove: (id: number) => api.delete(`/admin/mcp/servers/${id}`),

  test: (id: number) =>
    api
      .post<McpTestResult>(`/admin/mcp/servers/${id}/test`)
      .then((r) => r.data),
};
