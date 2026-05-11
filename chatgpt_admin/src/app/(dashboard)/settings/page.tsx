'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Card, CardBody, CardHeader, Input, Button } from '@heroui/react';
import { useMutation } from '@tanstack/react-query';
import { authApi } from '@/lib/api/auth';
import { useAuthStore } from '@/store/authStore';
import { useRouter } from 'next/navigation';


const schema = z
  .object({
    oldPassword: z.string().min(1, '请输入旧密码'),
    newPassword: z.string().min(6, '新密码至少6位'),
    confirmPassword: z.string().min(6, '请确认新密码'),
  })
  .refine((d) => d.newPassword === d.confirmPassword, {
    message: '两次密码不一致',
    path: ['confirmPassword'],
  });
type FormData = z.infer<typeof schema>;

export default function SettingsPage() {
  const router = useRouter();
  const logout = useAuthStore((s) => s.logout);

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  const { mutate, isPending, error } = useMutation({
    mutationFn: ({ oldPassword, newPassword }: FormData) =>
      authApi.changePassword(oldPassword, newPassword),
    onSuccess: () => {
      console.log('密码修改成功');
      logout();
      router.replace('/login');
    },
  });

  return (
    <div className="max-w-md mx-auto space-y-6">
      <h1 className="text-xl font-bold">设置</h1>
      <Card>
        <CardHeader>修改密码</CardHeader>
        <CardBody>
          <form
            onSubmit={handleSubmit((d) => mutate(d))}
            className="space-y-4"
          >
            <Input
              label="旧密码"
              type="password"
              {...register('oldPassword')}
              isInvalid={!!errors.oldPassword}
              errorMessage={errors.oldPassword?.message}
            />
            <Input
              label="新密码"
              type="password"
              {...register('newPassword')}
              isInvalid={!!errors.newPassword}
              errorMessage={errors.newPassword?.message}
            />
            <Input
              label="确认新密码"
              type="password"
              {...register('confirmPassword')}
              isInvalid={!!errors.confirmPassword}
              errorMessage={errors.confirmPassword?.message}
            />
            {error && (
              <p className="text-danger text-sm">{(error as Error).message}</p>
            )}
            <Button
              type="submit"
              color="primary"
              className="w-full"
              isLoading={isPending}
            >
              修改密码
            </Button>
          </form>
        </CardBody>
      </Card>
    </div>
  );
}
