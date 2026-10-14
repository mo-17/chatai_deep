import { createHash } from 'node:crypto';
import { BadRequestException } from '@nestjs/common';

export const CLOUD_CONSENT_VERSION = 'cloud-text-v1';
export const CLOUD_LIMITS = Object.freeze({
  attempts: 8,
  estimatedTokens: 32000,
  outputTokens: 2048,
  durationMs: 600000,
  reworks: 1,
  queued: 32,
  inputs: 4,
  taskBytes: 12000,
  inputBytes: 12000,
  allInputBytes: 24000,
  requestBytes: 48000,
  resultBytes: 48000,
  depth: 6,
});
export const CLOUD_ROLES = ['analysis', 'writing', 'review'] as const;
export type CloudRole = (typeof CLOUD_ROLES)[number];
export interface CloudAuthorization {
  userId: number;
  securityVersion: number;
  expiresAt: number;
}
export interface CloudProfile {
  providerId: number;
  modelRowId: number;
}
interface CloudPayloadFields {
  consentVersion: typeof CLOUD_CONSENT_VERSION;
  idempotencyKey: string;
  clientInstanceId: string;
  task: string;
  acceptance: {
    format: 'txt' | 'md' | 'csv';
    outputName: string;
    minChars: number;
    maxChars: number;
    requiredTerms: string[];
    requireFullRead: boolean;
  };
  inputs: Array<{ title: string; text: string; contentHash: string }>;
  profiles: Record<CloudRole, CloudProfile>;
  budget: {
    attempts: number;
    estimatedTokens: number;
    outputTokens: number;
    durationMs: number;
    reworks: number;
  };
  grantDurationMs: number;
}
export interface CloudPayloadV1 extends CloudPayloadFields {
  version: 1;
  source: { cid: number; messageId: string; contentHash: string };
}
export type CloudSourceV2 =
  | {
      kind: 'local_message';
      cid: number;
      messageId: string;
      revision: number;
      contentHash: string;
    }
  | { kind: 'draft'; id: string; revision: number; contentHash: string };
