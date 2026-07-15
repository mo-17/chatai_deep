import { MODULE_METADATA } from '@nestjs/common/constants';

jest.mock('../auth/jwt.guard', () => ({ JwtGuard: class JwtGuard {} }));

import { SyncV2Controller } from './sync-v2.controller';
import { SyncV2AccessPolicy } from './sync-v2-access.policy';
import { SyncV2Module } from './sync-v2.module';
import { SyncV2Service } from './sync-v2.service';
import { SYNC_V2_STORE, TypeOrmSyncV2Store } from './sync-v2.store';

describe('SyncV2Module', () => {
  it('只注册独立 v2 controller、service 和 store', () => {
    const controllers = Reflect.getMetadata(
      MODULE_METADATA.CONTROLLERS,
      SyncV2Module,
    ) as unknown[];
    const providers = Reflect.getMetadata(
      MODULE_METADATA.PROVIDERS,
      SyncV2Module,
    ) as unknown[];

    expect(controllers).toEqual([SyncV2Controller]);
    expect(providers).toEqual(
      expect.arrayContaining([
        SyncV2AccessPolicy,
        SyncV2Service,
        expect.objectContaining({
          provide: SYNC_V2_STORE,
          useClass: TypeOrmSyncV2Store,
        }),
      ]),
    );
  });
});
