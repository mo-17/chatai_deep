import { Container, getRandom } from "@cloudflare/containers";
import { buildContainerEnv } from "./container-env";
import { CloudScheduler, type GateStatus } from "./cloud-scheduler";
import {
  SqlSchedulerState,
  SdkSchedulerWakes,
  wakePayload,
} from "./cloud-scheduler-sdk";
import { cloudPublicRequest } from "./cloud-public-request";

const INSTANCE_COUNT = 1;

declare global {
  namespace Cloudflare {
    interface Env {
      CORS_ORIGINS?: string;
      LOG_LEVEL?: string;
      DB_HOST?: string;
      DB_PORT?: string;
      DB_USER?: string;
      DB_PASSWORD?: string;
      DB_NAME?: string;
      DB_LOGGING?: string;
      DB_POOL_MAX?: string;
      DB_SSL?: string;
      DB_SSL_REJECT_UNAUTHORIZED?: string;
      DB_SYNCHRONIZE?: string;
      MIGRATION_LOCK_TIMEOUT_MS?: string;
      JWT_SECRET?: string;
      APP_SECRET_KEY?: string;
      APPLE_BUNDLE_ID?: string;
      APPLE_SERVICE_ID?: string;
      ADMIN_DEFAULT_USERNAME?: string;
      ADMIN_DEFAULT_PASSWORD?: string;
      BCRYPT_ROUNDS?: string;
      OPENAI_API_KEY?: string;
      OPENAI_BASE_URL?: string;
      DEEPSEEK_API_KEY?: string;
      DEEPSEEK_BASE_URL?: string;
      MCP_SERVERS?: string;
      AWS_ACCESS_KEY_ID?: string;
      AWS_SECRET_ACCESS_KEY?: string;
      R2_ACCOUNT_ID?: string;
      R2_BUCKET_NAME: string;
      REQUIRE_PRODUCTION_MODE?: string;
      REQUIRE_PERSISTENT_UPLOADS?: string;
      SYNC_V2_SHADOW_ENABLED?: string;
      SYNC_V2_SHADOW_USER_IDS?: string;
    }
  }
}

export class BackendContainer extends Container<Cloudflare.Env> {
  defaultPort = 3000;
  sleepAfter = "10m";

  // Worker secrets/vars are not inherited by Containers automatically.
  // Keep this allow-list explicit so an unrelated binding is never leaked.
  envVars = buildContainerEnv(this.env);
  // Fixed false. Only isolated tests subclass by code injection; no env/header/query switch.
  protected cloudRuntimeEnabled(): boolean {
    return false;
  }
  private schedulerState?: SqlSchedulerState;
  private schedulerWakes?: SdkSchedulerWakes;
  private cloudScheduler?: CloudScheduler;
  private cloudAlarmFlight: Promise<void> | null = null;
  private scheduler(): CloudScheduler {
    if (!this.cloudScheduler) {
      const state = (this.schedulerState = new SqlSchedulerState(
        this.ctx.storage,
      ));
      const wakes = (this.schedulerWakes = new SdkSchedulerWakes(
        state,
        this.ctx.storage,
        this,
      ));
      const control = async (op: string, epoch?: string) => {
        const response = await this.containerFetch(
          new Request("http://container/_cloud/control", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              op,
              ...(epoch === undefined ? {} : { epoch }),
            }),
            signal: AbortSignal.timeout(8000),
          }),
          3101,
        );
        if (!response.ok) throw Error("cloud_control_unconfirmed");
        // Tiny bounded metadata only, never task/JWT/profile output.
        const reader = response.body?.getReader();
        const chunks: Uint8Array[] = [];
        let bytes = 0;
        try {
          if (reader)
            for (;;) {
              const next = await reader.read();
              if (next.done) break;
              bytes += next.value.length;
              if (bytes > 1024) {
                await reader.cancel();
                throw Error("cloud_control_overlimit");
              }
              chunks.push(next.value);
            }
        } finally {
          reader?.releaseLock();
        }
        const data = new Uint8Array(bytes);
        let at = 0;
        for (const c of chunks) {
          data.set(c, at);
          at += c.length;
        }
        return JSON.parse(
          new TextDecoder("utf-8", { fatal: true }).decode(data),
        ) as GateStatus;
      };
      this.cloudScheduler = new CloudScheduler(
        state,
        wakes,
        {
          open: (g) => control("open", g),
          status: () => control("status"),
          closeIfIdle: (g) => control("close", g),
          kick: (g) => control("kick", g),
        },
        Date.now,
        () => crypto.randomUUID(),
        (g) => wakes.pendingIntentId(g),
      );
    }
    return this.cloudScheduler;
  }
  async chataiCloudWake(
    payload: unknown,
    schedule?: { taskId: string },
  ): Promise<void> {
    if (!this.cloudRuntimeEnabled() || !schedule) return;
    const p = wakePayload(payload),
      scheduler = this.scheduler();
    if (!this.schedulerWakes!.beginCallback(schedule.taskId, p)) return;
    await scheduler.onWake(p.epoch, p.intentId);
  }
  alarm(info?: AlarmInvocationInfo): Promise<void> {
    if (!this.cloudRuntimeEnabled()) return super.alarm(info);
    if (this.cloudAlarmFlight) return this.cloudAlarmFlight;
    const pending = this.cloudAlarm(info).finally(() => {
      if (this.cloudAlarmFlight === pending) this.cloudAlarmFlight = null;
    });
    this.cloudAlarmFlight = pending;
    return pending;
  }
  private async cloudAlarm(info?: AlarmInvocationInfo): Promise<void> {
    const scheduler = this.scheduler(),
      wakes = this.schedulerWakes!;
    try {
      await scheduler.ensureSuccessor();
      await super.alarm(info);
    } finally {
      wakes.consuming.clear();
      try {
        await scheduler.ensureSuccessor();
      } finally {
        wakes.consuming.clear();
        wakes.reclaim();
      }
    }
  }
  async fetch(incoming: Request): Promise<Response> {
    const request = cloudPublicRequest(incoming),
      path = new URL(request.url).pathname;
    const continuing =
      /^\/uapi\/cloud-workflows\/([a-f0-9-]{36})\/continue$/.exec(path);
    if (
      this.cloudRuntimeEnabled() &&
      request.method === "POST" &&
      (path === "/uapi/cloud-workflows" || continuing)
    ) {
      try {
        const { epoch } = await this.scheduler().armForAdmission();
        if (request.signal.aborted) throw Error("admission_aborted");
        const headers = new Headers(request.headers);
        headers.set("x-chatai-cloud-epoch", epoch);
        const url = continuing
          ? `http://container/_cloud/admit/${continuing[1]}/continue`
          : "http://container/_cloud/admit";
        return await this.containerFetch(
          new Request(url, {
            method: "POST",
            headers,
            body: request.body,
            signal: request.signal,
          }),
          3101,
        );
      } catch {
        return Response.json(
          { code: "cloud_admission_unconfirmed" },
          { status: 503 },
        );
      }
    }
    return this.containerFetch(request, 3000);
  }
}

export default {
  async fetch(request: Request, env: Cloudflare.Env): Promise<Response> {
    const instance = await getRandom(env.BACKEND, INSTANCE_COUNT);
    return instance.fetch(cloudPublicRequest(request));
  },
};
