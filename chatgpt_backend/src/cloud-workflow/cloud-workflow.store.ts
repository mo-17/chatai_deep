import {
  Injectable,
  ConflictException,
  NotFoundException,
  ForbiddenException,
} from '@nestjs/common';
import { DataSource, EntityManager } from 'typeorm';
import { randomUUID } from 'node:crypto';
import {
  requireSchedulerAdmission,
  type CloudSchedulerContext,
} from './cloud-workflow.scheduler-gate';
import {
  canonical,
  CLOUD_LIMITS,
  CLOUD_ROLES,
  CloudAuthorization,
  CloudOperation,
  CloudPayload,
  hashText,
  object,
} from './cloud-workflow.contract';

export interface CloudParent {
  id: string;
  owner_id: number;
  payload: CloudPayload | null;
  payload_hash: string;
  state: string;
  revision: number;
  security_version: number;
  grant_version: number;
  grant_expires_at: Date;
  deadline_at: Date;
  fence: string;
  lease_owner: string | null;
  lease_expires_at: Date | null;
  attempts_used: number;
  estimated_tokens: number;
  max_attempts: number;
  token_limit: number;
  output_tokens: number;
  publication_id: string;
  reason: string | null;
  usage_unknown: boolean;
  created_at: Date;
}
export interface CloudFence {
  parentId: string;
  ownerId: number;
  leaseOwner: string;
  fence: string;
}
type CloudControlReceipt = Pick<
  CloudParent,
  | 'id'
  | 'owner_id'
  | 'state'
  | 'revision'
  | 'grant_version'
  | 'fence'
  | 'attempts_used'
  | 'estimated_tokens'
>;
const activeStates = [
  'queued',
  'running',
  'paused',
  'needs_configuration',
  'budget_exhausted',
  'cancelling',
];
const stale = () => new ConflictException('任务版本、授权或执行租约已变化');

