import { Injectable, ConflictException } from '@nestjs/common';
import { DataSource, type EntityManager } from 'typeorm';
import { randomUUID } from 'node:crypto';
import {
  CloudWorkflowStore,
  type CloudFence,
  type CloudParent,
} from './cloud-workflow.store';
import { hashText, parseCloudPayload } from './cloud-workflow.contract';
import {
  schedulerStatusTx,
  schedulerOpenTx,
  schedulerCloseTx,
} from './cloud-workflow.scheduler-store';
import type { CloudAuthUser } from '../auth/token-authentication.service';
import {
  acceptancePassed,
  boundedOutput,
  buildWire,
  equalRefs,
  parseReview,
  type ExecutionPlan,
  type ExecutionResult,
  type ExecutionStep,
  type InputRefs,
  type KnownOutput,
  type SendPermit,
  type WireRequest,
} from './cloud-workflow.execution';

const invalid = () => new ConflictException('cloud_execution_stale');
interface Attempt {
  id: string;
  step_id: string;
  state: string;
  fence: string;
  request_digest: string | null;
  input_refs: InputRefs | null;
  grant_version: number | null;
  send_authorized_at: Date | null;
}
@Injectable()
export class CloudWorkflowExecutionStore extends CloudWorkflowStore {
  private initializing: Promise<DataSource> | null = null;
  private closing = false;
  private closePromise: Promise<void> | null = null;
  constructor(source: DataSource) {
    if (source.options.type !== 'postgres')
      throw Error('cloud_requires_postgres');
    // 只复用已注入的显式数据库参数，惰性专用小池；不读取 dotenv/default datasource。
    // 共享 app pool 没有 acquisition timeout，不能在等连接时悬挂运行租约。
    const o = source.options;
    const extra = o.extra as Record<string, unknown> | undefined;
    const applicationName =
      typeof extra?.application_name === 'string'
        ? extra.application_name
        : 'chatai-cloud-worker';
    super(
      new DataSource({
        type: 'postgres',
        host: o.host,
        port: o.port,
        username: o.username,
        password: o.password,
        database: o.database,
        url: o.url,
        schema: o.schema,
        ssl: o.ssl,
        entities: [],
        migrations: [],
        subscribers: [],
        logging: false,
        synchronize: false,
        migrationsRun: false,
        dropSchema: false,
        cache: false,
        installExtensions: false,
        extra: {
          max: 2,
          connectionTimeoutMillis: 3000,
          statement_timeout: 3000,
          lock_timeout: 2000,
          query_timeout: 5000,
          application_name: applicationName,
        },
      }),
    );
  }
  protected async locked<T>(
    action: (tx: EntityManager) => Promise<T>,
  ): Promise<T> {
    if (this.closing) throw Error('cloud_store_closed');
    // isInitialized 早于 buildMetadatas/afterConnect；已有 promise 必须优先等待。
    if (this.initializing || !this.db.isInitialized) {
      const pending = (this.initializing ??= this.db.initialize());
      try {
        await pending;
      } finally {
        if (this.initializing === pending) this.initializing = null;
      }
    }
    if (this.closing) throw Error('cloud_store_closed');
    return super.locked(action);
  }
  close(): Promise<void> {
    this.closing = true;
    return (this.closePromise ??= (async () => {
      if (this.initializing) await this.initializing.catch(() => {});
      if (this.db.isInitialized) await this.db.destroy();
    })());
  }
  onApplicationShutdown(): Promise<void> {
    return this.close();
  }
  schedulerStatus() {
    return this.locked(schedulerStatusTx);
  }
  schedulerOpen(epoch: string) {
    return this.locked((tx) => schedulerOpenTx(tx, epoch));
  }
  schedulerClose(epoch: string) {
    return this.locked((tx) => schedulerCloseTx(tx, epoch));
  }
  cloudAuthUser(id: number): Promise<CloudAuthUser | null> {
    return this.locked(async (tx) => {
      const [user] = await tx.query<CloudAuthUser[]>(
        'SELECT id,"userName",role,banned,"tokenVersion" FROM users WHERE id=$1',
        [id],
      );
      return user ?? null;
    });
  }
  private async plan(
    tx: EntityManager,
    p: CloudParent,
  ): Promise<ExecutionPlan> {
    const steps = await tx.query<ExecutionStep[]>(
      `SELECT s.*,m."modelId" AS model_id FROM cloud_workflow_steps s
       LEFT JOIN ai_models m ON m.id=s.model_row_id AND m."providerId"=s.provider_id
       WHERE s.parent_id=$1 AND s.owner_id=$2 ORDER BY s.ordinal FOR UPDATE OF s`,
      [p.id, p.owner_id],
    );
    const results = await tx.query<ExecutionResult[]>(
      `SELECT r.id,r.step_id,r.version,r.content,r.content_hash FROM cloud_workflow_results r
       JOIN cloud_workflow_steps s ON s.id=r.step_id AND s.parent_id=r.parent_id AND s.owner_id=r.owner_id AND s.result_version=r.version
       WHERE r.parent_id=$1 AND r.owner_id=$2`,
      [p.id, p.owner_id],
    );
    if (steps.length !== 3) throw invalid();
    return {
      parent: p as ExecutionPlan['parent'],
      payload: parseCloudPayload(p.payload),
      steps,
      results,
    };
  }
  async readPlan(f: CloudFence): Promise<ExecutionPlan> {
    return this.locked(async (tx) => {
      const p = await this.fenced(tx, f, Date.now);
      const plan = await this.plan(tx, p);
      this.liveTime(p, Date.now);
      return plan;
    });
  }
  private async attempt(
    tx: EntityManager,
    f: CloudFence,
    id: string,
  ): Promise<Attempt> {
    const [a] = await tx.query<Attempt[]>(
      'SELECT * FROM cloud_workflow_attempts WHERE id=$1 AND parent_id=$2 AND owner_id=$3 FOR UPDATE',
      [id, f.parentId, f.ownerId],
    );
    if (!a || a.fence !== f.fence) throw invalid();
    return a;
  }
  /** reservation 只扣预算，不返回密钥，也不等同于可发送资格。 */
  async reserveExecution(f: CloudFence, wire: WireRequest): Promise<string> {
    return this.locked(async (tx) => {
      const p = await this.fenced(tx, f, Date.now),
        plan = await this.plan(tx, p);
      const step = plan.steps.find((s) => s.id === wire.refs.stepId);
      if (
        !step ||
        step.state !== 'queued' ||
        plan.steps.some(
          (s) => s.ordinal < step.ordinal && s.state !== 'complete',
        )
      )
        throw invalid();
      const expected = buildWire(plan, step);
      if (
        expected.digest !== wire.digest ||
        expected.body !== wire.body ||
        expected.inputEstimate !== wire.inputEstimate ||
        !equalRefs(expected.refs, wire.refs)
      )
        throw invalid();
      if (
        (await this.profileHash(tx, step.provider_id, step.model_row_id)) !==
        step.profile_hash
      )
        throw new ConflictException('needs_configuration');
      const cost = wire.inputEstimate + p.output_tokens;
      if (
        p.attempts_used >= p.max_attempts ||
        p.estimated_tokens + cost > p.token_limit
      )
        throw new ConflictException('budget_exhausted');
      this.liveTime(p, Date.now);
      const id = randomUUID();
      await tx.query(
        `INSERT INTO cloud_workflow_attempts(id,parent_id,step_id,owner_id,fence,number,state,estimated_tokens,request_digest,input_refs,grant_version)
        VALUES($1,$2,$3,$4,$5,$6,'dispatched',$7,$8,$9,$10)`,
        [
          id,
          f.parentId,
          step.id,
          f.ownerId,
          f.fence,
          p.attempts_used + 1,
          cost,
          wire.digest,
          JSON.stringify(wire.refs),
          p.grant_version,
        ],
      );
      await tx.query(
        "UPDATE cloud_workflow_steps SET state='running',revision=revision+1 WHERE id=$1 AND parent_id=$2 AND owner_id=$3",
        [step.id, f.parentId, f.ownerId],
      );
      await tx.query(
        'UPDATE cloud_workflow_parents SET attempts_used=attempts_used+1,estimated_tokens=estimated_tokens+$1,revision=revision+1 WHERE id=$2 AND owner_id=$3',
        [cost, f.parentId, f.ownerId],
      );
      await this.event(
        tx,
        await this.owned(tx, f.ownerId, f.parentId),
        'dispatch_reserved',
      );
      return id;
    });
  }
  /** 最后短事务消耗资格；返回后不再做任何异步准备。commit ack 不明则禁止 fetch。 */
  async authorizeSend(
    f: CloudFence,
    id: string,
    wire: WireRequest,
  ): Promise<SendPermit> {
    return this.locked(async (tx) => {
      const p = await this.fenced(tx, f, Date.now),
        a = await this.attempt(tx, f, id);
      if (
        a.state !== 'dispatched' ||
        a.send_authorized_at ||
        !a.input_refs ||
        !a.request_digest ||
        a.grant_version !== p.grant_version ||
        a.request_digest !== wire.digest ||
        !equalRefs(a.input_refs, wire.refs)
      )
        throw invalid();
      const plan = await this.plan(tx, p),
        step = plan.steps.find((s) => s.id === a.step_id);
      if (
        !step ||
        step.state !== 'running' ||
        step.revision !== wire.refs.stepRevision + 1 ||
        plan.steps.some(
          (s) => s.ordinal < step.ordinal && s.state !== 'complete',
        )
      )
        throw invalid();
      const expected = buildWire(plan, {
        ...step,
        revision: wire.refs.stepRevision,
      });
      if (
        expected.body !== wire.body ||
        expected.digest !== a.request_digest ||
        !equalRefs(expected.refs, a.input_refs)
      )
        throw invalid();
      if (
        (await this.profileHash(tx, step.provider_id, step.model_row_id)) !==
        step.profile_hash
      )
        throw new ConflictException('needs_configuration');
      const [profile] = await tx.query<
        Array<{ baseUrl: string; apiKey: string; modelId: string }>
      >(
        `SELECT p."baseUrl",p."apiKey",m."modelId" FROM ai_providers p JOIN ai_models m ON m."providerId"=p.id
         WHERE p.id=$1 AND m.id=$2 FOR SHARE OF p,m`,
        [step.provider_id, step.model_row_id],
      );
      const endpoint = new URL(
        profile.baseUrl.replace(/\/$/, '') + '/chat/completions',
      );
      if (
        !['https:', 'http:'].includes(endpoint.protocol) ||
        endpoint.username ||
        endpoint.password ||
        endpoint.hash
      )
        throw new ConflictException('needs_configuration');
      const now = this.liveTime(p, Date.now);
      const rows = await tx.query<Array<{ id: string }>>(
        `WITH changed AS (
        UPDATE cloud_workflow_attempts SET send_authorized_at=$1 WHERE id=$2 AND parent_id=$3 AND owner_id=$4 AND send_authorized_at IS NULL RETURNING id) SELECT * FROM changed`,
        [new Date(now), id, f.parentId, f.ownerId],
      );
      if (rows.length !== 1) throw invalid();
      await this.event(tx, p, 'send_authorized');
      return {
        endpoint: endpoint.toString(),
        key: profile.apiKey,
        model: profile.modelId,
        digest: a.request_digest,
        attemptId: id,
        deadline: Math.min(
          p.deadline_at.getTime(),
          p.grant_expires_at.getTime(),
          p.lease_expires_at!.getTime(),
        ),
      };
    });
  }
  /** 完整输出与用量已知时只提交这一份 buffer。重复 ack 对账不再次计量/返工/发事件。 */
  async commitOutput(
    f: CloudFence,
    id: string,
    output: KnownOutput,
  ): Promise<CloudParent> {
    if (
      !boundedOutput(output.content) ||
      (output.usage &&
        ![output.usage.input, output.usage.output].every(
          (v) => Number.isSafeInteger(v) && v >= 0 && v <= 1000000,
        ))
    )
      throw invalid();
    return this.locked(async (tx) => {
      let p = await this.owned(tx, f.ownerId, f.parentId);
      const a = await this.attempt(tx, f, id);
      const [old] = await tx.query<
        Array<{
          content_hash: string;
          input_tokens: number | null;
          output_tokens: number | null;
        }>
      >(
        'SELECT r.content_hash,a.input_tokens,a.output_tokens FROM cloud_workflow_results r JOIN cloud_workflow_attempts a ON r.attempt_id=a.id WHERE r.attempt_id=$1 AND r.parent_id=$2 AND r.owner_id=$3',
        [id, f.parentId, f.ownerId],
      );
      if (old) {
        if (
          p.fence !== f.fence ||
          p.lease_owner !== f.leaseOwner ||
          p.state === 'deleted' ||
          old.content_hash !== hashText(output.content) ||
          old.input_tokens !== (output.usage?.input ?? null) ||
          old.output_tokens !== (output.usage?.output ?? null)
        )
          throw invalid();
        return p;
      }
      p = await this.fenced(tx, f, Date.now);
      if (
        a.state !== 'dispatched' ||
        !a.send_authorized_at ||
        !a.input_refs ||
        a.grant_version !== p.grant_version
      )
        throw invalid();
      const plan = await this.plan(tx, p),
        step = plan.steps.find((s) => s.id === a.step_id)!;
      if (
        step.state !== 'running' ||
        step.revision !== a.input_refs.stepRevision + 1
      )
        throw invalid();
      // 当前 writing 身份来自原输入引用，不按角色名猜一个旧版本。
      let valid = true,
        rework = false,
        reason: string | null = null;
      let finalResult: string | null = null;
      if (step.role === 'review') {
        const review = parseReview(output.content);
        const writing = plan.steps.find((s) => s.role === 'writing')!;
        const result = plan.results.find(
          (r) =>
            r.step_id === writing.id && r.version === writing.result_version,
        );
        if (
          !result ||
          !a.input_refs.results.some(
            (r) =>
              r.id === result.id &&
              r.hash === result.content_hash &&
              r.version === result.version,
          )
        )
          throw invalid();
        valid =
          !!review &&
          review.passed &&
          acceptancePassed(result.content, plan.payload.acceptance);
        if (!valid) {
          rework =
            !!review && plan.parent.reworks < plan.payload.budget.reworks;
          reason = !review
            ? 'review_validation_failed'
            : rework
              ? 'review_rework'
              : 'rework_limit_reached';
        } else finalResult = result.id;
      }
      const now = this.liveTime(p, Date.now),
        resultId = randomUUID();
      await tx.query(
        'INSERT INTO cloud_workflow_results(id,parent_id,owner_id,step_id,attempt_id,version,content,content_hash) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',
        [
          resultId,
          f.parentId,
          f.ownerId,
          step.id,
          id,
          step.result_version + 1,
          output.content,
          hashText(output.content),
        ],
      );
      await tx.query(
        'UPDATE cloud_workflow_attempts SET state=$1,input_tokens=$2,output_tokens=$3,finished_at=$4,failure_code=$5 WHERE id=$6 AND parent_id=$7 AND owner_id=$8',
        [
          valid ? 'succeeded' : 'failed',
          output.usage?.input ?? null,
          output.usage?.output ?? null,
          new Date(now),
          reason,
          id,
          f.parentId,
          f.ownerId,
        ],
      );
      await tx.query(
        'UPDATE cloud_workflow_steps SET state=$1,result_version=result_version+1,revision=revision+1 WHERE id=$2 AND parent_id=$3 AND owner_id=$4',
        [valid ? 'complete' : 'failed', step.id, f.parentId, f.ownerId],
      );
      if (rework)
        await tx.query(
          "UPDATE cloud_workflow_steps SET state='queued',revision=revision+1 WHERE parent_id=$1 AND owner_id=$2 AND role IN ('writing','review')",
          [f.parentId, f.ownerId],
        );
      const state =
        step.role === 'review'
          ? valid
            ? 'complete'
            : rework
              ? 'running'
              : 'paused'
          : 'running';
      await tx.query(
        'UPDATE cloud_workflow_parents SET state=$1,reason=$2,reworks=reworks+$3,final_result_id=$4,usage_unknown=usage_unknown OR $5,revision=revision+1,updated_at=now() WHERE id=$6 AND owner_id=$7',
        [
          state,
          reason,
          rework ? 1 : 0,
          finalResult,
          output.usage === null,
          f.parentId,
          f.ownerId,
        ],
      );
      if (state !== 'running') await this.release(tx, f);
      const live = await this.owned(tx, f.ownerId, f.parentId);
      await this.event(
        tx,
        live,
        rework
          ? 'rework_committed'
          : valid
            ? 'result_committed'
            : 'review_rejected',
      );
      return live;
    });
  }
  private async release(tx: EntityManager, f: CloudFence) {
    await tx.query(
      'UPDATE cloud_workflow_slot SET parent_id=NULL,lease_owner=NULL,fence=NULL,expires_at=NULL WHERE id=1 AND parent_id=$1 AND lease_owner=$2 AND fence=$3',
      [f.parentId, f.leaseOwner, f.fence],
    );
  }
  /** 已知完整 HTTP 失败/未发送配置失败与不完整网络结果分别落盘；预算均不退。 */
  async pauseExecution(
    f: CloudFence,
    id: string | null,
    code: string,
    known: boolean,
    status: number | null = null,
  ): Promise<void> {
    await this.locked(async (tx) => {
      const p = await this.owned(tx, f.ownerId, f.parentId);
      if (
        p.fence !== f.fence ||
        p.lease_owner !== f.leaseOwner ||
        p.state !== 'running'
      )
        throw invalid();
      let usageUnknown = !known;
      if (id) {
        const a = await this.attempt(tx, f, id);
        if (a.state !== 'dispatched') throw invalid();
        usageUnknown ||= !!a.send_authorized_at;
        await tx.query(
          'UPDATE cloud_workflow_attempts SET state=$1,failure_code=$2,http_status=$3,finished_at=now() WHERE id=$4 AND parent_id=$5 AND owner_id=$6',
          [
            known ? 'failed' : 'unknown',
            code,
            status,
            id,
            f.parentId,
            f.ownerId,
          ],
        );
        await tx.query(
          'UPDATE cloud_workflow_steps SET state=$1,revision=revision+1 WHERE id=$2 AND parent_id=$3 AND owner_id=$4',
          [known ? 'failed' : 'unknown', a.step_id, f.parentId, f.ownerId],
        );
      } else {
        // reservation 的 commit ack 不明时，调用方可能没有拿到 attemptId。
        // 只按原 fence 找到持久 dispatched，必须 unknown，不能释放槽后重领发送。
        const orphan = await tx.query<Array<{ step_id: string }>>(
          `WITH changed AS (UPDATE cloud_workflow_attempts SET state='unknown',failure_code='reservation_ack_unknown',finished_at=now()
           WHERE parent_id=$1 AND owner_id=$2 AND fence=$3 AND state='dispatched' RETURNING step_id) SELECT * FROM changed`,
          [f.parentId, f.ownerId, f.fence],
        );
        for (const attempt of orphan)
          await tx.query(
            "UPDATE cloud_workflow_steps SET state='unknown',revision=revision+1 WHERE id=$1 AND parent_id=$2 AND owner_id=$3",
            [attempt.step_id, f.parentId, f.ownerId],
          );
        if (orphan.length) usageUnknown = true;
      }
      const state =
        code === 'needs_configuration'
          ? 'needs_configuration'
          : code === 'budget_exhausted' || code === 'input_budget_exhausted'
            ? 'budget_exhausted'
            : 'paused';
      await tx.query(
        'UPDATE cloud_workflow_parents SET state=$1,reason=$2,usage_unknown=usage_unknown OR $3,revision=revision+1 WHERE id=$4 AND owner_id=$5',
        [state, code, usageUnknown, f.parentId, f.ownerId],
      );
      await this.release(tx, f);
      await this.event(
        tx,
        await this.owned(tx, f.ownerId, f.parentId),
        'execution_paused',
      );
    });
  }
}
