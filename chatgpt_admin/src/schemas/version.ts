import { z } from 'zod';

export const versionSchema = z.object({
  versionName: z.string().regex(/^\d+\.\d+\.\d+$/, '格式如 1.2.0'),
  versionCode: z.number().int().positive('必须为正整数'),
  url: z.string().optional().default(''),
  sha256: z
    .string()
    .trim()
    .refine(
      (value) => value === '' || /^[0-9a-fA-F]{64}$/.test(value),
      '必须留空或填写 64 位 SHA-256',
    )
    .default(''),
  description: z.string().optional().default(''),
  cid: z.string().default('all'),
  forceUpdate: z.boolean().default(false),
  enabled: z.boolean().default(true),
  rolloutPercent: z.number().int().min(0).max(100).default(100),
  rolloutSalt: z.string().max(80).default(''),
  artifacts: z.record(z.string(),z.object({url:z.url(),sha256:z.string().regex(/^[0-9a-f]{64}$/),bytes:z.number().int().positive()})).default({}),
});
export type VersionForm = z.infer<typeof versionSchema>;
