'use client';

import { useEffect } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import {
  Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
  Button, Input, Switch,
} from '@nextui-org/react';
import { providerCreateSchema, providerUpdateSchema, type ProviderCreateForm, type ProviderUpdateForm } from '@/schemas/ai';
import type { AiProvider } from '@/types/ai';

interface Props {
  open: boolean;
  isCreate: boolean;
  provider?: AiProvider | null;
  onClose: () => void;
  onSave: (data: ProviderCreateForm | ProviderUpdateForm) => void;
  loading?: boolean;
}

export function ProviderForm({ open, isCreate, provider, onClose, onSave, loading }: Props) {
  const schema = isCreate ? providerCreateSchema : providerUpdateSchema;
  const { control, handleSubmit, reset, formState: { errors } } = useForm<any>({
    resolver: zodResolver(schema),
  });

  useEffect(() => {
    if (open) {
      if (isCreate || !provider) {
        reset({
          code: '',
          displayName: '',
          apiKey: '',
          baseUrl: '',
          modelPrefixes: '',
          enabled: true,
          sortOrder: 0,
        });
      } else {
        reset({
          displayName: provider.displayName,
          apiKey: '',
          baseUrl: provider.baseUrl,
          modelPrefixes: provider.modelPrefixes || '',
          enabled: provider.enabled,
          sortOrder: provider.sortOrder,
        });
      }
    }
  }, [open, isCreate, provider, reset]);

  return (
    <Modal isOpen={open} onClose={onClose} size="lg">
      <ModalContent>
        <ModalHeader>{isCreate ? '新增服务商' : '编辑服务商'}</ModalHeader>
        <ModalBody>
          <form className="space-y-3">
            {isCreate && (
              <Controller
                name="code"
                control={control}
                render={({ field }) => (
                  <Input
                    label="代码"
                    placeholder="如 openai, deepseek, qwen"
                    value={field.value}
                    onValueChange={field.onChange}
                    isInvalid={!!errors.code}
                    errorMessage={errors.code?.message?.toString()}
                  />
                )}
              />
            )}
            {!isCreate && provider && (
              <Input label="代码" value={provider.code} isReadOnly />
            )}
            <Controller
              name="displayName"
              control={control}
              render={({ field }) => (
                <Input
                  label="显示名称"
                  value={field.value}
                  onValueChange={field.onChange}
                  isInvalid={!!errors.displayName}
                  errorMessage={errors.displayName?.message?.toString()}
                />
              )}
            />
            <Controller
              name="apiKey"
              control={control}
              render={({ field }) => (
                <Input
                  label="API Key"
                  type="password"
                  placeholder={isCreate ? '' : '未变更则留空'}
                  value={field.value || ''}
                  onValueChange={field.onChange}
                  isInvalid={!!errors.apiKey}
                  errorMessage={errors.apiKey?.message?.toString()}
                />
              )}
            />
            <Controller
              name="baseUrl"
              control={control}
              render={({ field }) => (
                <Input
                  label="Base URL"
                  placeholder="https://api.openai.com/v1"
                  value={field.value}
                  onValueChange={field.onChange}
                  isInvalid={!!errors.baseUrl}
                  errorMessage={errors.baseUrl?.message?.toString()}
                />
              )}
            />
            <Controller
              name="modelPrefixes"
              control={control}
              render={({ field }) => (
                <Input
                  label="模型前缀"
                  placeholder="gpt-,o1-,chatgpt-（逗号分隔）"
                  value={field.value || ''}
                  onValueChange={field.onChange}
                />
              )}
            />
            <div className="flex gap-6">
              <Controller
                name="enabled"
                control={control}
                render={({ field }) => (
                  <Switch
                    isSelected={field.value}
                    onValueChange={field.onChange}
                  >
                    启用
                  </Switch>
                )}
              />
              <Controller
                name="sortOrder"
                control={control}
                render={({ field }) => (
                  <Input
                    label="排序权重"
                    type="number"
                    className="w-24"
                    value={String(field.value ?? 0)}
                    onValueChange={(v) => field.onChange(parseInt(v, 10) || 0)}
                  />
                )}
              />
            </div>
          </form>
        </ModalBody>
        <ModalFooter>
          <Button variant="flat" onPress={onClose}>取消</Button>
          <Button
            color="primary"
            isLoading={loading}
            onPress={handleSubmit((d) => onSave(d))}
          >
            保存
          </Button>
        </ModalFooter>
      </ModalContent>
    </Modal>
  );
}
