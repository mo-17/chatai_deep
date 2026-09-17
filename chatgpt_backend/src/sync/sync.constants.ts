import { SYNC_V2_LIMITS } from '../sync-v2/sync-v2.constants';

/**
 * 旧版同步协议仍被客户端使用；复用 v2 的线上传输预算，并补齐 v1 特有的
 * 自由形态字段、JSON 结构和累计存储上限。
 */
export const LEGACY_SYNC_LIMITS = {
  ...SYNC_V2_LIMITS,
  maxEntityLength: 64,
  maxEntityIdLength: 255,
  maxJsonKeyLength: 255,
  maxJsonDepth: 32,
  maxPayloadNodes: 10_000,
  maxEnvelopeNodes: 50_000,
  maxStoredChangesPerUser: 100_000,
  maxStoredPayloadBytesPerUser: 512 * 1024 * 1024,
} as const;