export interface CloudPayloadV2 extends CloudPayloadFields {
  version: 2;
  source: CloudSourceV2;
}
export type CloudPayload = CloudPayloadV1 | CloudPayloadV2;
export const hashText = (text: string) =>
  createHash('sha256').update(text).digest('hex');
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value !== null && typeof value === 'object') {
    return (
      '{' +
      Object.keys(value)
        .sort()
        .map(
          (key) =>
            JSON.stringify(key) +
            ':' +
            canonical((value as Record<string, unknown>)[key]),
        )
        .join(',') +
      '}'
    );
  }
  return JSON.stringify(value);
}
function invalid(): never {
  throw new BadRequestException(
    '云任务只接受已确认的有界文本、验收条件和服务端模型引用',
  );
}
export function object(
  value: unknown,
  keys: string[],
): Record<string, unknown> {
  if (
    !value ||
    typeof value !== 'object' ||
    Array.isArray(value) ||
    Object.getPrototypeOf(value) !== Object.prototype
  )
    invalid();
  const row = value as Record<string, unknown>;
  if (
    Object.keys(row).length !== keys.length ||
    Object.keys(row).some((key) => !keys.includes(key))
  )
    invalid();
  return row;
}
export function integer(value: unknown, min: number, max: number): number {
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < min ||
    (value as number) > max
  )
    invalid();
  return value as number;
}
function text(value: unknown, maxBytes: number): string {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.includes(String.fromCharCode(0)) ||
    /[\ud800-\udfff]/u.test(value) ||
    Buffer.byteLength(value) > maxBytes
  )
    invalid();
  return value;
}
export function uuid(value: unknown): string {
  if (
    typeof value !== 'string' ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  )
    invalid();
  return value.toLowerCase();
}
function digest(value: unknown): string {
  if (typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value)) invalid();
  return value;
}
function bounded(value: unknown, depth = 0): void {
  if (depth > CLOUD_LIMITS.depth) invalid();
  if (value && typeof value === 'object') {
    if (Object.keys(value).length > 64) invalid();
    Object.values(value).forEach((child) => bounded(child, depth + 1));
  }
}
/** 接收已解码 JSON；所有层都拒绝未知字段，绝不收任意 URL、路径、密钥或历史字段。 */
export function parseCloudPayload(value: unknown): CloudPayload {
  const p = object(value, [
    'version',
    'consentVersion',
    'idempotencyKey',
    'clientInstanceId',
    'source',
    'task',
    'acceptance',
    'inputs',
    'profiles',
    'budget',
    'grantDurationMs',
  ]);
  bounded(value);
  if (Buffer.byteLength(canonical(value)) > CLOUD_LIMITS.requestBytes)
    invalid();
  if (
    ![1, 2].includes(p.version as number) ||
    p.consentVersion !== CLOUD_CONSENT_VERSION
  )
    invalid();
  const a = object(p.acceptance, [
    'format',
    'outputName',
    'minChars',
    'maxChars',
    'requiredTerms',
    'requireFullRead',
  ]);
  if (
    !['txt', 'md', 'csv'].includes(a.format as string) ||
    typeof a.requireFullRead !== 'boolean'
  )
    invalid();
  const outputName = text(a.outputName, 120);
  if (
    !/^[A-Za-z0-9_\-\u4e00-\u9fff][A-Za-z0-9_.\-\u4e00-\u9fff]{0,100}\.(txt|md|csv)$/.test(
      outputName,
    ) ||
    !outputName.endsWith('.' + String(a.format))
  )
    invalid();
  const minChars = integer(a.minChars, 0, 12000),
    maxChars = integer(a.maxChars, 1, 12000);
  if (
    minChars > maxChars ||
    !Array.isArray(a.requiredTerms) ||
    a.requiredTerms.length > 20
  )
    invalid();
  const requiredTerms = a.requiredTerms.map((term) => text(term, 120));
  if (new Set(requiredTerms).size !== requiredTerms.length) invalid();
  if (!Array.isArray(p.inputs) || p.inputs.length > CLOUD_LIMITS.inputs)
    invalid();
  const inputs = p.inputs.map((input) => {
    const row = object(input, ['title', 'text', 'contentHash']);
    const content = text(row.text, CLOUD_LIMITS.inputBytes);
    if (digest(row.contentHash) !== hashText(content)) invalid();
    return {
      title: text(row.title, 240),
      text: content,
      contentHash: hashText(content),
    };
  });
  if (
    inputs.reduce((bytes, input) => bytes + Buffer.byteLength(input.text), 0) >
    CLOUD_LIMITS.allInputBytes
  )
    invalid();
  const profileRows = object(p.profiles, [...CLOUD_ROLES]);
  const profiles = Object.fromEntries(
    CLOUD_ROLES.map((role) => {
      const profile = object(profileRows[role], ['providerId', 'modelRowId']);
      return [
        role,
        {
          providerId: integer(profile.providerId, 1, 2147483647),
          modelRowId: integer(profile.modelRowId, 1, 2147483647),
        },
      ];
    }),
  ) as Record<CloudRole, CloudProfile>;
  const b = object(p.budget, [
    'attempts',
    'estimatedTokens',
    'outputTokens',
    'durationMs',
    'reworks',
  ]);
  const budget = {
    attempts: integer(b.attempts, 1, CLOUD_LIMITS.attempts),
    estimatedTokens: integer(
      b.estimatedTokens,
      CLOUD_LIMITS.outputTokens,
      CLOUD_LIMITS.estimatedTokens,
    ),
    outputTokens: integer(b.outputTokens, 1, CLOUD_LIMITS.outputTokens),
    durationMs: integer(b.durationMs, 1, CLOUD_LIMITS.durationMs),
    reworks: integer(b.reworks, 0, CLOUD_LIMITS.reworks),
  };
  const task = text(p.task, CLOUD_LIMITS.taskBytes);
  const common: CloudPayloadFields = {
    consentVersion: CLOUD_CONSENT_VERSION,
    idempotencyKey: uuid(p.idempotencyKey),
    clientInstanceId: uuid(p.clientInstanceId),
    task,
    acceptance: {
      format: a.format as 'txt' | 'md' | 'csv',
      outputName,
      minChars,
      maxChars,
      requiredTerms,
      requireFullRead: a.requireFullRead,
    },
    inputs,
    profiles,
    budget,
    grantDurationMs: integer(p.grantDurationMs, 1, CLOUD_LIMITS.durationMs),
  };
  // v1 保留既有规范化/hash语义，不能用新客户端规则重新签旧任务。
  if (p.version === 1) {
    const source = object(p.source, ['cid', 'messageId', 'contentHash']);
    return {
      ...common,
      version: 1,
      source: {
        cid: integer(source.cid, 1, Number.MAX_SAFE_INTEGER),
        messageId: uuid(source.messageId),
        contentHash: digest(source.contentHash),
      },
    };
  }
  const kind = (p.source as Record<string, unknown> | null)?.kind;
  const source = object(
    p.source,
    kind === 'local_message'
      ? ['kind', 'cid', 'messageId', 'revision', 'contentHash']
      : ['kind', 'id', 'revision', 'contentHash'],
  );
  if (digest(source.contentHash) !== hashText(task)) invalid();
  const revision = integer(source.revision, 1, Number.MAX_SAFE_INTEGER);
  if (kind === 'local_message')
    return {
      ...common,
      version: 2,
      source: {
        kind,
        cid: integer(source.cid, 1, Number.MAX_SAFE_INTEGER),
        messageId: uuid(source.messageId),
        revision,
        contentHash: hashText(task),
      },
    };
  if (kind === 'draft')
    return {
      ...common,
      version: 2,
      source: {
        kind,
        id: uuid(source.id),
        revision,
        contentHash: hashText(task),
      },
    };
  return invalid();
}
export interface CloudOperation {
  operationId: string;
  expectedRevision: number;
}
export function parseOperation(value: unknown): CloudOperation {
  const p = object(value, ['operationId', 'expectedRevision']);
  return {
    operationId: uuid(p.operationId),
    expectedRevision: integer(p.expectedRevision, 1, 2147483647),
  };
}
