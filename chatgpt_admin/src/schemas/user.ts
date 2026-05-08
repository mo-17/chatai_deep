import { z } from 'zod';

export const resetPasswordSchema = z.object({
  password: z.string().min(6, '密码至少6位'),
});
export type ResetPasswordForm = z.infer<typeof resetPasswordSchema>;
