import assert from 'node:assert/strict';
import test from 'node:test';
import { buildContainerEnv } from './container-env.ts';

test('container env 保持 production/port 默认值并过滤空变量', () => {
  assert.deepEqual(
    buildContainerEnv({
      DB_HOST: '',
      SYNC_V2_SHADOW_USER_IDS: undefined,
    }),
    { PORT: '3000', NODE_ENV: 'production' },
  );
});

test('只显式转发持久化、同步 canary、身份与数据库配置', () => {
  const values = buildContainerEnv({
    NODE_ENV: 'production',
    DB_HOST: 'postgres.internal',
    MIGRATION_LOCK_TIMEOUT_MS: '60000',
    APPLE_BUNDLE_ID: 'com.example.chatai',
    APPLE_SERVICE_ID: 'com.example.chatai.web',
    REQUIRE_PRODUCTION_MODE: 'true',
    REQUIRE_PERSISTENT_UPLOADS: 'true',
    SYNC_V2_SHADOW_ENABLED: 'true',
    SYNC_V2_SHADOW_USER_IDS: '41,42',
  });

  assert.deepEqual(values, {
    PORT: '3000',
    NODE_ENV: 'production',
    DB_HOST: 'postgres.internal',
    MIGRATION_LOCK_TIMEOUT_MS: '60000',
    APPLE_BUNDLE_ID: 'com.example.chatai',
    APPLE_SERVICE_ID: 'com.example.chatai.web',
    REQUIRE_PRODUCTION_MODE: 'true',
    REQUIRE_PERSISTENT_UPLOADS: 'true',
    SYNC_V2_SHADOW_ENABLED: 'true',
    SYNC_V2_SHADOW_USER_IDS: '41,42',
  });
});
