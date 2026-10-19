import type { Server } from 'node:http';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { DataSource } from 'typeorm';
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { KnowledgeTeamService } from './knowledge-team.service';
import { KnowledgeTeamController } from './knowledge-team.controller';
import { TeamInvite, TeamWorkspace } from './team-workspace.entity';
import { KnowledgeTeams1792360000000 } from '../migrations/1792360000000-KnowledgeTeams';
import { TokenAuthenticationService } from '../auth/token-authentication.service';

const owned = process.env.KNOWLEDGE_PG_TEST === '1' ? describe : describe.skip;
owned('团队知识库：真实PostgreSQL迁移、行锁和HTTP权限', () => {
  let ds: DataSource,
    app: INestApplication<Server>,
    service: KnowledgeTeamService;
  let id: string, docUid: string;
  const auth = (actor: number) => `Bearer synthetic-team-actor-${actor}`;
  beforeAll(async () => {
    const cfg = JSON.parse(
      readFileSync(
        process.env.KNOWLEDGE_PG_FIXTURE ?? '/tmp/chatai-p1p2-pg.json',
        'utf8',
      ),
    ) as { host: string; port: number; username: string; database: string };
    if (
      !String(cfg.host).startsWith('/tmp/chatai-knowledge-pg-') ||
      cfg.username !== 'knowledge_fixture'
    )
      throw new Error('isolated test fixture required');
    ds = new DataSource({
      type: 'postgres',
      host: cfg.host,
      port: cfg.port,
      username: cfg.username,
      database: cfg.database,
      entities: [TeamWorkspace, TeamInvite],
      synchronize: false,
    });
    await ds.initialize();
    const q = ds.createQueryRunner();
    try {
      await new KnowledgeTeams1792360000000().up(q);
    } finally {
      await q.release();
    }
    const module = await Test.createTestingModule({
      controllers: [KnowledgeTeamController],
      providers: [
        KnowledgeTeamService,
        { provide: DataSource, useValue: ds },
        {
          provide: TokenAuthenticationService,
          useValue: {
            verify: (token: string) => {
              const match = /^synthetic-team-actor-([1-9])$/.exec(token);
              return match
                ? {
                    userId: Number(match[1]),
                    role: 'user',
                    userName: 'synthetic',
                    tokenVersion: 0,
                  }
                : null;
            },
          },
        },
      ],
    }).compile();
    service = module.get(KnowledgeTeamService);
    app = module.createNestApplication({ logger: false });
    await app.init();
  });
  afterAll(async () => {
    if (app) await app.close();
    if (ds?.isInitialized) {
      const q = ds.createQueryRunner();
      try {
        await new KnowledgeTeams1792360000000().down(q);
      } finally {
        await q.release();
        await ds.destroy();
      }
    }
  });
  test('未认证不能列出团队，普通用户可创建自己的团队', async () => {
    await request(app.getHttpServer()).get('/uapi/knowledge/teams').expect(401);
    const result = await request(app.getHttpServer())
      .post('/uapi/knowledge/teams')
      .set('Authorization', auth(1))
      .send({ name: '测试团队' })
      .expect(201);
    const created = result.body as { data: { id: string; role: string } };
    id = created.data.id;
    expect(created.data.role).toBe('owner');
    const outsider = await request(app.getHttpServer())
      .get('/uapi/knowledge/teams')
      .set('Authorization', auth(9))
      .expect(200);
    expect((outsider.body as { data: unknown }).data).toEqual([]);
    await request(app.getHttpServer())
      .get(`/uapi/knowledge/teams/${id}`)
      .set('Authorization', auth(9))
      .expect(403);
  });
  test('邀请码仅存SHA，不能邀请owner，一次性邀请并发只有一个加入成功', async () => {
    await expect(service.invite(1, id, 'owner')).rejects.toThrow();
    const invitation = await service.invite(1, id, 'editor');
    const stored = await ds
      .getRepository(TeamInvite)
      .createQueryBuilder('i')
      .addSelect('i.codeHash')
      .where('i.id = :id', { id: invitation.id })
      .getOneOrFail();
    expect(stored.codeHash).not.toContain(invitation.code);
    expect(stored.codeHash).toHaveLength(64);
    const joined = await Promise.allSettled([
      service.join(2, invitation.code),
      service.join(3, invitation.code),
    ]);
    expect(joined.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
    const team = await service.read(1, id);
    if (!team.members['2']) {
      const i = await service.invite(1, id, 'editor');
      await service.join(2, i.code);
    }
    const viewer = await service.invite(1, id, 'viewer');
    await service.join(4, viewer.code);
    await expect(service.invite(4, id, 'viewer')).rejects.toThrow();
  });
  test('撤销和过期邀请均不可加入', async () => {
    const cancelled = await service.invite(1, id, 'viewer');
    await service.cancelInvite(1, id, cancelled.id);
    await expect(service.join(5, cancelled.code)).rejects.toThrow();
    const expired = await service.invite(1, id, 'viewer');
    await ds
      .getRepository(TeamInvite)
      .update(expired.id, { expiresAt: Date.now() - 1 });
    await expect(service.join(5, expired.code)).rejects.toThrow();
  });
  test('viewer不可编辑、editor可共享、并发CAS不丢失更新', async () => {
    docUid = randomUUID();
    const body = {
      title: '政策',
      pages: ['可在7天内申请退款。'],
      expectedRevision: 0,
      archived: false,
    };
    await request(app.getHttpServer())
      .put(`/uapi/knowledge/teams/${id}/documents/${docUid}`)
      .set('Authorization', auth(4))
      .send(body)
      .expect(403);
    const doc = await service.putDocument(2, id, docUid, body);
    expect(doc.revision).toBe(1);
    const changes = await Promise.allSettled([
      service.putDocument(2, id, docUid, {
        ...body,
        expectedRevision: 1,
        pages: ['可在14天内申请退款。'],
      }),
      service.putDocument(1, id, docUid, {
        ...body,
        expectedRevision: 1,
        pages: ['可在30天内申请退款。'],
      }),
    ]);
    expect(changes.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
  });
  test('拒绝跨团队写入和超额正文，所有者不可被移除或降级', async () => {
    const foreign = await service.create(9, '另一个团队');
    await expect(
      service.putDocument(2, foreign.id, randomUUID(), {
        title: 'x',
        pages: ['secret'],
        expectedRevision: 0,
        archived: false,
      }),
    ).rejects.toThrow();
    expect(() =>
      service.putDocument(2, id, randomUUID(), {
        title: 'x',
        pages: ['x'.repeat(30001)],
        expectedRevision: 0,
        archived: false,
      }),
    ).toThrow();
    await expect(service.member(1, id, 1, null)).rejects.toThrow();
    await expect(service.member(1, id, 1, 'viewer')).rejects.toThrow();
  });
  function answer(doc: {
    uid: string;
    title: string;
    revision: number;
    createdAt: number;
    chunks: { seq: number; pageNumber: number | null; content: string }[];
  }) {
    const chunk = doc.chunks[0];
    const source = {
      uid: doc.uid,
      title: doc.title,
      revision: doc.revision,
      importedAt: doc.createdAt,
      seq: chunk.seq,
      pageNumber: chunk.pageNumber,
      content: chunk.content,
      sourceAsset: '',
      docId: 1,
      chunkId: 1,
    };
    return {
      question: '退款期限？',
      model: 'synthetic',
      createdAt: 1,
      status: 'cited',
      sources: [source],
      claims: [
        {
          text: '请按原文期限申请。',
          evidence: [{ source, quote: chunk.content }],
        },
      ],
    };
  }
  test('问答逐字引用与当前版本校验；伪造或陈旧引文不保存', async () => {
    const current = (await service.read(4, id)).documents.find(
      (d) => d.uid === docUid,
    )!;
    const valid = answer(current);
    const saved = await service.saveAnswer(4, id, valid);
    expect(saved.authorId).toBe(4);
    const forged = structuredClone(valid);
    forged.claims[0].evidence[0].quote = '这不是团队资料中的正文。';
    await expect(service.saveAnswer(4, id, forged)).rejects.toThrow();
    const changed = await service.putDocument(2, id, docUid, {
      title: current.title,
      pages: ['新版规定需要审核。'],
      expectedRevision: current.revision,
      archived: false,
    });
    await expect(service.saveAnswer(4, id, valid)).rejects.toThrow();
    await service.putDocument(2, id, docUid, {
      title: changed.title,
      pages: ['新版规定需要审核。'],
      expectedRevision: changed.revision,
      archived: true,
    });
    await expect(service.saveAnswer(4, id, answer(changed))).rejects.toThrow();
    expect((await service.read(1, id)).answers).toHaveLength(1);
  });
  test('移除成员后立即拒绝原读写与问答请求；审计只有owner可见', async () => {
    await service.member(1, id, 2, null);
    await expect(service.read(2, id)).rejects.toThrow();
    await expect(
      service.putDocument(2, id, docUid, {
        title: '政策',
        pages: ['不应保存。'],
        expectedRevision: 4,
        archived: false,
      }),
    ).rejects.toThrow();
    await request(app.getHttpServer())
      .get(`/uapi/knowledge/teams/${id}/audit`)
      .set('Authorization', auth(4))
      .expect(403);
    const audit = await service.audit(1, id);
    expect(audit.some((a) => a.action === 'answer_save')).toBe(true);
    expect(audit.every((a) => !JSON.stringify(a).includes('新版规定'))).toBe(
      true,
    );
  });
});
