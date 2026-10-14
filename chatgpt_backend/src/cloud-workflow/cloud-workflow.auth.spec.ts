import type { Server } from 'node:http';
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import * as jwt from 'jsonwebtoken';
import request from 'supertest';
import { JWT_SECRET } from '../auth/jwt.const';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { CloudWorkflowController } from './cloud-workflow.controller';
import { CloudWorkflowGuard } from './cloud-workflow.guard';
import { CloudWorkflowService } from './cloud-workflow.service';
import { CloudWorkflowStore } from './cloud-workflow.store';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import { fixturePayload } from './cloud-workflow.fixture';

describe('cloud-specific verified auth HTTP (synthetic repository)', () => {
  let app: INestApplication;
  const user = {
    id: 7,
    userName: 'synthetic',
    role: 'user',
    banned: false,
    tokenVersion: 3,
  };
  const repo = { findOne: jest.fn() };
  const store = {
    create: jest.fn(),
    detail: jest.fn(),
    control: jest.fn(),
    results: jest.fn(),
    list: jest.fn(),
    revokeClient: jest.fn(),
    profiles: jest.fn(),
    byIdempotency: jest.fn(),
  };
  const token = (data: Record<string, unknown> = {}, exp?: number) =>
    jwt.sign(
      {
        userId: 7,
        tokenVersion: 3,
        ...data,
        ...(exp === undefined
          ? { exp: Math.floor(Date.now() / 1000) + 300 }
          : { exp }),
      },
      JWT_SECRET,
      { algorithm: 'HS256' },
    );
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [CloudWorkflowController],
      providers: [
        CloudWorkflowGuard,
        CloudWorkflowService,
        CloudWorkflowReadiness,
        {
          provide: TokenAuthenticationService,
          useValue: new TokenAuthenticationService(repo as never),
        },
        { provide: CloudWorkflowStore, useValue: store },
      ],
    }).compile();
    app = module.createNestApplication();
    await app.listen(0, '127.0.0.1');
  });
  beforeEach(() => {
    jest.clearAllMocks();
    repo.findOne.mockResolvedValue({ ...user });
  });
  afterAll(async () => {
    await app.close();
  });
  it.each(['guest-mode', 'forged', ''])(
    '能力路由也拒绝游客/假JWT %s',
    async (t) => {
      await request(app.getHttpServer() as Server)
        .get('/uapi/cloud-workflows/capability')
        .set('Authorization', `Bearer ${t}`)
        .expect(401);
    },
  );
  it('有效JWT能力仍false且正式提交0写入', async () => {
    await request(app.getHttpServer() as Server)
      .get('/uapi/cloud-workflows/capability')
      .set('Authorization', `Bearer ${token()}`)
      .expect(200)
      .expect((r) =>
        expect((r.body as { available: boolean }).available).toBe(false),
      );
    await request(app.getHttpServer() as Server)
      .post('/uapi/cloud-workflows')
      .set('Authorization', `Bearer ${token()}`)
      .send(fixturePayload())
      .expect(503);
    expect(store.create).not.toHaveBeenCalled();
  });
  it('exp缺失/过期、HS256之外、ban/version变化拒绝', async () => {
    const missing = jwt.sign({ userId: 7, tokenVersion: 3 }, JWT_SECRET, {
      algorithm: 'HS256',
    });
    const other = jwt.sign(
      { userId: 7, tokenVersion: 3, exp: Math.floor(Date.now() / 1000) + 300 },
      JWT_SECRET,
      { algorithm: 'HS384' },
    );
    for (const t of [missing, token({}, 1), other, token({ tokenVersion: 2 })])
      await request(app.getHttpServer() as Server)
        .get('/uapi/cloud-workflows/capability')
        .set('Authorization', `Bearer ${t}`)
        .expect(401);
    repo.findOne.mockResolvedValueOnce({ ...user, banned: true });
    await request(app.getHttpServer() as Server)
      .get('/uapi/cloud-workflows/capability')
      .set('Authorization', `Bearer ${token()}`)
      .expect(401);
  });
  it('普通auth兼容无exp，而云安全上下文只来自已验证旧版本', async () => {
    const a = new TokenAuthenticationService(repo as never);
    const t = jwt.sign({ userId: 7, tokenVersion: 3 }, JWT_SECRET, {
      algorithm: 'HS256',
    });
    expect(await a.verify(t)).toEqual({
      userId: 7,
      userName: 'synthetic',
      role: 'user',
      tokenVersion: 3,
    });
    expect(await a.verifyCloud(t)).toBeNull();
    const exp = Math.floor(Date.now() / 1000) + 30;
    expect(await a.verifyCloud(token({}, exp))).toEqual({
      userId: 7,
      securityVersion: 3,
      expiresAt: exp * 1000,
    });
    repo.findOne.mockResolvedValueOnce({ ...user, tokenVersion: 4 });
    expect(await a.verifyCloud(token())).toBeNull();
  });
  it('关闭时可读/停止/删除，owner来自JWT并非body/source', async () => {
    const id = fixturePayload().idempotencyKey;
    store.detail.mockResolvedValue({ state: 'paused' });
    store.control.mockResolvedValue({ state: 'cancelled' });
    await request(app.getHttpServer() as Server)
      .get(`/uapi/cloud-workflows/${id}`)
      .set('Authorization', `Bearer ${token()}`)
      .expect(200);
    await request(app.getHttpServer() as Server)
      .post(`/uapi/cloud-workflows/${id}/stop`)
      .set('Authorization', `Bearer ${token()}`)
      .send({ operationId: id, expectedRevision: 1 })
      .expect(201);
    await request(app.getHttpServer() as Server)
      .delete(`/uapi/cloud-workflows/${id}`)
      .set('Authorization', `Bearer ${token()}`)
      .send({ operationId: id, expectedRevision: 2 })
      .expect(200);
    expect((store.control.mock.calls as unknown[][])[0][0]).toMatchObject({
      userId: 7,
      securityVersion: 3,
    });
    await request(app.getHttpServer() as Server)
      .post(`/uapi/cloud-workflows/${id}/continue`)
      .set('Authorization', `Bearer ${token()}`)
      .send({ operationId: id, expectedRevision: 1, grantDurationMs: 1000 })
      .expect(503);
  });
  it('新静态路由仍经真实JWT，owner capability绑定及by-key纯读', async () => {
    const key = fixturePayload().idempotencyKey;
    store.profiles.mockResolvedValue([
      {
        providerId: 1,
        modelRowId: 2,
        modelId: 'synthetic',
        providerName: '服务',
        modelName: '模型',
      },
    ]);
    store.byIdempotency.mockResolvedValue({
      id: key,
      ownerId: 7,
      state: 'paused',
    });
    const cap = await request(app.getHttpServer() as Server)
      .get('/uapi/cloud-workflows/capability')
      .set('Authorization', `Bearer ${token()}`)
      .expect(200);
    expect(cap.body).toMatchObject({ ownerId: 7, available: false });
    for (const path of ['profiles', `by-idempotency/${key}`]) {
      await request(app.getHttpServer() as Server)
        .get(`/uapi/cloud-workflows/${path}`)
        .set('Authorization', 'Bearer guest-mode')
        .expect(401);
      await request(app.getHttpServer() as Server)
        .get(`/uapi/cloud-workflows/${path}`)
        .set('Authorization', `Bearer ${token()}`)
        .expect(200);
    }
    expect(store.byIdempotency).toHaveBeenCalledWith(7, key);
    expect(store.detail).not.toHaveBeenCalled(); // 静态路由未被:id吞掉。
    expect(store.create).not.toHaveBeenCalled();
    expect(store.control).not.toHaveBeenCalled();
  });
});
