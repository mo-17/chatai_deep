import {
  IsArray,
  IsIn,
  IsNumber,
  IsObject,
  IsOptional,
  IsString,
  Min,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import type { SyncOperation } from '../sync-change.entity';

export class SyncChangeDto {
  @IsString()
  entity: string;

  @IsString()
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
  deviceId?: string;
}

export class PushSyncDto {
  @IsOptional()
  @IsString()
  deviceId?: string;

  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => SyncChangeDto)
  changes: SyncChangeDto[];
}
