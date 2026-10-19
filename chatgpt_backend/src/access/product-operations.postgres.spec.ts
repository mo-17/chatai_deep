import { DataSource } from 'typeorm';
import { ChatService } from '../chat/chat.service';
import { Usage } from '../chat/usage.entity';
import type { AiProvider } from '../ai/ai-provider.entity';
import type { Response as ExpressResponse } from 'express';
import { resolve } from 'node:path';
import { AccessService } from './access.service';
import { AccessPolicy } from './access-policy.entity';
import { AccessRequest } from './access-request.entity';
import { UserFeedback } from '../feedback/feedback.entity';
import { FeedbackService } from '../feedback/feedback.service';
import { buildPostgresOptions } from '../database/postgres-options';
import { CreateCoreBaseline1783990000000 } from '../migrations/1783990000000-CreateCoreBaseline';
import { AddProductOperations1784120000000 } from '../migrations/1784120000000-AddProductOperations';
import { AddUserTokenVersion1784030000000 } from '../migrations/1784030000000-AddUserTokenVersion';
import { TrialGuardrails1784130000000 } from '../migrations/1784130000000-TrialGuardrails';

const integration =
  process.env.PRODUCT_PG_INTEGRATION === '1' ? describe : describe.skip;
integration('Product operations PostgreSQL', () => {
  let admin: DataSource,
    db: DataSource,
    access: AccessService,
    feedback: FeedbackService;
  const name = `chatai_product_${process.pid}`;
  beforeAll(async () => {
    const options = buildPostgresOptions(
      (key) => process.env[key],
      resolve(__dirname, '..'),
    );
    admin = new DataSource({ ...options, database: 'postgres' });
    await admin.initialize();
    await admin.query(`CREATE DATABASE "${name}"`);
    db = new DataSource({
      ...options,
      database: name,
      migrations: [
        CreateCoreBaseline1783990000000,
        AddUserTokenVersion1784030000000,
        AddProductOperations1784120000000,
        TrialGuardrails1784130000000,
      ],
    });
    await db.initialize();
    await db.runMigrations();
    access = new AccessService(db);
    feedback = new FeedbackService(db);
  });
  afterAll(async () => {
    if (db?.isInitialized) await db.destroy();
    if (admin?.isInitialized) {
      await admin.query(`DROP DATABASE IF EXISTS "${name}"`);
      await admin.destroy();
    }
  });
  beforeEach(async () => {
    await db.getRepository(AccessRequest).clear();
    await db.getRepository(UserFeedback).clear();
    await db.getRepository(AccessPolicy).clear();
    await db.query('DELETE FROM users');
    await db.query('DELETE FROM ai_models');
    await db.query('DELETE FROM ai_providers');
    await access.update({
      limitsEnabled: true,
      dailyTokens: 10000,
      globalDailyTokens: 100000,
      maxConcurrent: 1,
      maxOutputTokens: 600,
    });
  });
  const body = {
    model: 'synthetic-only',
    messages: [{ role: 'user', content: 'hello' }],
  };
  it('migration preserves existing reservation rows and applies safe policy defaults', async () => {
    const runner = db.createQueryRunner();
    const migration = new TrialGuardrails1784130000000();
    try {
      await migration.down(runner);
      await runner.query(
        `INSERT INTO access_requests(id,"userId",day,model,"chargedTokens") VALUES('11d9ad01-66db-4a83-9ac6-6962b24efc57',1,'2026-01-01','synthetic',123)`,
      );
      await migration.up(runner);
      const [row] = await runner.query<
        Array<{ chargedTokens: number; old: boolean }>
      >(
        `SELECT "chargedTokens", "createdAt" < now()-interval '1 minute' AS old FROM access_requests`,
      );
      expect(row).toEqual({ chargedTokens: 123, old: true });
      expect(await access.policy()).toMatchObject({
        requireVerifiedEmail: true,
        requestsPerMinute: 6,
        globalMaxConcurrent: 4,
        dailyTokens: 10000,
      });
    } finally {
      await runner.release();
    }
  });
  it('requires verified email for alias, direct model and alternate proxy requests', async () => {
    await db.query(
      `INSERT INTO ai_providers(code,"displayName","apiKey","baseUrl") VALUES('synthetic','Synthetic','test-only','https://synthetic.invalid')`,
    );
    await db.query(
      `INSERT INTO ai_models("providerId","modelId","displayName") SELECT id,'synthetic-flash','Synthetic' FROM ai_providers WHERE code='synthetic'`,
    );
    await db.query(
      `INSERT INTO users(id,"userName",email) VALUES(91,'qa-unverified','qa@example.invalid')`,
    );
    await access.update({
      trialEnabled: true,
      trialProviderCode: 'synthetic',
      trialModel: 'synthetic-flash',
    });
    for (const model of [
      '__aipu_trial__',
      'synthetic-flash',
      'another-model',
    ]) {
      await expect(access.admit(91, { ...body, model })).rejects.toMatchObject({
        status: 403,
      });
    }
    expect((await access.status(91)).trialEligible).toBe(false);
    expect(await db.getRepository(AccessRequest).count()).toBe(0);
    await db.query(`UPDATE users SET "emailVerifiedAt"=now() WHERE id=91`);
    expect((await access.status(91)).trialEligible).toBe(true);
    const admission = await access.admit(91, {
      ...body,
      model: '__aipu_trial__',
    });
    expect(admission.body.model).toBe('synthetic-flash');
    await access.finish(admission.id, { total_tokens: 10 });
    await access.update({ trialEnabled: false });
    await expect(
      access.admit(91, { ...body, model: 'synthetic-flash' }),
    ).rejects.toMatchObject({ status: 403 });
  });
  it('minute limit survives settlement and enforces global concurrency across instances', async () => {
    await access.update({ requestsPerMinute: 1, globalMaxConcurrent: 1 });
    const other = new AccessService(db);
    const first = await access.admit(1, body);
    await expect(other.admit(2, body)).rejects.toMatchObject({ status: 429 });
    await access.finish(first.id, { total_tokens: 1 });
    await expect(other.admit(1, body)).rejects.toMatchObject({ status: 429 });
    expect((await other.admit(2, body)).id).toBeTruthy();
    await db.query(
      `UPDATE access_requests SET "createdAt"=now()-interval '2 minutes' WHERE "userId"=1`,
    );
    await db.query(
      `UPDATE access_requests SET "activeUntil"=NULL WHERE "userId"=2`,
    );
    expect((await other.admit(1, body)).id).toBeTruthy();
  });
  it('serializes concurrent admission across two service instances', async () => {
    const other = new AccessService(db);
    const results = await Promise.allSettled(
      [access, other, access, other].map((service) => service.admit(1, body)),
    );
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
    expect(await db.getRepository(AccessRequest).count()).toBe(1);
    const value = (
      results.find((r) => r.status === 'fulfilled') as PromiseFulfilledResult<
        Awaited<ReturnType<AccessService['admit']>>
      >
    ).value;
    await access.finish(value.id, { total_tokens: 100 });
    const status = await access.status(1);
    expect(status.usedTokens).toBe(100);
    expect(status.remainingTokens).toBe(9900);
    expect((await other.admit(1, body)).id).toBeTruthy();
  });
  it('keeps unknown usage charged and rejects user/global overspend', async () => {
    await access.update({ dailyTokens: 1000, globalDailyTokens: 1000 });
    const first = await access.admit(1, body);
    await access.finish(first.id);
    const status = await access.status(1);
    expect(status.usedTokens).toBeGreaterThan(600);
    await expect(access.admit(1, body)).rejects.toMatchObject({ status: 429 });
    await expect(access.admit(2, body)).rejects.toMatchObject({ status: 429 });
    expect((await access.status(2)).usedTokens).toBe(0);
  });
  it('settles real service non-stream and SSE paths; failures retain reservation', async () => {
    const chat = new ChatService(
      db.getRepository(Usage),
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      access,
    );
    jest.spyOn(chat, 'resolveProvider').mockResolvedValue({
      code: 'synthetic',
      apiKey: 'synthetic-only',
      baseUrl: 'https://synthetic.invalid',
      enabled: true,
    } as AiProvider);
    const call = jest.spyOn(chat, 'callUpstream').mockResolvedValue({
      choices: [{ message: { content: 'synthetic response' } }],
      usage: { prompt_tokens: 10, completion_tokens: 7, total_tokens: 17 },
    });
    await chat.complete(1, body);
    expect((await access.status(1)).usedTokens).toBe(17);
    call.mockRejectedValueOnce(Error('synthetic failure'));
    await expect(chat.complete(1, body)).rejects.toThrow('synthetic failure');
    expect((await access.status(1)).usedTokens).toBeGreaterThan(600);
    const fetchSpy = jest.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        'data: ' +
          JSON.stringify({
            choices: [],
            usage: {
              prompt_tokens: 10,
              completion_tokens: 7,
              total_tokens: 17,
            },
          }) +
          '\n\ndata: [DONE]\n\n',
        { status: 200 },
      ),
    );
    const res = {
      destroyed: false,
      writableEnded: false,
      status: jest.fn(),
      setHeader: jest.fn(),
      flushHeaders: jest.fn(),
      write: jest.fn(),
      end: jest.fn(),
    };
    try {
      await chat.completeStream(2, body, res as unknown as ExpressResponse);
      expect(res.end).toHaveBeenCalled();
      expect((await access.status(2)).usedTokens).toBe(17);
    } finally {
      fetchSpy.mockRestore();
    }
    expect(await db.getRepository(AccessRequest).countBy({ userId: 1 })).toBe(
      2,
    );
  });

  it('disabled trial makes no reservation; cannot enable unconfigured model', async () => {
    await expect(
      access.admit(1, { ...body, model: '__aipu_trial__' }),
    ).rejects.toMatchObject({ status: 403 });
    await expect(
      access.update({
        trialEnabled: true,
        trialProviderCode: 'deepseek',
        trialModel: 'deepseek-flash',
      }),
    ).rejects.toMatchObject({ status: 400 });
    expect(await db.getRepository(AccessRequest).count()).toBe(0);
  });
  it('feedback retry is idempotent; users only see their own rows and admin replies', async () => {
    const input = {
      requestId: '22d9ad01-66db-4a83-9ac6-6962b24efc57',
      category: 'bug',
      content: 'synthetic test feedback',
      diagnostics: { appVersion: '1.0.6+16', token: 'must-be-dropped' },
    };
    const first = await feedback.submit(1, input);
    expect((await feedback.submit(1, input)).id).toBe(first.id);
    expect((await feedback.list(2)).list).toHaveLength(0);
    expect((await feedback.list(undefined)).total).toBe(1);
    await feedback.reply(first.id, {
      status: 'resolved',
      reply: 'synthetic reply',
    });
    expect((await feedback.list(1)).list[0].reply).toBe('synthetic reply');
    expect((await feedback.list(1)).list[0].diagnostics).toEqual({
      appVersion: '1.0.6+16',
    });
    await expect(
      feedback.submit(1, { ...input, content: 'changed body same id' }),
    ).rejects.toMatchObject({ status: 409 });
  });
});
