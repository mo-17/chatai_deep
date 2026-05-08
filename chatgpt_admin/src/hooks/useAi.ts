import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { aiApi } from '@/lib/api/ai';
import type { AiProvider, AiModel, AiGlobalConfig } from '@/types/ai';

export function useProviders() {
  return useQuery({
    queryKey: ['ai', 'providers'],
    queryFn: () => aiApi.listProviders().then((d) => d.list),
  });
}

export function useProvider(id: number | null) {
  return useQuery({
    queryKey: ['ai', 'providers', id],
    queryFn: () => aiApi.getProvider(id!),
    enabled: id !== null && id > 0,
  });
}

export function useModels(params?: {
  providerId?: string;
  enabled?: string;
  keyword?: string;
}) {
  return useQuery({
    queryKey: ['ai', 'models', params],
    queryFn: () => aiApi.listModels(params).then((d) => d.list),
  });
}

export function useModel(id: number | null) {
  return useQuery({
    queryKey: ['ai', 'models', id],
    queryFn: () => aiApi.getModel(id!),
    enabled: id !== null && id > 0,
  });
}

export function useGlobalConfig() {
  return useQuery({
    queryKey: ['ai', 'global'],
    queryFn: () => aiApi.getGlobal(),
  });
}

export function useAiMutations() {
  const qc = useQueryClient();
  const invalidate = () => qc.invalidateQueries({ queryKey: ['ai'] });

  const createProvider = useMutation({
    mutationFn: (body: Partial<AiProvider>) => aiApi.createProvider(body),
    onSuccess: invalidate,
  });

  const updateProvider = useMutation({
    mutationFn: ({ id, ...body }: Partial<AiProvider> & { id: number }) =>
      aiApi.updateProvider(id, body),
    onSuccess: invalidate,
  });

  const deleteProvider = useMutation({
    mutationFn: (id: number) => aiApi.deleteProvider(id),
    onSuccess: invalidate,
  });

  const testProvider = useMutation({
    mutationFn: (id: number) => aiApi.testProvider(id),
  });

  const createModel = useMutation({
    mutationFn: (body: Partial<AiModel>) => aiApi.createModel(body),
    onSuccess: invalidate,
  });

  const updateModel = useMutation({
    mutationFn: ({ id, ...body }: Partial<AiModel> & { id: number }) =>
      aiApi.updateModel(id, body),
    onSuccess: invalidate,
  });

  const deleteModel = useMutation({
    mutationFn: (id: number) => aiApi.deleteModel(id),
    onSuccess: invalidate,
  });

  const setDefaultModel = useMutation({
    mutationFn: (id: number) => aiApi.setDefaultModel(id),
    onSuccess: invalidate,
  });

  const updateGlobal = useMutation({
    mutationFn: (body: Partial<AiGlobalConfig>) => aiApi.updateGlobal(body),
    onSuccess: invalidate,
  });

  return {
    createProvider,
    updateProvider,
    deleteProvider,
    testProvider,
    createModel,
    updateModel,
    deleteModel,
    setDefaultModel,
    updateGlobal,
  };
}
