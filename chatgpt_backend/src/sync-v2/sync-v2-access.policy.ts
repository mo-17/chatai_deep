import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

@Injectable()
export class SyncV2AccessPolicy {
  constructor(private readonly config: ConfigService) {}

  isAllowed(userId: number): boolean {
    if (this.config.get<string>('SYNC_V2_SHADOW_ENABLED') !== 'true') {
      return false;
    }

    const configuredUsers = this.config
      .get<string>('SYNC_V2_SHADOW_USER_IDS', '')
      .trim();
    if (configuredUsers === '*') return true;

    const expected = String(userId);
    return configuredUsers
      .split(',')
      .map((value) => value.trim())
      .filter((value) => /^[1-9]\d*$/.test(value))
      .includes(expected);
  }

  assertAllowed(userId: number): void {
    if (!this.isAllowed(userId)) {
      throw new ServiceUnavailableException('sync v2 shadow 未启用');
    }
  }
}
