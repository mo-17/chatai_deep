// Test-only native SQLite DO + installed SDK. Container VM/network is a transport shim.
import { BackendContainer, default as publicWorker } from "../src/index.ts";
export class SyntheticBackend extends BackendContainer {
  constructor(ctx, env) {
    Object.defineProperty(ctx, "container", { value: { running: false } });
    super(ctx, env);
    this.fault = {};
    this.callbacks = [];
    this.peakRows = 0;
    this.kickProofs = [];
    this.realNow = Date.now;
    this.clock = { enabled: false, value: 0 };
    // The application captures Date.now when constructing its pure scheduler.
    // Keep one stable function so both the SDK and that captured clock agree.
    Date.now = () => (this.clock.enabled ? this.clock.value : this.realNow());
  }
  cloudRuntimeEnabled() {
    return true;
  }
  async containerFetch(request, port) {
    if (
      new URL(request.url).pathname === "/_cloud/control" &&
      (await request.clone().json()).op === "kick"
    ) {
      this.kickProofs.push({
        callback: this.callbacks.at(-1),
        snapshot: this.inspect(),
        alarm: await this.ctx.storage.getAlarm(),
        at: Date.now(),
      });
    }
    const headers = new Headers(request.headers);
    headers.set("x-fixture-port", String(port));
    return this.env.BRIDGE.fetch(new Request(request, { headers }));
  }
  async schedule(...args) {
    if (this.fault.schedule === "always")
      throw Error("synthetic_write_unavailable");
    if (this.fault.schedule === "before") {
      this.fault.schedule = null;
      throw Error("synthetic_write_before");
    }
    const result = await super.schedule(...args);
    this.peakRows = Math.max(this.peakRows, this.inspect().rows.length);
    if (this.fault.schedule === "after") {
      this.fault.schedule = null;
      throw Error("synthetic_write_ack_unknown");
    }
    return result;
  }
  async scheduleNextAlarm(...args) {
    if (this.fault.alarm === "always")
      throw Error("synthetic_alarm_persistence_unavailable");
    return super.scheduleNextAlarm(...args);
  }
  async chataiCloudWake(payload, schedule) {
    this.callbacks.push({
      payload,
      nativeId: schedule?.taskId,
      at: Date.now(),
    });
    return super.chataiCloudWake(payload, schedule);
  }
  async runningAlarms(rounds, reenter = false, failPostflight = false) {
    // Only a test clock/timer; the installed SDK executes its own enumeration,
    // wait, callback, DELETE and activity logic without replacement.
    const realTimer = globalThis.setTimeout;
    this.clock.value = this.realNow();
    this.clock.enabled = true;
    globalThis.setTimeout = (callback, duration, ...args) => {
      const end = this.clock.value + Math.max(0, Number(duration));
      return realTimer(() => {
        this.clock.value = Math.max(this.clock.value, end);
        if (failPostflight) this.fault.alarm = "always";
        callback(...args);
      }, 5);
    };
    this.ctx.container.running = true;
    this.renewActivityTimeout();
    const cycles = [];
    try {
      for (let n = 0; n < rounds; n++) {
        const before = this.inspect();
        const enteredAt = this.clock.value;
        await this.alarm();
        cycles.push({
          enteredAt,
          exitedAt: this.clock.value,
          before,
          after: this.inspect(),
          callbacks: [...this.callbacks],
          kickProofs: [...this.kickProofs],
          peakRows: this.peakRows,
        });
        if (reenter && n === 0) {
          // Same pending row, even when the logical confirmation point expires again.
          this.clock.value += 45000;
          const admissions = [];
          for (let i = 0; i < 2; i++) {
            const reply = await super.fetch(
              new Request("http://public.invalid/uapi/cloud-workflows", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: '{"fixture":"same admission"}',
              }),
            );
            admissions.push({
              status: reply.status,
              snapshot: this.inspect(),
              alarm: await this.ctx.storage.getAlarm(),
            });
          }
          cycles[n].admissions = admissions;
        }
      }
      return cycles;
    } catch (e) {
      this.alarmFailure = {
        at: Date.now(),
        alarm: await this.ctx.storage.getAlarm(),
        snapshot: this.inspect(),
        callbacks: [...this.callbacks],
      };
      throw e;
    } finally {
      this.ctx.container.running = false;
      this.clock.enabled = false;
      globalThis.setTimeout = realTimer;
    }
  }
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (!path.startsWith("/__fixture/")) return super.fetch(request);
    try {
      if (path === "/__fixture/fault") this.fault = await request.json();
      if (path === "/__fixture/running") {
        const { rounds, reenter, failPostflight } = await request.json();
        if (!Number.isInteger(rounds) || rounds < 1 || rounds > 4)
          throw Error("fixture_rounds_invalid");
        return Response.json({
          cycles: await this.runningAlarms(rounds, reenter, failPostflight),
        });
      }
      if (path === "/__fixture/drop-pending") {
        const row = this.inspect().rows[0];
        this.ctx.storage.sql.exec(
          "DELETE FROM container_schedules WHERE id=? AND callback=?",
          row.id,
          row.callback,
        );
      }
      if (path === "/__fixture/fire") {
        const row = this.ctx.storage.sql
          .exec("SELECT doc FROM chatai_cloud_scheduler WHERE id=1")
          .toArray()[0];
        const state = JSON.parse(row.doc);
        const oldIntent = state.wake.id;
        // Artificial early SDK row: floor(Date) already due, logical ms at is still future.
        state.wake.at = Date.now() + 700;
        this.ctx.storage.sql.exec(
          "UPDATE chatai_cloud_scheduler SET doc=? WHERE id=1",
          JSON.stringify(state),
        );
        this.ctx.storage.sql.exec(
          "UPDATE container_schedules SET time=? WHERE callback=?",
          Math.floor(Date.now() / 1000),
          "chataiCloudWake",
        );
        await this.alarm();
        return Response.json({ oldIntent, ...this.inspect() });
      }
      if (path === "/__fixture/callback") {
        const p = await request.json();
        await this.chataiCloudWake(p, { taskId: "synthetic_duplicate_id" });
      }
      if (path === "/__fixture/alarm") await this.alarm();
      return Response.json(this.inspect());
    } catch (e) {
      return Response.json(
        {
          failure: e.message,
          alarmFailure: this.alarmFailure,
          ...this.inspect(),
        },
        { status: 503 },
      );
    }
  }
  inspect() {
    const exists = this.ctx.storage.sql
      .exec(
        "SELECT name FROM sqlite_master WHERE name='chatai_cloud_scheduler'",
      )
      .toArray().length;
    const row = exists
      ? this.ctx.storage.sql
          .exec("SELECT doc FROM chatai_cloud_scheduler WHERE id=1")
          .toArray()[0]
      : null;
    return {
      state: row ? JSON.parse(row.doc) : null,
      rows: this.ctx.storage.sql
        .exec("SELECT id,callback,time,payload FROM container_schedules")
        .toArray(),
    };
  }
}
export class DisabledSyntheticBackend extends SyntheticBackend {
  cloudRuntimeEnabled() {
    return false;
  }
}
export default publicWorker;
