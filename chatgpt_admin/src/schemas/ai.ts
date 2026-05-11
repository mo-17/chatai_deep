import { z } from 'zod';

export const providerCreateSchema = z.object({
  code: z
    .string()
    .min(1, '请输入服务商代码')
    .regex(/^[a-z][a-z0-9_-]*$/, '仅小写字母开头，含数字和_-'),
  displayName: z.string().min(1, '请输入显示名称'),
  apiKey: z.string().min(1, '请输入 API Key'),
  baseUrl: z.string().min(1, '请输入 Base URL'),
  modelPrefixes: z.string().optional().default(''),
  enabled: z.boolean().default(true),
  sortOrder: z.number().int().default(0),
});

export const providerUpdateSchema = z.object({
  displayName: z.string().min(1, '请输入显示名称'),
  apiKey: z.string().optional().default(''),
  baseUrl: z.string().min(1, '请输入 Base URL'),
  modelPrefixes: z.string().optional().default(''),
  enabled: z.boolean().default(true),
  sortOrder: z.number().int().default(0),
});

export const modelSchema = z.object({
  providerId: z.number({ error: (iss) => iss.input === undefined ? '请选择服务商' : '请输入有效数字' }),
  modelId: z.string().min(1, '请输入模型 ID'),
  displayName: z.string().min(1, '请输入显示名称'),
  description: z.string().optional().default(''),
  enabled: z.boolean().default(true),
  isDefault: z.boolean().default(false),
  sortOrder: z.number().int().default(0),
});

export const globalSchema = z.object({
  defaultProviderCode: z.string().min(1, '请选择默认服务商'),
  defaultModelId: z.string().min(1, '请选择默认模型'),
  catalogPublic: z.boolean().default(true),
});

export type ProviderCreateForm = z.infer<typeof providerCreateSchema>;
export type ProviderUpdateForm = z.infer<typeof providerUpdateSchema>;
export type ModelForm = z.input<typeof modelSchema>;
export type GlobalForm = z.infer<typeof globalSchema>;
