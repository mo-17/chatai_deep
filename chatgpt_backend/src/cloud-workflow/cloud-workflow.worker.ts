import {
  Injectable,
  Optional,
  Inject,
  ConflictException,
  ForbiddenException,
  type BeforeApplicationShutdown,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import {
  CloudWorkflowTransport,
  CloudTransportFailure,
} from './cloud-workflow.transport';
import { buildWire, type KnownOutput } from './cloud-workflow.execution';
import type { CloudFence } from './cloud-workflow.store';

export const CLOUD_WORKER_OPTIONS = Symbol('CLOUD_WORKER_OPTIONS');
export interface CloudWorkerOptions {
  heartbeatMs?: number;
  saveDelayMs?: number;
}
interface ActiveExecution {
  controller: AbortController;
  done: Promise<boolean>;
  hardTimer?: ReturnType<typeof setTimeout>;
  heartbeatTimer?: ReturnType<typeof setTimeout>;
  heartbeat?: Promise<void>;
  expires: number;
  stopped: boolean;
  databaseFailed: boolean;
  heartbeatFailure?: unknown;
}
/** 显式驱动的一次纵向执行器。构造/模块启动绝不领取、不扫描。 */
@Injectable()
export class CloudWorkflowWorker implements BeforeApplicationShutdown {
  private readonly workerId = randomUUID();
  private readonly heartbeatMs: number;
  private readonly saveDelayMs: number;
  private active: ActiveExecution | null = null;
  private shutdownRequested = false;
  constructor(
    private readonly store: CloudWorkflowExecutionStore,
    private readonly transport: CloudWorkflowTransport,
    @Optional() @Inject(CLOUD_WORKER_OPTIONS) options: CloudWorkerOptions = {},
  ) {
    this.heartbeatMs = Math.max(
      25,
      Math.min(5000, options.heartbeatMs ?? 5000),
    );
    this.saveDelayMs = Math.max(1, Math.min(1000, options.saveDelayMs ?? 100));
  }
  runOnce(): Promise<boolean> {
    if (this.shutdownRequested || this.active) return Promise.resolve(false);
    const active: ActiveExecution = {
      controller: new AbortController(),
      done: Promise.resolve(false),
      expires: 0,
      stopped: false,
      databaseFailed: false,
    };
    this.active = active;
    active.done = this.execute(active).finally(() => {
      active.stopped = true;
      clearTimeout(active.hardTimer);
      clearTimeout(active.heartbeatTimer);
      if (this.active === active) this.active = null;
    });
    return active.done;
  }
  get isActive(): boolean {
    return this.active !== null;
  }
  async runUntilIdle(maxParents = 32): Promise<number> {
    if (!Number.isSafeInteger(maxParents) || maxParents < 1 || maxParents > 32)
      throw Error('invalid_worker_limit');
    let count = 0;
    while (
      !this.shutdownRequested &&
      count < maxParents &&
      (await this.runOnce())
    )
      count++;
    return count;
  }
  private deadline(a: ActiveExecution, end: number) {
    a.expires = end;
    clearTimeout(a.hardTimer);
    a.hardTimer = setTimeout(
      () => a.controller.abort(),
      Math.max(0, end - Date.now()),
    );
  }
  private heartbeat(a: ActiveExecution, f: CloudFence) {
    const schedule = () => {
      if (a.stopped || a.controller.signal.aborted) return;
      a.heartbeatTimer = setTimeout(() => {
        a.heartbeat = this.store
          .renew(f)
          .then((end) => {
            if (!a.stopped && !a.controller.signal.aborted)
              this.deadline(a, end.getTime());
          })
          .catch((error: unknown) => {
            a.databaseFailed = true;
            a.heartbeatFailure = error;
            a.controller.abort();
          })
          .finally(schedule);
      }, this.heartbeatMs);
    };
    schedule();
  }
  private async save(
    a: ActiveExecution,
    f: CloudFence,
    id: string,
    output: KnownOutput,
  ) {
    // 已收到完整输出只重试同一事务；不再次调用 transport，也不前进下一节点。
    let failure: unknown;
    for (let n = 0; n < 3; n++) {
      try {
        return await this.store.commitOutput(f, id, output);
      } catch (error) {
        failure = error;
        a.databaseFailed = true;
        a.controller.abort();
        if (
          error instanceof ConflictException ||
          error instanceof ForbiddenException ||
          this.shutdownRequested
        )
          break;
        if (n < 2)
          await new Promise<void>((resolve) =>
            setTimeout(resolve, this.saveDelayMs * (n + 1)),
          );
      }
    }
    throw failure;
  }
  private code(error: unknown): string {
    if (error instanceof CloudTransportFailure) return error.code;
    if (error instanceof ForbiddenException) return 'authorization_invalid';
    const message = error instanceof Error ? error.message : '';
    if (message === 'budget_exhausted' || message === 'input_budget_exhausted')
      return message;
    if (message.includes('模型') || message === 'needs_configuration')
      return 'needs_configuration';
    return 'execution_unknown';
  }
  private async execute(a: ActiveExecution): Promise<boolean> {
    let fence: CloudFence | null = null,
      attemptId: string | null = null;
    let knownOutput: KnownOutput | null = null;
    try {
      fence = await this.store.claim(this.workerId);
      if (!fence) return false;
      const first = await this.store.renew(fence);
      this.deadline(a, first.getTime());
      this.heartbeat(a, fence);
      while (!this.shutdownRequested && !a.controller.signal.aborted) {
        const plan = await this.store.readPlan(fence);
        const step = plan.steps.find((s) => s.state === 'queued');
        if (!step) throw Error('execution_unknown');
        const wire = buildWire(plan, step);
        if (a.controller.signal.aborted || this.shutdownRequested) break;
        attemptId = await this.store.reserveExecution(fence, wire);
        if (a.controller.signal.aborted || this.shutdownRequested) break;
        const permit = await this.store.authorizeSend(fence, attemptId, wire);
        // 许可返回后到 send 没有 await/hook。transport.send 在调用时直接 fetch。
        if (
          a.controller.signal.aborted ||
          this.shutdownRequested ||
          Date.now() >= permit.deadline
        )
          break;
        knownOutput = await this.transport.send(
          permit,
          wire,
          a.controller.signal,
        );
        const parent = await this.save(a, fence, attemptId, knownOutput);
        attemptId = null;
        knownOutput = null;
        if (parent.state !== 'running') return true;
        if (a.databaseFailed) break; // 只恢复保存；故障后绝不内存续跑下一请求。
      }
      throw new CloudTransportFailure(
        this.shutdownRequested ? 'shutdown' : 'interrupted',
        false,
      );
    } catch (error) {
      if (!fence) return false; // claim ack不明：不发送，PG租约按期回收。
      a.controller.abort();
      a.stopped = true;
      clearTimeout(a.heartbeatTimer);
      clearTimeout(a.hardTimer);
      if (a.heartbeat) await a.heartbeat;
      // fetch/body 已结算后才允许释放自己的槽。撤权用既有 fence 结算规则。
      try {
        await this.store.settleRevoked(fence);
      } catch {
        try {
          const code = this.code(a.heartbeatFailure ?? error);
          const known =
            error instanceof CloudTransportFailure
              ? error.known
              : !knownOutput &&
                (error instanceof ConflictException ||
                  error instanceof ForbiddenException ||
                  !attemptId);
          await this.store.pauseExecution(
            fence,
            attemptId,
            code,
            known,
            error instanceof CloudTransportFailure ? error.status : null,
          );
        } catch {
          /* 断库/旧fence只能留给持久租约回收；不得补签或发送。 */
        }
      }
      return true;
    } finally {
      a.stopped = true;
      clearTimeout(a.heartbeatTimer);
      clearTimeout(a.hardTimer);
      if (a.heartbeat) await a.heartbeat;
    }
  }
  async shutdown(): Promise<void> {
    this.shutdownRequested = true;
    const a = this.active;
    if (!a) return;
    a.controller.abort();
    // SQL有真实statement/lock timeout；此处上限仅限制宿主shutdown等待，不伪装事务已完成。
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      a.done,
      new Promise<void>((resolve) => {
        timer = setTimeout(resolve, 10000);
      }),
    ]);
    clearTimeout(timer);
  }
  beforeApplicationShutdown(): Promise<void> {
    return this.shutdown();
  }
}
