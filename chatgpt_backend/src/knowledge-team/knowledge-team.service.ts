import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import {
  TeamWorkspace,
  TeamInvite,
  type TeamRole,
  type TeamDocument,
} from './team-workspace.entity';

function text(value: unknown, max: number, label: string) {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max)
    throw new BadRequestException(`${label}无效`);
  return value.trim();
}
function uuid(value: string) {
  if (!/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(value))
    throw new BadRequestException('身份无效');
}
function role(value: unknown): 'editor' | 'viewer' {
  if (value !== 'editor' && value !== 'viewer')
    throw new BadRequestException('角色无效');
  return value;
}
@Injectable()
export class KnowledgeTeamService {
  constructor(private readonly data: DataSource) {}
  private async within<T>(
    actor: number,
    id: string,
    permission: TeamRole | 'read',
    action: string,
    run: (team: TeamWorkspace, tx: EntityManager) => Promise<T> | T,
  ): Promise<T> {
    uuid(id);
    return this.data.transaction(async (tx) => {
      const team = await tx.findOne(TeamWorkspace, {
        where: { id },
        lock: { mode: 'pessimistic_write' },
      });
      if (!team) throw new NotFoundException('团队不存在或无访问权限');
      const access = team.members[String(actor)];
      if (
        !access ||
        (permission === 'owner' && access !== 'owner') ||
        (permission === 'editor' && access === 'viewer')
      )
        throw new ForbiddenException('团队权限不足');
      const result = await run(team, tx);
      team.audit = [
        ...team.audit,
        { at: Date.now(), actor, action, target: id },
      ].slice(-200);
      await tx.save(TeamWorkspace, team);
      return result;
    });
  }
  async create(actor: number, rawName: unknown) {
    const name = text(rawName, 80, '团队名称');
    return this.data.transaction(async (tx) => {
      // 每个用户创建团队的写入串行化，避免并发绕过数量限制。
      await tx.query('SELECT pg_advisory_xact_lock($1, $2)', [178414, actor]);
      if ((await tx.count(TeamWorkspace, { where: { ownerId: actor } })) >= 5)
        throw new BadRequestException('最多创建5个团队');
      const team = tx.create(TeamWorkspace, {
        ownerId: actor,
        name,
        revision: 1,
        members: { [actor]: 'owner' },
        documents: {},
        answers: [],
        audit: [{ at: Date.now(), actor, action: 'create', target: '' }],
        createdAt: Date.now(),
      });
      return this.summary(await tx.save(team), actor);
    });
  }
  private summary(t: TeamWorkspace, actor: number) {
    return {
      id: t.id,
      name: t.name,
      revision: t.revision,
      role: t.members[String(actor)],
      members: t.members,
      documentCount: Object.keys(t.documents).length,
    };
  }
  async list(actor: number) {
    const teams = await this.data
      .getRepository(TeamWorkspace)
      .createQueryBuilder('t')
      .where('t.members ? :actor', { actor: String(actor) })
      .orderBy('t.createdAt', 'DESC')
      .take(100)
      .getMany();
    return teams.map((t) => this.summary(t, actor));
  }
  read(actor: number, id: string) {
    return this.within(actor, id, 'read', 'read', (team) => ({
      ...this.summary(team, actor),
      documents: Object.values(team.documents),
      answers: team.answers,
    }));
  }
  async invite(actor: number, id: string, rawRole: unknown) {
    const access = role(rawRole);
    const code = randomBytes(24).toString('base64url');
    return this.within(actor, id, 'owner', 'invite', async (team, tx) => {
      const now = Date.now();
      await tx
        .createQueryBuilder()
        .delete()
        .from(TeamInvite)
        .where('"teamId" = :id AND ("expiresAt" < :now OR consumed = true)', {
          id,
          now,
        })
        .execute();
      if ((await tx.count(TeamInvite, { where: { teamId: id } })) >= 10)
        throw new BadRequestException('待使用邀请已达上限');
      const invitation = await tx.save(
        TeamInvite,
        tx.create(TeamInvite, {
          teamId: id,
          role: access,
          codeHash: createHash('sha256').update(code).digest('hex'),
          expiresAt: now + 86400000,
          consumed: false,
        }),
      );
      return {
        id: invitation.id,
        code,
        expiresAt: invitation.expiresAt,
        role: access,
      };
    });
  }
  async join(actor: number, rawCode: unknown) {
    const code = text(rawCode, 64, '邀请码');
    const codeHash = createHash('sha256').update(code).digest('hex');
    const invitation = await this.data
      .getRepository(TeamInvite)
      .findOne({ where: { codeHash } });
    if (!invitation) throw new BadRequestException('邀请无效或已过期');
    return this.withinJoin(actor, invitation.teamId, invitation.id, codeHash);
  }
  private withinJoin(
    actor: number,
    id: string,
    inviteId: string,
    codeHash: string,
  ) {
    return this.data.transaction(async (tx) => {
      const team = await tx.findOne(TeamWorkspace, {
        where: { id },
        lock: { mode: 'pessimistic_write' },
      });
      const invitation = await tx.findOne(TeamInvite, {
        where: { id: inviteId, teamId: id, codeHash },
        lock: { mode: 'pessimistic_write' },
      });
      if (
        !team ||
        !invitation ||
        invitation.consumed ||
        Number(invitation.expiresAt) <= Date.now()
      )
        throw new BadRequestException('邀请无效或已过期');
      if (team.members[String(actor)])
        throw new ConflictException('你已是团队成员');
      if (Object.keys(team.members).length >= 50)
        throw new BadRequestException('团队最多50人');
      team.members[String(actor)] = invitation.role;
      team.revision++;
      team.audit = [
        ...team.audit,
        { at: Date.now(), actor, action: 'join', target: id },
      ].slice(-200);
      invitation.consumed = true;
      await tx.save(invitation);
      await tx.save(team);
      return this.summary(team, actor);
    });
  }
  cancelInvite(actor: number, id: string, inviteId: string) {
    uuid(inviteId);
    return this.within(actor, id, 'owner', 'cancel_invite', async (_, tx) => {
      await tx.delete(TeamInvite, { id: inviteId, teamId: id });
      return { cancelled: true };
    });
  }
  member(actor: number, id: string, target: number, rawRole: unknown) {
    if (!Number.isSafeInteger(target) || target <= 0)
      throw new BadRequestException('成员无效');
    const access = rawRole === null ? null : role(rawRole);
    return this.within(actor, id, 'owner', 'member_update', (team) => {
      if (target === team.ownerId)
        throw new BadRequestException('不能移除或降级所有者');
      if (!team.members[String(target)])
        throw new NotFoundException('成员不存在');
      if (access === null) delete team.members[String(target)];
      else team.members[String(target)] = access;
      team.revision++;
      return this.summary(team, actor);
    });
  }
  putDocument(
    actor: number,
    id: string,
    uid: string,
    raw: Record<string, unknown>,
  ) {
    uuid(uid);
    const title = text(raw.title, 100, '文档标题');
    const pages = raw.pages;
    if (
      !Array.isArray(pages) ||
      !pages.length ||
      pages.length > 20 ||
      pages.some((p) => typeof p !== 'string') ||
      pages.join('').length > 30000 ||
      !pages.join('').trim()
    )
      throw new BadRequestException('文档须为1至20页、合计最多3万字');
    if (
      !Number.isSafeInteger(raw.expectedRevision) ||
      Number(raw.expectedRevision) < 0 ||
      typeof raw.archived !== 'boolean'
    )
      throw new BadRequestException('修订参数无效');
    return this.within(actor, id, 'editor', 'document_write', (team) => {
      const old = team.documents[uid];
      if ((old?.revision ?? 0) !== raw.expectedRevision)
        throw new ConflictException('文档版本已变化，请刷新比较后重试');
      if (!old && Object.keys(team.documents).length >= 100)
        throw new BadRequestException('团队最多100篇文档');
      const chunks: TeamDocument['chunks'] = [];
      (pages as string[]).forEach((page, i) => {
        for (let start = 0; start < page.length; start += 600)
          chunks.push({
            seq: chunks.length,
            pageNumber: i + 1,
            content: page.slice(start, start + 600),
          });
      });
      const document: TeamDocument = {
        uid,
        title,
        revision: (old?.revision ?? 0) + 1,
        archived: raw.archived as boolean,
        createdAt: old?.createdAt ?? Date.now(),
        updatedAt: Date.now(),
        chunks,
      };
      const next = { ...team.documents, [uid]: document };
      if (JSON.stringify(next).length > 600000)
        throw new BadRequestException(
          '团队资料总量超过预算，请归档整理后删除旧资料',
        );
      team.documents = next;
      team.revision++;
      return document;
    });
  }
  removeDocument(actor: number, id: string, uid: string, expected: number) {
    uuid(uid);
    return this.within(actor, id, 'editor', 'document_delete', (team) => {
      if (!team.documents[uid] || team.documents[uid].revision !== expected)
        throw new ConflictException('文档已删除或版本已变化');
      delete team.documents[uid];
      team.revision++;
      return { deleted: true };
    });
  }
  saveAnswer(actor: number, id: string, answer: Record<string, unknown>) {
    if (JSON.stringify(answer).length > 100000 || answer.status !== 'cited')
      throw new BadRequestException('只保存有有效引文的团队回答');
    return this.within(actor, id, 'read', 'answer_save', (team) => {
      text(answer.question, 1000, '问题');
      text(answer.model, 200, '模型');
      if (
        !Array.isArray(answer.sources) ||
        !answer.sources.length ||
        answer.sources.length > 6 ||
        !Array.isArray(answer.claims) ||
        !answer.claims.length ||
        answer.claims.length > 12
      )
        throw new BadRequestException('回答引用结构无效');
      const sources = new Map<string, Record<string, unknown>>();
      for (const raw of answer.sources as Record<string, unknown>[]) {
        const doc = team.documents[String(raw.uid)];
        const chunk = doc?.chunks.find((c) => c.seq === raw.seq);
        if (
          !doc ||
          doc.archived ||
          doc.revision !== raw.revision ||
          !chunk ||
          chunk.content !== raw.content ||
          raw.title !== doc.title ||
          raw.importedAt !== doc.createdAt ||
          raw.pageNumber !== chunk.pageNumber ||
          raw.sourceAsset !== ''
        )
          throw new ConflictException('引用资料已变化或失效，请重新提问');
        sources.set(JSON.stringify(raw), raw);
      }
      for (const claim of answer.claims as Record<string, unknown>[]) {
        text(claim.text, 4000, '结论');
        if (
          !Array.isArray(claim.evidence) ||
          !claim.evidence.length ||
          claim.evidence.length > 6
        )
          throw new BadRequestException('结论缺少引文');
        for (const evidence of claim.evidence as Record<string, unknown>[]) {
          const source = sources.get(JSON.stringify(evidence.source));
          const quote = text(evidence.quote, 1500, '引文');
          if (
            !source ||
            quote.length < 4 ||
            !String(source.content).includes(quote)
          )
            throw new BadRequestException('引文与团队原文不符');
        }
      }
      const saved = {
        ...answer,
        id: randomUUID(),
        authorId: actor,
        createdAt: Date.now(),
      };
      team.answers = [saved, ...team.answers].slice(0, 100);
      return saved;
    });
  }
  audit(actor: number, id: string) {
    return this.within(actor, id, 'owner', 'audit_read', (team) => team.audit);
  }
}
