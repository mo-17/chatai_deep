import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { mcpApi } from '@/lib/api/mcp';
import type { McpServerInput } from '@/types/mcp';

export function useMcpServers() {
  return useQuery({
    queryKey: ['mcp', 'servers'],
    queryFn: () => mcpApi.list().then((d) => d.list),
  });
}

export function useMcpMutations() {
  const qc = useQueryClient();
  const invalidate = () => qc.invalidateQueries({ queryKey: ['mcp'] });

  const create = useMutation({
    mutationFn: (body: McpServerInput) => mcpApi.create(body),
    onSuccess: invalidate,
  });

  const update = useMutation({
    mutationFn: ({ id, ...body }: Partial<McpServerInput> & { id: number }) =>
      mcpApi.update(id, body),
    onSuccess: invalidate,
  });

  const remove = useMutation({
    mutationFn: (id: number) => mcpApi.remove(id),
    onSuccess: invalidate,
  });

  const test = useMutation({
    mutationFn: (id: number) => mcpApi.test(id),
  });

  return { create, update, remove, test };
}
