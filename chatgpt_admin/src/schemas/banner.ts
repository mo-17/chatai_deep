import { z } from 'zod';

export const bannerSchema = z.object({
  title: z.string().min(1, '请输入标题').max(80, '标题不超过80字'),
  subtitle: z.string().max(200, '副标题不超过200字').optional().default(''),
  cover: z.string().url('请输入有效URL').or(z.literal('')).optional().default(''),
  url: z.string().url('请输入有效URL').or(z.literal('')).optional().default(''),
  sticky: z.number().int().default(0),
  enabled: z.boolean().default(true),
  type: z.string().default('banner'),
});
export type BannerForm = z.infer<typeof bannerSchema>;
