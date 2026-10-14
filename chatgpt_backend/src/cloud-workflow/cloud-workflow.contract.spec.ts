import { BadRequestException } from '@nestjs/common';
import {
  canonical,
  parseCloudPayload,
  parseOperation,
  CLOUD_LIMITS,
  hashText,
} from './cloud-workflow.contract';
import { fixturePayload } from './cloud-workflow.fixture';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';

describe('cloud workflow strict bounded contract', () => {
  it('规范内容键顺序稳定，Unicode文本/快照哈希闭合', () => {
    const p = fixturePayload();
    p.task = '合成😀';
    expect(parseCloudPayload(p)).toEqual(p);
    expect(canonical({ b: 2, a: 1 })).toBe(canonical({ a: 1, b: 2 }));
    expect(CLOUD_LIMITS).toMatchObject({
      attempts: 8,
      estimatedTokens: 32000,
      outputTokens: 2048,
      durationMs: 600000,
      queued: 32,
    });
  });
  it.each([
    'apiKey',
    'jwt',
    'localPath',
    'history',
    'personalMemory',
    'assistantMemory',
    'roleMetadata',
    'url',
    'ownerId',
  ])('拒绝未授权字段%s', (key) => {
    expect(() =>
      parseCloudPayload({ ...fixturePayload(), [key]: 'untrusted' }),
    ).toThrow(BadRequestException);
  });
  it('每一嵌套层未知字段和错误类型拒绝，不宽松修补', () => {
    const variants: unknown[] = [];
    for (const key of ['source', 'acceptance', 'profiles', 'budget']) {
      const p = fixturePayload();
      (p as unknown as Record<string, unknown>)[key] = {
        ...(p as unknown as Record<string, Record<string, unknown>>)[key],
        extra: true,
      };
      variants.push(p);
    }
    const p = fixturePayload();
    variants.push(
      { ...p, inputs: [{ ...p.inputs[0], path: '/private' }] },
      {
        ...p,
        profiles: {
          ...p.profiles,
          analysis: { ...p.profiles.analysis, key: 'secret' },
        },
      },
      { ...p, budget: { ...p.budget, attempts: '8' } },
      { ...p, version: 2 },
      { ...p, consentVersion: 'future' },
    );
    variants.forEach((v) =>
      expect(() => parseCloudPayload(v)).toThrow(BadRequestException),
    );
  });
  it('UTF8而非JS length限额、空白/孤立surrogate/深度/数量/内容篡改拒绝', () => {
    const p = fixturePayload();
    for (const task of [' ', '\ud800', '中'.repeat(4001)])
      expect(() => parseCloudPayload({ ...p, task })).toThrow();
    const row = {
      title: 'text',
      text: '中'.repeat(3000),
      contentHash: hashText('中'.repeat(3000)),
    };
    expect(() =>
      parseCloudPayload({ ...p, inputs: [row, row, row] }),
    ).toThrow();
    expect(() =>
      parseCloudPayload({ ...p, inputs: Array(5).fill(p.inputs[0]) }),
    ).toThrow();
    expect(() =>
      parseCloudPayload({
        ...p,
        inputs: [{ ...p.inputs[0], contentHash: '0'.repeat(64) }],
      }),
    ).toThrow();
    expect(() =>
      parseCloudPayload({
        ...p,
        profiles: { x: { x: { x: { x: { x: { x: { x: 1 } } } } } } },
      }),
    ).toThrow();
  });
  it('预算与单文本验收不接受隐藏多输出/JSON/逃逸名称或超限', () => {
    const p = fixturePayload();
    for (const budget of [
      { ...p.budget, attempts: 9 },
      { ...p.budget, estimatedTokens: 32001 },
      { ...p.budget, outputTokens: 2049 },
      { ...p.budget, durationMs: 600001 },
      { ...p.budget, reworks: 2 },
    ])
      expect(() => parseCloudPayload({ ...p, budget })).toThrow();
    for (const acceptance of [
      { ...p.acceptance, outputName: '../a.md' },
      { ...p.acceptance, format: 'json' },
      { ...p.acceptance, outputNames: ['a.md', 'b.md'] },
      { ...p.acceptance, minChars: 12001 },
      { ...p.acceptance, requiredTerms: ['x', 'x'] },
    ])
      expect(() => parseCloudPayload({ ...p, acceptance })).toThrow();
    expect(() =>
      parseOperation({
        operationId: p.idempotencyKey,
        expectedRevision: 1,
        force: true,
      }),
    ).toThrow();
  });
  it('生产readiness不可被环境单开，拒绝create/continue能力而不是假托管', () => {
    const old = process.env.CLOUD_WORKFLOW_ENABLED;
    try {
      delete process.env.CLOUD_WORKFLOW_ENABLED;
      const r = new CloudWorkflowReadiness();
      expect(r.capabilities()).toMatchObject({
        available: false,
        reason: 'disabled',
      });
      process.env.CLOUD_WORKFLOW_ENABLED = 'true';
      expect(r.capabilities()).toMatchObject({
        available: false,
        reason: 'runtime_not_ready',
      });
      expect(() => r.requireReady()).toThrow();
    } finally {
      if (old === undefined) delete process.env.CLOUD_WORKFLOW_ENABLED;
      else process.env.CLOUD_WORKFLOW_ENABLED = old;
    }
  });
});
