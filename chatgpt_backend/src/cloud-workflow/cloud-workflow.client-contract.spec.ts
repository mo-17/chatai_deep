import { NotFoundException, ForbiddenException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { DataSource } from 'typeorm';
import {
  canonical,
  hashText,
  parseCloudPayload,
} from './cloud-workflow.contract';
import { fixturePayload } from './cloud-workflow.fixture';
import { CloudWorkflowStore } from './cloud-workflow.store';
import { buildWire, type ExecutionPlan } from './cloud-workflow.execution';

describe('C2 source/owner/read-only client contract', () => {
  it('v1规范化仍逐字段/规范JSON不变，旧source不是新task hash', () => {
    const p = fixturePayload();
    expect(canonical(parseCloudPayload(p))).toBe(canonical(p));
    expect(p.source.contentHash).not.toBe(hashText(p.task));
  });
  it('v2 source只作客户端声明，两个来源均不进入实际节点wire', () => {
    for (const source of [
      {
        kind: 'draft',
        id: randomUUID(),
        revision: 7,
        contentHash: hashText(fixturePayload().task),
      },
      {
        kind: 'local_message',
        cid: 12345,
        messageId: randomUUID(),
        revision: 8,
        contentHash: hashText(fixturePayload().task),
      },
    ]) {
      const payload = parseCloudPayload({
        ...fixturePayload(),
        version: 2,
        source,
      });
      const plan = {
        parent: {
          output_tokens: 2048,
          grant_version: 1,
          payload_hash: 'h',
          reworks: 0,
        },
        payload,
        steps: [{ id: 's', role: 'analysis', model_id: 'fixed', revision: 1 }],
        results: [],
      } as unknown as ExecutionPlan;
      const wire = buildWire(plan, plan.steps[0]);
      expect(wire.body).toContain(payload.task);
      expect(wire.body).not.toContain('local_message');
      expect(wire.body).not.toContain(
        source.kind === 'draft' ? source.id : source.messageId,
      );
      expect(wire.body).not.toContain('12345');
    }
  });
  for (const kind of ['local_message', 'draft'] as const) {
    it(`v2 ${kind}精确规范化，UUID/revision及task hash`, () => {
      const p = fixturePayload();
      const source =
        kind === 'draft'
          ? {
              kind,
              id: randomUUID(),
              revision: 3,
              contentHash: hashText(p.task),
            }
          : {
              kind,
              cid: 77,
              messageId: randomUUID(),
              revision: 4,
              contentHash: hashText(p.task),
            };
      const v = { ...p, version: 2, source };
      expect(parseCloudPayload(v)).toEqual(v);
      for (const change of [
        { revision: 0 },
        { revision: '1' },
        { revision: 1.1 },
        { contentHash: p.source.contentHash },
        { ownerId: 7 },
        { path: '/private' },
        { kind: 'future' },
        { ...(kind === 'draft' ? { cid: 77 } : { id: randomUUID() }) },
      ]) {
        expect(() =>
          parseCloudPayload({ ...v, source: { ...source, ...change } }),
        ).toThrow();
      }
      expect(() =>
        parseCloudPayload({ ...v, source: { ...source, revision: undefined } }),
      ).toThrow();
    });
  }
  it('by-key仅owner查询/回执，跨owner与不存在统一404，无写操作', async () => {
    const query = jest
      .fn()
      .mockResolvedValueOnce([{ id: randomUUID(), ownerId: 7 }])
      .mockResolvedValueOnce([]);
    const store = new CloudWorkflowStore({ query } as unknown as DataSource);
    const key = randomUUID();
    await store.byIdempotency(7, key);
    await expect(store.byIdempotency(8, key)).rejects.toBeInstanceOf(
      NotFoundException,
    );
    const calls = query.mock.calls as unknown as Array<[string, unknown[]]>;
    expect(calls.map((x) => x[1])).toEqual([
      [7, key],
      [8, key],
    ]);
    expect(calls.every((x) => /^SELECT /.test(x[0]))).toBe(true);
    expect(calls[0][0]).not.toContain('SELECT *');
    expect(calls[0][0]).not.toContain('client_instance_id');
  });
  it('profile SQL只显式安全列，双enabled且不绕catalog flag', async () => {
    const query = jest
      .fn()
      .mockResolvedValueOnce([{ catalogPublic: false }])
      .mockResolvedValueOnce([{ catalogPublic: true }])
      .mockResolvedValueOnce([]);
    const store = new CloudWorkflowStore({ query } as unknown as DataSource);
    await expect(store.profiles()).rejects.toBeInstanceOf(ForbiddenException);
    expect(query).toHaveBeenCalledTimes(1);
    expect(await store.profiles()).toEqual([]);
    const sql = (query.mock.calls as unknown as Array<[string]>)[2][0];
    expect(sql).toContain('p.enabled=true AND m.enabled=true');
    for (const secret of ['apiKey', 'baseUrl', 'profile_hash', 'SELECT *'])
      expect(sql).not.toContain(secret);
  });
});