/** PG 是唯一事实源；每个方法仅持短事务，不能从回调等待网络。 */
@Injectable()
export class CloudWorkflowStore {
  constructor(protected readonly db: DataSource) {}
  protected async locked<T>(
    action: (tx: EntityManager) => Promise<T>,
  ): Promise<T> {
    return this.db.transaction(async (tx) => {
      // 实际 SQL 等待有界；取消 Promise 不能终止 PostgreSQL 正在执行的语句。
      await tx.query("SET LOCAL statement_timeout='3000ms'");
      await tx.query("SET LOCAL lock_timeout='2000ms'");
      // 首期单执行槽；统一次序同时保护队列/owner限额和控制操作。
      await tx.query('SELECT pg_advisory_xact_lock(178404,1)');
      return action(tx);
    });
  }
  protected async owned(
    tx: EntityManager,
    owner: number,
    id: string,
  ): Promise<CloudParent> {
    const [p] = await tx.query<CloudParent[]>(
      'SELECT * FROM cloud_workflow_parents WHERE owner_id=$1 AND id=$2 FOR UPDATE',
      [owner, id],
    );
    if (!p) throw new NotFoundException('任务不存在');
    return p;
  }
  protected async auth(
    tx: EntityManager,
    a: CloudAuthorization,
    clock: () => number,
  ) {
    const [user] = await tx.query<
      Array<{ tokenVersion: number; banned: boolean }>
    >('SELECT "tokenVersion",banned FROM users WHERE id=$1 FOR SHARE', [
      a.userId,
    ]);
    const now = clock(); // users 行锁等待完毕后采样；入口时间不是授权依据。
    if (
      !user ||
      user.banned ||
      user.tokenVersion !== a.securityVersion ||
      a.expiresAt <= now
    )
      throw new ForbiddenException('登录授权已变化或过期');
    return now;
  }
  protected async grant(
    tx: EntityManager,
    p: CloudParent,
    clock: () => number,
  ) {
    const now = await this.auth(
      tx,
      {
        userId: p.owner_id,
        securityVersion: p.security_version,
        expiresAt: p.grant_expires_at.getTime(),
      },
      clock,
    );
    if (p.deadline_at.getTime() <= now) throw stale();
    return now;
  }
  // 所有相关行锁/配置检查完成后再次调用；仅测试注入动态clock，HTTP从不提供时钟。
  protected liveTime(
    p: CloudParent,
    clock: () => number,
    lease = true,
  ): number {
    const now = clock();
    if (
      p.grant_expires_at.getTime() <= now ||
      p.deadline_at.getTime() <= now ||
      (lease && (!p.lease_expires_at || p.lease_expires_at.getTime() <= now))
    )
      throw stale();
    return now;
  }
  protected async event(tx: EntityManager, p: CloudParent, code: string) {
    await tx.query(
      'INSERT INTO cloud_workflow_events(parent_id,owner_id,code,revision) VALUES($1,$2,$3,$4)',
      [p.id, p.owner_id, code, p.revision],
    );
  }
  protected async profileHash(
    tx: EntityManager,
    providerId: number,
    modelRowId: number,
  ): Promise<string> {
    const [r] = await tx.query<
      Array<{
        baseUrl: string;
        apiKey: string;
        modelId: string;
        enabled: boolean;
        providerEnabled: boolean;
      }>
    >(
      `SELECT p."baseUrl",p."apiKey",m."modelId",m.enabled,p.enabled AS "providerEnabled"
       FROM ai_models m JOIN ai_providers p ON p.id=m."providerId" WHERE m.id=$1 AND p.id=$2 FOR SHARE OF p,m`,
      [modelRowId, providerId],
    );
    if (
      !r ||
      !r.enabled ||
      !r.providerEnabled ||
      !r.apiKey?.trim() ||
      !r.baseUrl?.trim()
    )
      throw new ConflictException('指定服务端模型不可用');
    // 仅保存不可逆指纹；端点、密钥和客户端对象均不进入任务记录。
    return hashText(
      canonical({
        providerId,
        modelRowId,
        modelId: r.modelId,
        endpoint: r.baseUrl,
        keyHash: hashText(r.apiKey),
      }),
    );
  }
  async create(
    a: CloudAuthorization,
    payload: CloudPayload,
    clock: () => number = Date.now,
    scheduler?: CloudSchedulerContext,
  ): Promise<CloudParent> {
    return this.locked(async (tx) => {
      await this.auth(tx, a, clock);
      const payloadHash = hashText(canonical(payload));
      const [old] = await tx.query<CloudParent[]>(
        'SELECT * FROM cloud_workflow_parents WHERE owner_id=$1 AND idempotency_key=$2 FOR UPDATE',
        [a.userId, payload.idempotencyKey],
      );
      if (old) {
        if (old.payload_hash !== payloadHash)
          throw new ConflictException('相同幂等键不能提交不同内容');
        await this.auth(tx, a, clock);
        return old; // deleted tombstone 也返回原身份，不能复活。
      }
      await requireSchedulerAdmission(tx, scheduler);
      const [{ count: active }] = await tx.query<Array<{ count: number }>>(
        'SELECT count(*)::int AS count FROM cloud_workflow_parents WHERE owner_id=$1 AND state=ANY($2::text[])',
        [a.userId, activeStates],
      );
      if (active) throw new ConflictException('当前账号已有活动云任务');
      const [{ count: queued }] = await tx.query<Array<{ count: number }>>(
        "SELECT count(*)::int AS count FROM cloud_workflow_parents WHERE state='queued'",
      );
      if (queued >= CLOUD_LIMITS.queued)
        throw new ConflictException('云任务队列已满，请稍后明确重试');
      const profiles = [] as string[];
      for (const role of CLOUD_ROLES) {
        const ref = payload.profiles[role];
        profiles.push(
          await this.profileHash(tx, ref.providerId, ref.modelRowId),
        );
      }
      const now = await this.auth(tx, a, clock);
      const deadline = now + payload.budget.durationMs;
      const grantEnd = Math.min(
        a.expiresAt,
        deadline,
        now + payload.grantDurationMs,
        now + CLOUD_LIMITS.durationMs,
      );
      const id = randomUUID();
      const [p] = await tx.query<CloudParent[]>(
        `INSERT INTO cloud_workflow_parents
        (id,owner_id,idempotency_key,payload_hash,payload,client_instance_id,security_version,grant_expires_at,deadline_at,max_attempts,token_limit,output_tokens,publication_id)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING *`,
        [
          id,
          a.userId,
          payload.idempotencyKey,
          payloadHash,
          payload,
          payload.clientInstanceId,
          a.securityVersion,
          new Date(grantEnd),
          new Date(deadline),
          payload.budget.attempts,
          payload.budget.estimatedTokens,
          payload.budget.outputTokens,
          randomUUID(),
        ],
      );
      for (let ordinal = 0; ordinal < CLOUD_ROLES.length; ordinal++) {
        const role = CLOUD_ROLES[ordinal],
          ref = payload.profiles[role];
        await tx.query(
          'INSERT INTO cloud_workflow_steps(id,parent_id,owner_id,role,ordinal,provider_id,model_row_id,profile_hash) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
          [
            randomUUID(),
            id,
            a.userId,
            role,
            ordinal,
            ref.providerId,
            ref.modelRowId,
            profiles[ordinal],
          ],
        );
      }
      await this.event(tx, p, 'created');
      return p;
    });
  }
  async detail(owner: number, id: string) {
    const rows = await this.db.query<CloudParent[]>(
      'SELECT * FROM cloud_workflow_parents WHERE owner_id=$1 AND id=$2',
      [owner, id],
    );
    if (!rows.length) throw new NotFoundException('任务不存在');
    const steps = await this.db.query<
      Array<{
        id: string;
        role: string;
        ordinal: number;
        state: string;
        revision: number;
        result_version: number;
      }>
    >(
      'SELECT id,role,ordinal,state,revision,result_version FROM cloud_workflow_steps WHERE owner_id=$1 AND parent_id=$2 ORDER BY ordinal',
      [owner, id],
    );
    return { parent: rows[0], steps };
  }
  /** 专用白名单目录；沿用 catalogPublic，绝不读取/返回 key 或 endpoint。 */
  async profiles() {
    const [global] = await this.db.query<Array<{ catalogPublic: boolean }>>(
      'SELECT "catalogPublic" FROM ai_global_config WHERE id=1',
    );
    if (!global?.catalogPublic)
      throw new ForbiddenException('模型清单暂不对外开放');
    return this.db.query<
      Array<{
        providerId: number;
        modelRowId: number;
        modelId: string;
        providerName: string;
        modelName: string;
      }>
    >(`SELECT p.id AS "providerId",m.id AS "modelRowId",m."modelId",
      p."displayName" AS "providerName",m."displayName" AS "modelName"
      FROM ai_models m JOIN ai_providers p ON p.id=m."providerId"
      WHERE p.enabled=true AND m.enabled=true
      ORDER BY p."sortOrder",p.id,m."sortOrder",m.id`);
  }
  /** 提交未知后的纯读恢复。owner始终来自本次JWT，不授予执行许可。 */
  async byIdempotency(owner: number, key: string) {
    const [row] = await this.db.query<
      Array<{
        id: string;
        ownerId: number;
        state: string;
        revision: number;
        payloadHash: string;
        source: CloudPayload['source'] | null;
        publicationId: string;
        finalResultId: string | null;
      }>
    >(
      `SELECT id,owner_id AS "ownerId",state,revision,payload_hash AS "payloadHash",
      payload->'source' AS source,publication_id AS "publicationId",final_result_id AS "finalResultId"
      FROM cloud_workflow_parents WHERE owner_id=$1 AND idempotency_key=$2`,
      [owner, key],
    );
    if (!row) throw new NotFoundException('任务不存在');
    return row;
  }
  async results(owner: number, id: string) {
    await this.detail(owner, id);
    return this.db.query<
      Array<{
        id: string;
        step_id: string;
        version: number;
        content: string;
        content_hash: string;
        publication_id: string;
      }>
    >(
      'SELECT r.id,r.step_id,r.version,r.content,r.content_hash,p.publication_id FROM cloud_workflow_results r JOIN cloud_workflow_parents p ON p.id=r.parent_id AND p.owner_id=r.owner_id WHERE r.owner_id=$1 AND r.parent_id=$2 ORDER BY r.created_at,r.id',
      [owner, id],
    );
  }
  async list(owner: number, cursor: string | null, limit: number) {
    // UUID 游标只允许当前 owner 的行作为锚点，跨 owner 游标统一404。
    if (
      cursor &&
      !(
        await this.db.query<Array<{ id: string }>>(
          'SELECT id FROM cloud_workflow_parents WHERE owner_id=$1 AND id=$2',
          [owner, cursor],
        )
      ).length
    )
      throw new NotFoundException('任务不存在');
    return this.db.query<CloudParent[]>(
      `SELECT * FROM cloud_workflow_parents WHERE owner_id=$1
      AND ($2::uuid IS NULL OR (created_at,id)<(SELECT created_at,id FROM cloud_workflow_parents WHERE owner_id=$1 AND id=$2))
      ORDER BY created_at DESC,id DESC LIMIT $3`,
      [owner, cursor, limit],
    );
  }
  private async operation(
    tx: EntityManager,
    owner: number,
    id: string,
    kind: string,
    body: unknown,
  ) {
    const hash = hashText(canonical(body));
    const [old] = await tx.query<
      Array<{
        parent_id: string;
        kind: string;
        request_hash: string;
        response: CloudControlReceipt;
      }>
    >(
      'SELECT * FROM cloud_workflow_operations WHERE owner_id=$1 AND operation_id=$2',
      [owner, (body as CloudOperation).operationId],
    );
    if (
      old &&
      (old.parent_id !== id || old.kind !== kind || old.request_hash !== hash)
    )
      throw new ConflictException('操作幂等键已用于另一操作');
    return { hash, old: old?.response };
  }
  private async record(
    tx: EntityManager,
    p: CloudParent,
    kind: string,
    op: CloudOperation,
    hash: string,
  ) {
    // 操作回执仅记录无正文的控制身份，不保留删除前 payload。
    const response: CloudControlReceipt = {
      id: p.id,
      owner_id: p.owner_id,
      state: p.state,
      revision: p.revision,
      grant_version: p.grant_version,
      fence: p.fence,
      attempts_used: p.attempts_used,
      estimated_tokens: p.estimated_tokens,
    };
    await tx.query(
      'INSERT INTO cloud_workflow_operations(owner_id,operation_id,parent_id,kind,request_hash,response) VALUES($1,$2,$3,$4,$5,$6)',
      [p.owner_id, op.operationId, p.id, kind, hash, response],
    );
    return response;
  }
  async control(
    a: CloudAuthorization,
    id: string,
    kind: 'stop' | 'delete' | 'continue',
    op: CloudOperation,
    grantDurationMs?: number,
    clock: () => number = Date.now,
    scheduler?: CloudSchedulerContext,
  ) {
    return this.locked(async (tx) => {
      const p = await this.owned(tx, a.userId, id);
      if (kind === 'continue') {
        await this.auth(tx, a, clock);
        if (
          !Number.isSafeInteger(grantDurationMs) ||
          grantDurationMs! < 1 ||
          grantDurationMs! > CLOUD_LIMITS.durationMs
        )
          throw stale();
      }
      const body = {
        ...op,
        ...(kind === 'continue' ? { grantDurationMs } : {}),
      };
      const receipt = await this.operation(tx, a.userId, id, kind, body);
      if (receipt.old) return receipt.old;
      if (p.revision !== op.expectedRevision) throw stale();
      if (
        kind === 'stop' &&
        ['complete', 'cancelled', 'failed', 'deleted'].includes(p.state)
      ) {
        return this.record(tx, p, kind, op, receipt.hash);
      }
      if (kind === 'continue') {
        await requireSchedulerAdmission(tx, scheduler);
        if (p.reason === 'rework_limit_reached')
          throw new ConflictException('本次返工额度已耗尽，不能通过继续重置');
        if (
          ![
            'paused',
            'needs_configuration',
            'budget_exhausted',
            'failed',
          ].includes(p.state) ||
          p.deadline_at.getTime() <= clock() ||
          p.attempts_used >= p.max_attempts ||
          p.estimated_tokens >= p.token_limit
        )
          throw stale();
        if (
          (
            await tx.query<Array<{ id: string }>>(
              "SELECT id FROM cloud_workflow_attempts WHERE parent_id=$1 AND owner_id=$2 AND state IN ('unknown','dispatched')",
              [id, a.userId],
            )
          ).length
        )
          throw new ConflictException('结果未知，不能自动重放');
        const [{ count }] = await tx.query<Array<{ count: number }>>(
          "SELECT count(*)::int AS count FROM cloud_workflow_parents WHERE state='queued'",
        );
        if (count >= CLOUD_LIMITS.queued)
          throw new ConflictException('云任务队列已满');
        for (const role of CLOUD_ROLES) {
          const profile = p.payload!.profiles[role];
          const h = await this.profileHash(
            tx,
            profile.providerId,
            profile.modelRowId,
          );
          await tx.query(
            'UPDATE cloud_workflow_steps SET profile_hash=$1 WHERE owner_id=$2 AND parent_id=$3 AND role=$4',
            [h, a.userId, id, role],
          );
        }
        await tx.query(
          "UPDATE cloud_workflow_steps SET state='queued',revision=revision+1 WHERE owner_id=$1 AND parent_id=$2 AND state='failed'",
          [a.userId, id],
        );
        const now = await this.auth(tx, a, clock);
        if (p.deadline_at.getTime() <= now) throw stale();
        await tx.query(
          `UPDATE cloud_workflow_parents SET state='queued',reason=NULL,security_version=$1,grant_version=grant_version+1,grant_expires_at=$2,fence=fence+1,lease_owner=NULL,lease_expires_at=NULL,revision=revision+1,updated_at=now() WHERE owner_id=$3 AND id=$4`,
          [
            a.securityVersion,
            new Date(
              Math.min(
                a.expiresAt,
                p.deadline_at.getTime(),
                now + grantDurationMs!,
                now + CLOUD_LIMITS.durationMs,
              ),
            ),
            a.userId,
            id,
          ],
        );
      } else {
        const [{ count }] = await tx.query<Array<{ count: number }>>(
          "SELECT count(*)::int AS count FROM cloud_workflow_attempts WHERE owner_id=$1 AND parent_id=$2 AND state='dispatched'",
          [a.userId, id],
        );
        const state =
          kind === 'delete' || p.state === 'deleted'
            ? 'deleted'
            : count
              ? 'cancelling'
              : 'cancelled';
        await tx.query(
          "UPDATE cloud_workflow_parents SET state=$1,grant_version=grant_version+1,grant_expires_at=$2,fence=fence+1,revision=revision+1,updated_at=now(),payload=CASE WHEN $1='deleted' THEN NULL ELSE payload END WHERE owner_id=$3 AND id=$4",
          [state, new Date(clock()), a.userId, id],
        );
        if (kind === 'delete') {
          await tx.query(
            'DELETE FROM cloud_workflow_results WHERE owner_id=$1 AND parent_id=$2',
            [a.userId, id],
          );
          await tx.query(
            'UPDATE cloud_workflow_steps SET checkpoint=NULL WHERE owner_id=$1 AND parent_id=$2',
            [a.userId, id],
          );
        }
      }
      const result = await this.owned(tx, a.userId, id);
      await this.event(tx, result, kind);
      return this.record(tx, result, kind, op, receipt.hash);
    });
  }
  async revokeClient(
    a: CloudAuthorization,
    clientId: string,
    operationId: string,
    clock: () => number = Date.now,
  ) {
    return this.locked(async (tx) => {
      const requestHash = hashText(canonical({ clientId }));
      const [old] = await tx.query<
        Array<{ request_hash: string; response: unknown[] }>
      >(
        'SELECT request_hash,response FROM cloud_workflow_client_operations WHERE owner_id=$1 AND operation_id=$2',
        [a.userId, operationId],
      );
      if (old) {
        if (old.request_hash !== requestHash)
          throw new ConflictException('批量撤销幂等键已用于另一客户端');
        return old.response;
      }
      const parents = await tx.query<CloudParent[]>(
        'SELECT * FROM cloud_workflow_parents WHERE owner_id=$1 AND client_instance_id=$2 AND state=ANY($3::text[]) FOR UPDATE',
        [a.userId, clientId, activeStates],
      );
      const out: Array<{ id: string; revision: number; state: string }> = [];
      for (const p of parents) {
        const [{ count }] = await tx.query<Array<{ count: number }>>(
          "SELECT count(*)::int AS count FROM cloud_workflow_attempts WHERE owner_id=$1 AND parent_id=$2 AND state='dispatched'",
          [a.userId, p.id],
        );
        await tx.query(
          'UPDATE cloud_workflow_parents SET state=$1,grant_version=grant_version+1,grant_expires_at=$2,fence=fence+1,revision=revision+1,updated_at=now() WHERE owner_id=$3 AND id=$4',
          [
            count ? 'cancelling' : 'cancelled',
            new Date(clock()),
            a.userId,
            p.id,
          ],
        );
        const live = await this.owned(tx, a.userId, p.id);
        await this.event(tx, live, 'client_revoked');
        out.push({ id: p.id, revision: live.revision, state: live.state });
      }
      await tx.query(
        'INSERT INTO cloud_workflow_client_operations(owner_id,operation_id,request_hash,response) VALUES($1,$2,$3,$4)',
        [a.userId, operationId, requestHash, JSON.stringify(out)],
      );
      return out;
    });
  }
  private async reap(tx: EntityManager, clock: () => number) {
    const [slot] = await tx.query<
      Array<{ parent_id: string | null; expires_at: Date | null }>
    >('SELECT * FROM cloud_workflow_slot WHERE id=1 FOR UPDATE');
    if (
      !slot.parent_id ||
      !slot.expires_at ||
      slot.expires_at.getTime() > clock()
    )
      return;
    const [p] = await tx.query<CloudParent[]>(
      'SELECT * FROM cloud_workflow_parents WHERE id=$1 FOR UPDATE',
      [slot.parent_id],
    );
    if (p) {
      const now = clock();
      const attempts = await tx.query<Array<{ step_id: string }>>(
        "WITH changed AS (UPDATE cloud_workflow_attempts SET state='unknown',finished_at=$1 WHERE parent_id=$2 AND owner_id=$3 AND state='dispatched' RETURNING step_id) SELECT * FROM changed",
        [new Date(now), p.id, p.owner_id],
      );
      for (const attempt of attempts)
        await tx.query(
          "UPDATE cloud_workflow_steps SET state='unknown',revision=revision+1 WHERE id=$1 AND parent_id=$2 AND owner_id=$3",
          [attempt.step_id, p.id, p.owner_id],
        );
      const state = ['deleted', 'cancelled', 'complete', 'failed'].includes(
        p.state,
      )
        ? p.state
        : p.state === 'cancelling'
          ? 'cancelled'
          : attempts.length
            ? 'paused'
            : 'queued';
      await tx.query(
        'UPDATE cloud_workflow_parents SET state=$1,reason=$2,usage_unknown=usage_unknown OR $3,fence=fence+1,revision=revision+1,lease_owner=NULL,lease_expires_at=NULL,updated_at=now() WHERE owner_id=$4 AND id=$5',
        [
          state,
          attempts.length ? 'result_unknown' : 'lease_expired_before_dispatch',
          !!attempts.length,
          p.owner_id,
          p.id,
        ],
      );
      await this.event(
        tx,
        await this.owned(tx, p.owner_id, p.id),
        'lease_expired',
      );
    }
    await tx.query(
      'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL WHERE id=1',
    );
  }
  async claim(
    workerId: string,
    clock: () => number = Date.now,
  ): Promise<CloudFence | null> {
    return this.locked(async (tx) => {
      await this.reap(tx, clock);
      const [slot] = await tx.query<Array<{ parent_id: string | null }>>(
        'SELECT parent_id FROM cloud_workflow_slot WHERE id=1',
      );
      if (slot.parent_id) return null;
      const [p] = await tx.query<CloudParent[]>(
        "SELECT * FROM cloud_workflow_parents WHERE state='queued' ORDER BY created_at,id LIMIT 1 FOR UPDATE",
      );
      if (!p) return null;
      let now: number;
      try {
        now = await this.grant(tx, p, clock);
      } catch (error) {
        if (
          !(
            error instanceof ForbiddenException ||
            error instanceof ConflictException
          )
        )
          throw error;
        await tx.query(
          "UPDATE cloud_workflow_parents SET state='paused',reason='authorization_expired',revision=revision+1 WHERE id=$1 AND owner_id=$2",
          [p.id, p.owner_id],
        );
        await this.event(
          tx,
          await this.owned(tx, p.owner_id, p.id),
          'authorization_expired',
        );
        return null;
      }
      const end = new Date(
        Math.min(
          now + 30000,
          p.grant_expires_at.getTime(),
          p.deadline_at.getTime(),
        ),
      );
      const [live] = await tx.query<CloudParent[]>(
        "WITH changed AS (UPDATE cloud_workflow_parents SET state='running',lease_owner=$1,lease_expires_at=$2,fence=fence+1,revision=revision+1,updated_at=now() WHERE id=$3 AND owner_id=$4 RETURNING *) SELECT * FROM changed",
        [workerId, end, p.id, p.owner_id],
      );
      await tx.query(
        'UPDATE cloud_workflow_slot SET parent_id=$1,lease_owner=$2,fence=$3,expires_at=$4 WHERE id=1',
        [p.id, workerId, live.fence, end],
      );
      await this.event(tx, live, 'claimed');
      return {
        parentId: p.id,
        ownerId: p.owner_id,
        leaseOwner: workerId,
        fence: live.fence,
      };
    });
  }
  protected async fenced(
    tx: EntityManager,
    f: CloudFence,
    clock: () => number,
  ) {
    const p = await this.owned(tx, f.ownerId, f.parentId);
    const [slot] = await tx.query<
      Array<{
        parent_id: string | null;
        lease_owner: string | null;
        fence: string | null;
        expires_at: Date | null;
      }>
    >(
      'SELECT parent_id,lease_owner,fence,expires_at FROM cloud_workflow_slot WHERE id=1 FOR UPDATE',
    );
    if (
      p.state !== 'running' ||
      p.lease_owner !== f.leaseOwner ||
      p.fence !== f.fence ||
      slot.parent_id !== f.parentId ||
      slot.lease_owner !== f.leaseOwner ||
      slot.fence !== f.fence ||
      !slot.expires_at ||
      slot.expires_at.getTime() <= clock() ||
      !p.lease_expires_at ||
      p.lease_expires_at.getTime() <= clock()
    )
      throw stale();
    // 父和全局槽的截止都有效；之后等待profile/step时仍按两者最早截止复核。
    p.lease_expires_at = new Date(
      Math.min(p.lease_expires_at.getTime(), slot.expires_at.getTime()),
    );
    await this.grant(tx, p, clock);
    const executing = await tx.query<
      Array<{ provider_id: number; model_row_id: number; profile_hash: string }>
    >(
      "SELECT provider_id,model_row_id,profile_hash FROM cloud_workflow_steps WHERE owner_id=$1 AND parent_id=$2 AND state='running'",
      [f.ownerId, f.parentId],
    );
    for (const step of executing) {
      if (
        (await this.profileHash(tx, step.provider_id, step.model_row_id)) !==
        step.profile_hash
      )
        throw new ConflictException('原服务端模型配置已变化，需要明确重新授权');
    }
    this.liveTime(p, clock);
    return p;
  }
  async renew(f: CloudFence, clock: () => number = Date.now) {
    return this.locked(async (tx) => {
      const p = await this.fenced(tx, f, clock),
        now = this.liveTime(p, clock),
        end = new Date(
          Math.min(
            now + 30000,
            p.deadline_at.getTime(),
            p.grant_expires_at.getTime(),
          ),
        );
      await tx.query(
        'UPDATE cloud_workflow_parents SET lease_expires_at=$1 WHERE owner_id=$2 AND id=$3',
        [end, f.ownerId, f.parentId],
      );
      await tx.query(
        'UPDATE cloud_workflow_slot SET expires_at=$1 WHERE id=1 AND parent_id=$2 AND lease_owner=$3 AND fence=$4',
        [end, f.parentId, f.leaseOwner, f.fence],
      );
      return end;
    });
  }
  async reserveDispatch(
    f: CloudFence,
    stepId: string,
    inputEstimate: number,
    clock: () => number = Date.now,
  ) {
    if (
      !Number.isSafeInteger(inputEstimate) ||
      inputEstimate < 1 ||
      inputEstimate > CLOUD_LIMITS.estimatedTokens
    )
      throw stale();
    return this.locked(async (tx) => {
      const p = await this.fenced(tx, f, clock);
      const [step] = await tx.query<
        Array<{
          id: string;
          ordinal: number;
          state: string;
          provider_id: number;
          model_row_id: number;
          profile_hash: string;
        }>
      >(
        'SELECT * FROM cloud_workflow_steps WHERE owner_id=$1 AND parent_id=$2 AND id=$3 FOR UPDATE',
        [f.ownerId, f.parentId, stepId],
      );
      if (
        !step ||
        step.state !== 'queued' ||
        (
          await tx.query<Array<{ id: string }>>(
            "SELECT id FROM cloud_workflow_steps WHERE parent_id=$1 AND owner_id=$2 AND ordinal<$3 AND state<>'complete'",
            [f.parentId, f.ownerId, step.ordinal],
          )
        ).length
      )
        throw stale();
      if (
        (await this.profileHash(tx, step.provider_id, step.model_row_id)) !==
        step.profile_hash
      )
        throw new ConflictException('原服务端模型配置已变化，需要明确重新授权');
      const tokens = inputEstimate + p.output_tokens;
      if (
        p.attempts_used >= p.max_attempts ||
        p.estimated_tokens + tokens > p.token_limit
      )
        throw new ConflictException('云任务预算已用尽');
      this.liveTime(p, clock); // profile/step/user锁等待后、不可逆发送意图INSERT前。
      const attemptId = randomUUID();
      await tx.query(
        "INSERT INTO cloud_workflow_attempts(id,parent_id,step_id,owner_id,fence,number,state,estimated_tokens) VALUES($1,$2,$3,$4,$5,$6,'dispatched',$7)",
        [
          attemptId,
          f.parentId,
          stepId,
          f.ownerId,
          f.fence,
          p.attempts_used + 1,
          tokens,
        ],
      );
      await tx.query(
        "UPDATE cloud_workflow_steps SET state='running',revision=revision+1 WHERE id=$1 AND parent_id=$2 AND owner_id=$3",
        [stepId, f.parentId, f.ownerId],
      );
      await tx.query(
        'UPDATE cloud_workflow_parents SET attempts_used=attempts_used+1,estimated_tokens=estimated_tokens+$1,revision=revision+1,updated_at=now() WHERE id=$2 AND owner_id=$3',
        [tokens, f.parentId, f.ownerId],
      );
      await this.event(
        tx,
        await this.owned(tx, f.ownerId, f.parentId),
        'dispatch_reserved',
      );
      return attemptId;
    });
  }
  async finish(
    f: CloudFence,
    attemptId: string,
    content: string,
    usage: { input: number; output: number } | null,
    clock: () => number = Date.now,
  ) {
    if (
      typeof content !== 'string' ||
      !content.trim() ||
      Buffer.byteLength(content) > CLOUD_LIMITS.resultBytes ||
      [...content].length > 12000
    )
      throw stale();
    if (
      usage &&
      ![usage.input, usage.output].every(
        (v) => Number.isSafeInteger(v) && v >= 0 && v <= 1000000,
      )
    )
      throw stale();
    return this.locked(async (tx) => {
      const prior = await this.owned(tx, f.ownerId, f.parentId);
      const [a] = await tx.query<
        Array<{ step_id: string; state: string; fence: string }>
      >(
        'SELECT * FROM cloud_workflow_attempts WHERE owner_id=$1 AND parent_id=$2 AND id=$3 FOR UPDATE',
        [f.ownerId, f.parentId, attemptId],
      );
      if (!a || a.fence !== f.fence) throw stale();
      const [old] = await tx.query<
        Array<{
          content_hash: string;
          input_tokens: number | null;
          output_tokens: number | null;
        }>
      >(
        'SELECT r.content_hash,a.input_tokens,a.output_tokens FROM cloud_workflow_results r JOIN cloud_workflow_attempts a ON a.id=r.attempt_id AND a.owner_id=r.owner_id AND a.parent_id=r.parent_id WHERE r.owner_id=$1 AND r.parent_id=$2 AND r.attempt_id=$3',
        [f.ownerId, f.parentId, attemptId],
      );
      if (old) {
        if (
          prior.fence !== f.fence ||
          prior.lease_owner !== f.leaseOwner ||
          !['running', 'complete', 'paused'].includes(prior.state) ||
          old.content_hash !== hashText(content) ||
          old.input_tokens !== (usage?.input ?? null) ||
          old.output_tokens !== (usage?.output ?? null)
        )
          throw stale();
        return prior;
      }
      await this.fenced(tx, f, clock);
      if (a.state !== 'dispatched') throw stale();
      const [step] = await tx.query<
        Array<{ role: string; result_version: number }>
      >(
        'SELECT role,result_version FROM cloud_workflow_steps WHERE owner_id=$1 AND parent_id=$2 AND id=$3 FOR UPDATE',
        [f.ownerId, f.parentId, a.step_id],
      );
      let passed = true;
      if (step.role === 'review') {
        try {
          const decoded: unknown = JSON.parse(content);
          const r = object(decoded, ['passed', 'feedback']);
          passed =
            Object.keys(r).sort().join(',') === 'feedback,passed' &&
            typeof r.passed === 'boolean' &&
            typeof r.feedback === 'string' &&
            Buffer.byteLength(r.feedback) <= 4000 &&
            r.passed === true;
        } catch {
          passed = false;
        }
      }
      const now = this.liveTime(prior, clock);
      await tx.query(
        'INSERT INTO cloud_workflow_results(id,parent_id,owner_id,step_id,attempt_id,version,content,content_hash) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
        [
          randomUUID(),
          f.parentId,
          f.ownerId,
          a.step_id,
          attemptId,
          step.result_version + 1,
          content,
          hashText(content),
        ],
      );
      await tx.query(
        'UPDATE cloud_workflow_attempts SET state=$1,input_tokens=$2,output_tokens=$3,finished_at=$4 WHERE owner_id=$5 AND parent_id=$6 AND id=$7',
        [
          passed ? 'succeeded' : 'failed',
          usage?.input ?? null,
          usage?.output ?? null,
          new Date(now),
          f.ownerId,
          f.parentId,
          attemptId,
        ],
      );
      await tx.query(
        'UPDATE cloud_workflow_steps SET state=$1,result_version=result_version+1,revision=revision+1 WHERE owner_id=$2 AND parent_id=$3 AND id=$4',
        [passed ? 'complete' : 'failed', f.ownerId, f.parentId, a.step_id],
      );
      const [{ count }] = await tx.query<Array<{ count: number }>>(
        "SELECT count(*)::int AS count FROM cloud_workflow_steps WHERE owner_id=$1 AND parent_id=$2 AND state<>'complete'",
        [f.ownerId, f.parentId],
      );
      const state = !passed ? 'paused' : count ? 'running' : 'complete';
      await tx.query(
        'UPDATE cloud_workflow_parents SET state=$1,reason=$2,usage_unknown=usage_unknown OR $3,revision=revision+1,updated_at=now() WHERE owner_id=$4 AND id=$5',
        [
          state,
          passed ? null : 'review_validation_failed',
          usage === null,
          f.ownerId,
          f.parentId,
        ],
      );
      if (state !== 'running')
        await tx.query(
          'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL WHERE id=1 AND parent_id=$1 AND lease_owner=$2 AND fence=$3',
          [f.parentId, f.leaseOwner, f.fence],
        );
      const result = await this.owned(tx, f.ownerId, f.parentId);
      await this.event(
        tx,
        result,
        passed ? 'result_committed' : 'review_rejected',
      );
      return result;
    });
  }
  async settleRevoked(f: CloudFence, clock: () => number = Date.now) {
    return this.locked(async (tx) => {
      const p = await this.owned(tx, f.ownerId, f.parentId);
      if (!['cancelling', 'deleted', 'cancelled'].includes(p.state))
        throw stale();
      const rows = await tx.query<Array<{ id: number }>>(
        'WITH changed AS (UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL WHERE id=1 AND parent_id=$1 AND lease_owner=$2 AND fence=$3 RETURNING id) SELECT * FROM changed',
        [f.parentId, f.leaseOwner, f.fence],
      );
      if (!rows.length) {
        if (
          p.lease_owner === null &&
          ['cancelled', 'deleted'].includes(p.state)
        )
          return p;
        throw stale();
      }
      const unknown = await tx.query<Array<{ id: string; step_id: string }>>(
        "WITH changed AS (UPDATE cloud_workflow_attempts SET state='unknown',finished_at=$1 WHERE owner_id=$2 AND parent_id=$3 AND state='dispatched' RETURNING id,step_id) SELECT * FROM changed",
        [new Date(clock()), f.ownerId, f.parentId],
      );
      for (const attempt of unknown) {
        await tx.query(
          "UPDATE cloud_workflow_steps SET state='unknown',revision=revision+1 WHERE id=$1 AND parent_id=$2 AND owner_id=$3",
          [attempt.step_id, f.parentId, f.ownerId],
        );
      }
      await tx.query(
        "UPDATE cloud_workflow_parents SET state=CASE WHEN state='deleted' THEN state ELSE 'cancelled' END,usage_unknown=usage_unknown OR $3,lease_owner=NULL,lease_expires_at=NULL,revision=revision+1 WHERE owner_id=$1 AND id=$2",
        [f.ownerId, f.parentId, unknown.length > 0],
      );
      const live = await this.owned(tx, f.ownerId, f.parentId);
      await this.event(tx, live, 'revocation_settled');
      return live;
    });
  }
}
