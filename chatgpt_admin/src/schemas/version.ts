import { z } from 'zod';

export const versionSchema = z.object({
  versionName: z.string().regex(/^\d+\.\d+\.\d+$/, '格式如 1.2.0'),
  versionCode: z.number().int().positive('必须为正整数'),
  url: z.string().optional().default(''),
  description: z.string().optional().default(''),
  cid: z.string().default('all'),
  forceUpdate: z.boolean().default(false),
  enabled: z.boolean().default(true),
});
export type VersionForm = z.infer<typeof versionSchema>;
