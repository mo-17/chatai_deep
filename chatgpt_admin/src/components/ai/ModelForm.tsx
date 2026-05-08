'use client';

import { useEffect } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import {
  Modal, ModalContent, ModalHeader, ModalBody, ModalFooter,
  Button, Input, Switch, Select, SelectItem, Textarea,
} from '@nextui-org/react';
import { modelSchema, type ModelForm as ModelFormType } from '@/schemas/ai';
import { useProviders } from '@/hooks/useAi';
import type { AiModel } from '@/types/ai';

interface Props {
  open: boolean;
  isCreate: boolean;
  model?: AiModel | null;
  onClose: () => void;
  onSave: (data: ModelFormType) => void;
  loading?: boolean;
}

export function ModelForm({ open, isCreate, model, onClose, onSave, loading }: Props) {
  const { data: providers } = useProviders();
  const { control, handleSubmit, reset, formState: { errors } } = useForm<ModelFormType>({
    resolver: zodResolver(modelSchema),
  });

  useEffect(() => {
    if (open) {
      if (isCreate || !model) {
        reset({
          providerId: 0,
          modelId: '',
          displayName: '',
          description: '',
          enabled: true,
          isDefault: false,
          sortOrder: 0,
        });
      } else {
        reset({
          providerId: model.providerId,
          modelId: model.modelId,
          displayName: model.displayName,
          description: model.description || '',
          enabled: model.enabled,
          isDefault: model.isDefault,
          sortOrder: model.sortOrder,
        });
      }
    }
  }, [open, isCreate, model, reset]);

  return (
    <Modal isOpen={open} onClose={onClose} size="lg">
      <ModalContent>
        <ModalHeader>{isCreate ? '新增模型' : '编辑模型'}</ModalHeader>
        <ModalBody>
          <form className="space-y-3">
            <Controller
              name="providerId"
              control={control}
              render={({ field }) => (
                <Select
                  label="服务商"
                  selectedKeys={field.value ? [String(field.value)] : []}
                  onSelectionChange={(keys) => {
                    const val = Array.from(keys as Set<string>)[0];
                    if (val) field.onChange(parseInt(val, 10));
                  }}
                  isInvalid={!!errors.providerId}
                  errorMessage={errors.providerId?.message}
                >
                  {(providers || []).map((p) => (
                    <SelectItem key={String(p.id)}>{p.displayName}</SelectItem>
                  ))}
                </Select>
              )}
            />
            <Controller
              name="modelId"
              control={control}
              render={({ field }) => (
                <Input
                  label="模型 ID"
                  placeholder="gpt-4o-mini"
                  value={field.value}
                  onValueChange={field.onChange}
                  isInvalid={!!errors.modelId}
                  errorMessage={errors.modelId?.message}
                />
              )}
            />
            <Controller
              name="displayName"
              control={control}
              render={({ field }) => (
                <Input
                  label="显示名称"
                  placeholder="GPT-4o mini"
                  value={field.value}
                  onValueChange={field.onChange}
                  isInvalid={!!errors.displayName}
                  errorMessage={errors.displayName?.message}
                />
              )}
            />
            <Controller
              name="description"
              control={control}
              render={({ field }) => (
                <Textarea
                  label="描述"
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
                name="isDefault"
                control={control}
                render={({ field }) => (
                  <Switch
                    isSelected={field.value}
                    onValueChange={field.onChange}
                  >
                    默认模型
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
