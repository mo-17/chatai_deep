import { ServiceUnavailableException } from '@nestjs/common';
import { PATH_METADATA } from '@nestjs/common/constants';

jest.mock('../auth/jwt.guard', () => ({ JwtGuard: class JwtGuard {} }));

import { SyncV2Controller } from './sync-v2.controller';
import type { SyncV2AccessPolicy } from './sync-v2-access.policy';
import type { PushSyncV2Dto } from './dto/sync-v2.dto';
import type { SyncV2Service } from './sync-v2.service';

describe('SyncV2Controller', () => {
  const pushBody = {
    deviceId: '00000000-0000-4000-8000-000000009000',
    changes: [],
  } as PushSyncV2Dto;

  function setup({ allowed = true } = {}) {
    const service = {
      capabilities: jest.fn(() => ({ protocol: 2, shadowOnly: true })),
      push: jest.fn(() => Promise.resolve({ acks: [] })),
      pull: jest.fn(() =>
        Promise.resolve({ cursor: '0', hasMore: false, changes: [] }),
      ),
    };
    const accessPolicy = {
      isAllowed: jest.fn(() => allowed),
      assertAllowed: jest.fn(() => {
        if (!allowed) {
          throw new ServiceUnavailableException('sync v2 shadow 未启用');
        }
      }),
    };
    return {
      service,
      accessPolicy,
      controller: new SyncV2Controller(
        service as unknown as SyncV2Service,
        accessPolicy as unknown as SyncV2AccessPolicy,
      ),
    };
  }

  it('注册在独立的 uapi/sync/v2 路径', () => {
    expect(Reflect.getMetadata(PATH_METADATA, SyncV2Controller)).toBe(
      'uapi/sync/v2',
    );
  });

  it('capabilities 明确包装 code/data', () => {
    const { controller } = setup();

    expect(controller.capabilities({ user: { userId: 77 } } as never)).toEqual({
      code: 0,
      data: {
        protocol: 2,
        shadowOnly: true,
        shadowAccessEnabled: true,
      },
    });
  });

  it('默认关闭时 capabilities 可探测，但 push/pull 在访问存储前拒绝', async () => {
    const { controller, service, accessPolicy } = setup({ allowed: false });
    const request = { user: { userId: 77 } } as never;

    expect(controller.capabilities(request)).toEqual({
      code: 0,
      data: {
        protocol: 2,
        shadowOnly: true,
        shadowAccessEnabled: false,
      },
    });
    await expect(controller.push(request, pushBody)).rejects.toThrow(
      ServiceUnavailableException,
    );
    await expect(controller.pull(request, '0')).rejects.toThrow(
      ServiceUnavailableException,
    );
    expect(accessPolicy.assertAllowed).toHaveBeenCalledTimes(2);
    expect(service.push).not.toHaveBeenCalled();
    expect(service.pull).not.toHaveBeenCalled();
  });

  it('push 只使用 JWT userId，不接受 body 身份', async () => {
    const { controller, service, accessPolicy } = setup();

    const result = await controller.push(
      { user: { userId: 77 } } as never,
      pushBody,
    );

    expect(accessPolicy.assertAllowed).toHaveBeenCalledWith(77);
    expect(service.push).toHaveBeenCalledWith(77, pushBody);
    expect(result).toEqual({ code: 0, data: { acks: [] } });
  });

  it('pull 使用十进制 cursor 并限制 limit 上限', async () => {
    const { controller, service, accessPolicy } = setup();

    await controller.pull({ user: { userId: 77 } } as never, '123', '999');

    expect(accessPolicy.assertAllowed).toHaveBeenCalledWith(77);
    expect(service.pull).toHaveBeenCalledWith(77, '123', 500);
  });
});
