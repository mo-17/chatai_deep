'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Card, CardBody, CardHeader, Input, Button } from '@heroui/react';
import { useMutation } from '@tanstack/react-query';
import { authApi } from '@/lib/api/auth';
import { useAuthStore } from '@/store/authStore';
import { useRouter } from 'next/navigation';

const schema = z.object({
  userName: z.string().min(1, '请输入账号'),
  password: z.string().min(1, '请输入密码'),
});
type FormData = z.infer<typeof schema>;

export default function LoginPage() {
  const router = useRouter();
  const setAuth = useAuthStore((s) => s.setAuth);
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({
    resolver: zodResolver(schema),
  });
  const { mutate, isPending, error } = useMutation({
    mutationFn: ({ userName, password }: FormData) =>
      authApi.login(userName, password),
    onSuccess: (res) => {
      setAuth(res.token, res.admin);
      router.replace('/dashboard');
    },
  });

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-blue-50 to-purple-50">
      <Card className="w-[400px] p-2">
        <CardHeader className="flex-col items-start">
          <h1 className="text-2xl font-bold">ChatGPT Admin</h1>
          <p className="text-sm text-default-500">后台管理系统</p>
        </CardHeader>
        <CardBody>
          <form
            onSubmit={handleSubmit((d) => mutate(d))}
            className="space-y-4"
          >
            <Input
              label="账号"
              {...register('userName')}
              isInvalid={!!errors.userName}
              errorMessage={errors.userName?.message}
            />
            <Input
              label="密码"
              type="password"
              {...register('password')}
              isInvalid={!!errors.password}
              errorMessage={errors.password?.message}
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
              登录
            </Button>
          </form>
        </CardBody>
      </Card>
    </div>
  );
}
