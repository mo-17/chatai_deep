import { MODULE_METADATA } from '@nestjs/common/constants';
import type { TypeOrmModuleOptions } from '@nestjs/typeorm';

jest.mock('./user/user.module', () => ({ UserModule: class UserModule {} }));
jest.mock('./notice/notice.module', () => ({
  NoticeModule: class NoticeModule {},
}));
jest.mock('./update/update.module', () => ({
  UpdateModule: class UpdateModule {},
}));
jest.mock('./test/test.module', () => ({ TestModule: class TestModule {} }));
jest.mock('./chat/chat.module', () => ({ ChatModule: class ChatModule {} }));
jest.mock('./admin/admin.module', () => ({
  AdminModule: class AdminModule {},
}));
jest.mock('./ai/ai.module', () => ({ AiModule: class AiModule {} }));
jest.mock('./health/health.module', () => ({
  HealthModule: class HealthModule {},
}));
jest.mock('./auth/auth.module', () => ({ AuthModule: class AuthModule {} }));
jest.mock('./mcp/mcp.module', () => ({ McpModule: class McpModule {} }));
jest.mock('./sync/sync.module', () => ({ SyncModule: class SyncModule {} }));
jest.mock('./sync-v2/sync-v2.module', () => ({
  SyncV2Module: class SyncV2Module {},
}));

import { AppModule } from './app.module';

type DynamicModuleShape = {
  module?: { name?: string };
  imports?: unknown[];
  providers?: unknown[];
};

type TypeOrmOptionsProvider = {
  provide: string;
  useFactory: (config: {
    get<T = string>(key: string): T | undefined;
  }) => TypeOrmModuleOptions | Promise<TypeOrmModuleOptions>;
};

async function buildAppTypeOrmOptions(
  values: Record<string, string | undefined>,
): Promise<TypeOrmModuleOptions> {
  const imports = Reflect.getMetadata(
    MODULE_METADATA.IMPORTS,
    AppModule,
  ) as unknown[];
  const typeOrmModule = imports
    .map((value) => value as DynamicModuleShape)
    .find((value) => value.module?.name === 'TypeOrmModule');
  const coreModule = typeOrmModule?.imports?.[0] as
    | DynamicModuleShape
    | undefined;
  const optionsProvider = coreModule?.providers?.find(
    (provider): provider is TypeOrmOptionsProvider =>
      typeof provider === 'object' &&
      provider !== null &&
      'provide' in provider &&
      provider.provide === 'TypeOrmModuleOptions' &&
      'useFactory' in provider &&
      typeof provider.useFactory === 'function',
  );

  if (!optionsProvider) {
    throw new Error('未找到 AppModule 的 TypeORM options provider');
  }

  return await optionsProvider.useFactory({
    get<T = string>(key: string): T | undefined {
      return values[key] as T | undefined;
    },
  });
}

describe('AppModule database configuration', () => {
  it.each([
    {
      name: '开发环境显式 false',
      values: { NODE_ENV: 'development', DB_SYNCHRONIZE: 'false' },
      expected: false,
    },
    {
      name: '生产环境显式 true',
      values: { NODE_ENV: 'production', DB_SYNCHRONIZE: 'true' },
      expected: true,
    },
    {
      name: '开发环境未配置',
      values: { NODE_ENV: 'development' },
      expected: true,
    },
    {
      name: '生产环境未配置',
      values: { NODE_ENV: 'production' },
      expected: false,
    },
  ])('$name 时 synchronize=$expected', async ({ values, expected }) => {
    const options = await buildAppTypeOrmOptions(values);

    expect(options.synchronize).toBe(expected);
  });
});
