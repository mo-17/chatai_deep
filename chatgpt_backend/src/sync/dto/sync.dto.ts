import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsNumber,
  IsObject,
  IsOptional,
  IsString,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import type { SyncOperation } from '../sync-change.entity';
import { LEGACY_SYNC_LIMITS } from '../sync.constants';

export class SyncChangeDto {
  @IsString()
  @MaxLength(LEGACY_SYNC_LIMITS.maxEntityLength)
  entity: string;

  @IsString()
  @MaxLength(LEGACY_SYNC_LIMITS.maxEntityIdLength)
  entityId: string;

  @IsIn(['upsert', 'delete'])
  op: SyncOperation;

  @IsNumber()
  @Min(0)
  updatedAt: number;

  @IsOptional()
  @IsObject()
  payload?: Record<string, unknown>;

  @IsOptional()
  @IsString()
  @MaxLength(LEGACY_SYNC_LIMITS.maxDeviceIdLength)
  deviceId?: string;
}

export class PushSyncDto {
  @IsOptional()
  @IsString()
  @MaxLength(LEGACY_SYNC_LIMITS.maxDeviceIdLength)
  deviceId?: string;

  @IsArray()
  @ArrayMaxSize(LEGACY_SYNC_LIMITS.maxChanges)
  @ValidateNested({ each: true })
  @Type(() => SyncChangeDto)
  changes: SyncChangeDto[];
}
