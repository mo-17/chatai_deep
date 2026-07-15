import { ConfigService } from '@nestjs/config';
import { ServiceUnavailableException } from '@nestjs/common';
import { SyncV2AccessPolicy } from './sync-v2-access.policy';

describe('SyncV2AccessPolicy', () => {
  function policy(values: Record<string, string | undefined>) {
    return new SyncV2AccessPolicy(new ConfigService(values));
  }

  it('默认关闭，不能仅凭已登录身份写入 shadow 表', () => {
    const access = policy({});

    expect(access.isAllowed(77)).toBe(false);
    expect(() => access.assertAllowed(77)).toThrow(ServiceUnavailableException);
  });

  it('显式启用后仍只允许 canary userId', () => {
    const access = policy({
      SYNC_V2_SHADOW_ENABLED: 'true',
      SYNC_V2_SHADOW_USER_IDS: '77, 88',
    });

    expect(access.isAllowed(77)).toBe(true);
    expect(access.isAllowed(88)).toBe(true);
    expect(access.isAllowed(99)).toBe(false);
  });

  it('只有显式星号才允许所有已认证用户', () => {
    const access = policy({
      SYNC_V2_SHADOW_ENABLED: 'true',
      SYNC_V2_SHADOW_USER_IDS: '*',
    });

    expect(access.isAllowed(77)).toBe(true);
  });
});
