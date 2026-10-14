import {
  acceptancePassed,
  buildWire,
  parseReview,
} from './cloud-workflow.execution';
import { fixturePayload } from './cloud-workflow.fixture';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import type { ExecutionPlan } from './cloud-workflow.execution';

describe('cloud explicit text execution contract', () => {
  it('review rejects invalid JSON, unknown fields, wrong types and oversized feedback', () => {
    for (const text of [
      '```json\n{}\n```',
      '{}',
      '{"passed":"yes","feedback":""}',
      '{"passed":true,"feedback":"","other":1}',
      JSON.stringify({ passed: true, feedback: 'x'.repeat(4001) }),
    ])
      expect(parseReview(text)).toBeNull();
    expect(parseReview('{"passed":false,"feedback":"revise"}')).toEqual({
      passed: false,
      feedback: 'revise',
    });
  });
  it('local checks count codepoints and verify terms and lowest text/MD/CSV syntax', () => {
    const a = {
      ...fixturePayload().acceptance,
      format: 'txt' as const,
      minChars: 2,
      maxChars: 2,
      requiredTerms: ['😀'],
    };
    expect(acceptancePassed('😀a', a)).toBe(true);
    expect(acceptancePassed('😀', a)).toBe(false);
    const csv = {
      ...a,
      format: 'csv' as const,
      minChars: 0,
      maxChars: 100,
      requiredTerms: [],
    };
    expect(acceptancePassed('a,b\n"c,d",e', csv)).toBe(true);
    expect(acceptancePassed('a,b\nc', csv)).toBe(false);
    expect(acceptancePassed('"unclosed', csv)).toBe(false);
    expect(acceptancePassed('```\ntext', { ...csv, format: 'md' })).toBe(false);
  });
  it('wire is deterministic, snapshots preserved and no history/credentials/tools fields', () => {
    const payload = fixturePayload();
    const plan = {
      parent: {
        output_tokens: 2048,
        grant_version: 1,
        payload_hash: 'h',
        reworks: 0,
      },
      payload,
      steps: [
        { id: 's', role: 'analysis', model_id: 'fixed-model', revision: 1 },
      ],
      results: [],
    } as unknown as ExecutionPlan;
    const wire = buildWire(plan, plan.steps[0]);
    expect(buildWire(plan, plan.steps[0])).toEqual(wire);
    const body = JSON.parse(wire.body) as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual([
      'max_tokens',
      'messages',
      'model',
      'stream',
    ]);
    expect(wire.body).toContain(payload.inputs[0].text);
    expect(wire.body).toContain('confirmedAcceptance');
    expect(wire.inputEstimate).toBe(
      Math.ceil(Buffer.byteLength(wire.body) / 2),
    );
  });
  it('worker registration does not unlock production readiness', () => {
    const previous = process.env.CLOUD_WORKFLOW_ENABLED;
    process.env.CLOUD_WORKFLOW_ENABLED = 'true';
    try {
      expect(new CloudWorkflowReadiness().capabilities().available).toBe(false);
    } finally {
      if (previous === undefined) delete process.env.CLOUD_WORKFLOW_ENABLED;
      else process.env.CLOUD_WORKFLOW_ENABLED = previous;
    }
  });
});
