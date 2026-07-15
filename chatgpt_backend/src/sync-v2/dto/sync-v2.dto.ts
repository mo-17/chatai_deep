import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  MaxLength,
  ValidateNested,
} from 'class-validator';
import { SYNC_V2_ENTITIES, SYNC_V2_LIMITS } from '../sync-v2.constants';
import type { SyncV2Entity } from '../sync-v2.constants';

export type SyncV2Operation = 'upsert' | 'delete';

export class SyncV2ChangeDto {
  @IsUUID('4')
  changeId: string;

  @IsIn(SYNC_V2_ENTITIES)
  entity: SyncV2Entity;

  @IsUUID('4')
  syncId: string;

  @IsOptional()
  @IsUUID('4')
  parentChangeId?: string | null;

  @IsString()
  @Matches(/^[1-9]\d*$/)
  revision: string;

  @IsIn(['upsert', 'delete'])
  op: SyncV2Operation;

  @IsOptional()
  @IsObject()
  payload?: Record<string, unknown>;
}

export class PushSyncV2Dto {
  @IsUUID('4')
  @MaxLength(SYNC_V2_LIMITS.maxDeviceIdLength)
  deviceId: string;

  @IsArray()
  @ArrayMaxSize(SYNC_V2_LIMITS.maxChanges)
  @ValidateNested({ each: true })
  @Type(() => SyncV2ChangeDto)
  changes: SyncV2ChangeDto[];
}
