import {
  Injectable,
  HttpException,
  ServiceUnavailableException,
  UnauthorizedException,
  ConflictException,
  type BeforeApplicationShutdown,
} from '@nestjs/common';
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from 'node:http';
import { CloudWorkflowExecutionStore } from './cloud-workflow.execution-store';
import { CloudWorkflowWorker } from './cloud-workflow.worker';
import { CloudWorkflowReadiness } from './cloud-workflow.readiness';
import { CloudWorkflowService } from './cloud-workflow.service';
import { TokenAuthenticationService } from '../auth/token-authentication.service';
import { extractBearer } from '../auth/bearer';
import { CLOUD_LIMITS, object, uuid } from './cloud-workflow.contract';
import { schedulerEpoch } from './cloud-workflow.scheduler-gate';

/** Dedicated listener, NEVER a public Nest controller. Network topology is its authority. */
@Injectable()
export class CloudWorkflowPrivateRuntime implements BeforeApplicationShutdown {
  private enabled = false;
  private closing = false;
  private server: Server | null = null;
  private starting: Promise<void> | null = null;
  private pumping: Promise<void> | null = null;
  private closingPromise: Promise<void> | null = null;
  private readonly handlers = new Set<Promise<void>>();
  private readonly service: CloudWorkflowService;
  constructor(
    private readonly store: CloudWorkflowExecutionStore,
    private readonly worker: CloudWorkflowWorker,
    private readonly authentication: TokenAuthenticationService,
    readiness: CloudWorkflowReadiness,
  ) {
    this.service = new CloudWorkflowService(store, readiness);
  }
  // Synthetic tests must opt in by code injection. No environment/HTTP/query activation.
  static synthetic(
    store: CloudWorkflowExecutionStore,
    worker: CloudWorkflowWorker,
    auth: TokenAuthenticationService,
    ready: CloudWorkflowReadiness,
  ) {
    const instance = new CloudWorkflowPrivateRuntime(
      store,
      worker,
      auth,
      ready,
    );
    instance.enabled = true;
    return instance;
  }
  async listen(port = 3101, host = '0.0.0.0'): Promise<number> {
    if (!this.enabled || this.closing || this.server)
      throw Error('private_runtime_disabled');
    const server = createServer((req, res) => {
      const pending = this.handle(req, res).finally(() =>
        this.handlers.delete(pending),
      );
      this.handlers.add(pending);
    });
    server.requestTimeout = server.headersTimeout = 5000;
    this.server = server;
    const starting = (this.starting = new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, host, resolve);
    }));
    try {
      await starting;
    } catch (e) {
      this.server = null;
      throw e;
    } finally {
      if (this.starting === starting) this.starting = null;
    }
    if (this.closing) throw Error('private_runtime_closed');
    const address = server.address();
    if (!address || typeof address === 'string')
      throw Error('listener_missing');
    return address.port;
  }
  private async body(req: IncomingMessage): Promise<unknown> {
    const chunks: Buffer[] = [];
    let size = 0;
    req.setTimeout(5000, () => req.destroy());
    for await (const value of req) {
      const chunk = Buffer.isBuffer(value) ? value : Buffer.from(String(value));
      size += chunk.length;
      if (size > CLOUD_LIMITS.requestBytes)
        throw new HttpException('bounded_body', 413);
      chunks.push(chunk);
    }
    return JSON.parse(
      new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)),
    ) as unknown;
  }
  private async handle(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    try {
      if (!this.enabled || this.closing)
        throw new ServiceUnavailableException();
      if (req.method !== 'POST') throw new HttpException('private_route', 404);
      const path = new URL(req.url ?? '/', 'http://internal').pathname;
      const body = await this.body(req);
      if (this.closing) throw new ServiceUnavailableException();
      let result: unknown;
      if (path === '/_cloud/control') {
        const op =
          body && typeof body === 'object' && !Array.isArray(body)
            ? (body as { op?: unknown }).op
            : null;
        if (op === 'status') {
          object(body, ['op']);
          result = await this.store.schedulerStatus();
        } else {
          const fields = object(body, ['op', 'epoch']);
          const epoch = schedulerEpoch(fields.epoch);
          if (fields.op === 'open')
            result = await this.store.schedulerOpen(epoch);
          else if (fields.op === 'close')
            result = await this.store.schedulerClose(epoch);
          else if (fields.op === 'kick') result = await this.kick(epoch);
          else throw new HttpException('private_operation', 400);
        }
      } else if (
        path === '/_cloud/admit' ||
        /^\/_cloud\/admit\/[a-f0-9-]{36}\/continue$/.test(path)
      ) {
        const token = extractBearer(req.headers.authorization);
        const auth = token
          ? await this.authentication.verifyCloud(token, (id) =>
              this.store.cloudAuthUser(id),
            )
          : null;
        if (!auth) throw new UnauthorizedException();
        if (this.closing) throw new ServiceUnavailableException();
        const epoch = schedulerEpoch(req.headers['x-chatai-cloud-epoch']);
        result =
          path === '/_cloud/admit'
            ? await this.service.create(auth, body, { epoch })
            : await this.service.control(
                auth,
                uuid(path.split('/')[3]),
                'continue',
                body,
                { epoch },
              );
      } else throw new HttpException('private_route', 404);
      if (!res.destroyed) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      }
    } catch (e) {
      // No raw body/JWT/key/endpoint/errors in logs or responses.
      if (!res.destroyed) {
        res.writeHead(e instanceof HttpException ? e.getStatus() : 503, {
          'Content-Type': 'application/json',
        });
        res.end('{"code":"private_control_unconfirmed"}');
      }
    }
  }
  private async kick(epoch: string) {
    const status = await this.store.schedulerStatus();
    if (status.epoch !== epoch) throw new ConflictException('scheduler_stale');
    if (!this.pumping && !this.worker.isActive && status.work !== 'idle') {
      this.pumping = this.pump()
        .catch(() => {
          /* DB failure: worker aborts and no new claim; successor rechecks PG. */
        })
        .finally(() => {
          this.pumping = null;
        });
    }
    return status; // No wait for a model; busy may include expired slot requiring reap.
  }
  private async pump(): Promise<void> {
    for (let n = 0; n < 4 && !this.closing; n++) {
      const before = await this.store.schedulerStatus();
      if (before.work === 'idle') return;
      const ran = await this.worker.runOnce();
      const after = await this.store.schedulerStatus();
      if (after.work === 'idle' || (!ran && after.work === 'busy')) return;
      // claim(null) may have expired only the head. Recheck full queue and progress boundedly.
    }
  }
  beforeApplicationShutdown(): Promise<void> {
    this.closing = true;
    return (this.closingPromise ??= (async () => {
      if (this.starting) await this.starting.catch(() => {});
      await this.worker.shutdown();
      if (this.worker.isActive) throw Error('worker_not_settled');
      const server = this.server;
      this.server = null;
      if (server) {
        server.closeAllConnections();
        await new Promise<void>((resolve, reject) =>
          server.close((e) => (e ? reject(e) : resolve())),
        );
      }
      // Transactions have real SQL/acquisition timeouts. No pool close until their promises settled.
      await Promise.all([...this.handlers]);
      await this.pumping;
    })());
  }
}
