export const SYNC_V2_ENTITIES = [
  'project',
  'assistant',
  'conversation',
  'message',
  'favorite',
  'knowledge_doc',
  'knowledge_chunk',
  'project_knowledge',
  'assistant_memory',
] as const;

export type SyncV2Entity = (typeof SYNC_V2_ENTITIES)[number];

export const SYNC_V2_LIMITS = {
  maxChanges: 500,
  defaultPullLimit: 200,
  maxPullLimit: 500,
  maxPayloadBytes: 512 * 1024,
  maxEnvelopeBytes: 4 * 1024 * 1024,
  maxPullResponseBytes: 4 * 1024 * 1024,
  maxDeviceIdLength: 64,
} as const;

export const SYNC_V2_MAX_BIGINT = BigInt('9223372036854775807');
