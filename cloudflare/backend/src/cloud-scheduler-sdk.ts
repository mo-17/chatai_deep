import type { Container } from "@cloudflare/containers";
import type {
  DurableSchedulerState,
  SchedulerState,
  WakeIntent,
  DurableWakes,
} from "./cloud-scheduler";
export const CLOUD_WAKE_CALLBACK = "chataiCloudWake";
export interface CloudWakePayload {
  epoch: string;
  intentId: string;
}
interface Row {
  id: string;
  payload: string;
  time: number;
}
export function wakePayload(v: unknown): CloudWakePayload {
  if (
    !v ||
    typeof v !== "object" ||
    Object.keys(v).sort().join() !== "epoch,intentId"
  )
    throw Error("sdk_wake_invalid");
  const p = v as CloudWakePayload;
  if (
    typeof p.epoch !== "string" ||
    !/^(0|[1-9][0-9]{0,18})$/.test(p.epoch) ||
    BigInt(p.epoch) > 9223372036854775807n ||
    typeof p.intentId !== "string" ||
    !/^[A-Za-z0-9_-]{1,80}$/.test(p.intentId)
  )
    throw Error("sdk_wake_invalid");
  return p;
}
/** One small opaque metadata row, lazily created only when synthetic runtime is enabled. */
export class SqlSchedulerState implements DurableSchedulerState {
  constructor(private readonly storage: DurableObjectStorage) {}
  readSync(): SchedulerState | null {
    this.storage.sql.exec(
      "CREATE TABLE IF NOT EXISTS chatai_cloud_scheduler (id INTEGER PRIMARY KEY CHECK(id=1), doc TEXT NOT NULL)",
    );
    const row = this.storage.sql
      .exec<{
        doc: string;
      }>("SELECT doc FROM chatai_cloud_scheduler WHERE id=1")
      .toArray()[0];
    if (!row) return null;
    if (row.doc.length > 1024) throw Error("sdk_state_overlimit");
    return JSON.parse(row.doc) as SchedulerState;
  }
  read(): Promise<SchedulerState | null> {
    return Promise.resolve(this.readSync());
  }
  mutate<T>(
    change: (s: SchedulerState | null) => { state: SchedulerState; result: T },
  ): Promise<T> {
    try {
      return Promise.resolve(
        this.storage.transactionSync(() => {
          const next = change(this.readSync()),
            doc = JSON.stringify(next.state);
          if (doc.length > 1024) throw Error("sdk_state_overlimit");
          this.storage.sql.exec(
            "INSERT INTO chatai_cloud_scheduler VALUES(1,?) ON CONFLICT(id) DO UPDATE SET doc=excluded.doc",
            doc,
          );
          return next.result;
        }),
      );
    } catch (e) {
      return Promise.reject(e);
    }
  }
}
/** Real 0.3.7 schedule API, raw bounded SQLite inspection (SDK listSchedules is LIMIT1). */
export class SdkSchedulerWakes implements DurableWakes {
  readonly consuming = new Set<string>();
  constructor(
    private readonly state: SqlSchedulerState,
    private readonly storage: DurableObjectStorage,
    private readonly host: Pick<
      Container<Cloudflare.Env>,
      "schedule" | "scheduleNextAlarm"
    >,
  ) {}
  rows(): Row[] {
    const rows = this.storage.sql
      .exec<{
        id: string;
        payload: string;
        time: number;
      }>(
        "SELECT id,payload,time FROM container_schedules WHERE callback=? LIMIT 3",
        CLOUD_WAKE_CALLBACK,
      )
      .toArray();
    if (rows.length > 2) throw Error("sdk_schedule_overlimit");
    return rows;
  }
  private erase(row: Row): void {
    this.storage.sql.exec(
      "DELETE FROM container_schedules WHERE id=? AND callback=? AND payload=?",
      row.id,
      CLOUD_WAKE_CALLBACK,
      row.payload,
    );
  }
  reclaim(): void {
    const s = this.state.readSync();
    if (!s) return;
    for (const row of this.rows()) {
      if (this.consuming.has(row.id)) continue;
      const p = wakePayload(JSON.parse(row.payload));
      if (BigInt(p.epoch) > BigInt(s.epoch))
        throw Error("sdk_future_epoch_unconfirmed");
      if (
        p.epoch !== s.epoch ||
        s.phase === "idle" ||
        p.intentId !== s.wake?.id
      )
        this.erase(row);
    }
  }
  pendingIntentId(epoch: string): string | undefined {
    this.reclaim();
    const s = this.state.readSync();
    if (s?.epoch !== epoch || s.phase === "idle") return;
    const row = this.rows().find((r) => {
      const p = wakePayload(JSON.parse(r.payload));
      return (
        p.epoch === s?.epoch &&
        p.intentId === s.wake?.id &&
        !this.consuming.has(r.id)
      );
    });
    if (row) return wakePayload(JSON.parse(row.payload)).intentId;
  }
  beginCallback(nativeId: string, payload: CloudWakePayload): boolean {
    const row = this.rows().find((r) => {
      const p = wakePayload(JSON.parse(r.payload));
      return (
        r.id === nativeId &&
        p.epoch === payload.epoch &&
        p.intentId === payload.intentId
      );
    });
    if (!row || this.consuming.has(nativeId)) return false;
    this.consuming.add(nativeId);
    return true;
  }
  async ensure(g: string, intent: WakeIntent): Promise<void> {
    const current = this.state.readSync();
    if (
      current?.epoch !== g ||
      current.wake?.id !== intent.id ||
      current.phase === "idle"
    )
      throw Error("sdk_state_superseded");
    this.reclaim();
    const matching = this.rows().find((r) => {
      const p = wakePayload(JSON.parse(r.payload));
      return (
        p.epoch === g && p.intentId === intent.id && !this.consuming.has(r.id)
      );
    });
    if (!matching) {
      // Ceiling prevents SDK floor(Date) from registering earlier than the intended instant.
      try {
        await this.host.schedule(
          new Date(Math.ceil(intent.at / 1000) * 1000),
          CLOUD_WAKE_CALLBACK,
          { epoch: g, intentId: intent.id },
        );
      } catch (e) {
        if (
          !this.rows().some((r) => {
            const p = wakePayload(JSON.parse(r.payload));
            return (
              p.epoch === g &&
              p.intentId === intent.id &&
              !this.consuming.has(r.id)
            );
          })
        )
          throw e;
      }
    }
    // SQL INSERT ack isn't alarm persistence. Re-arm/sync even after SDK schedule ACK loss.
    await this.host.scheduleNextAlarm();
    if (!(await this.exists(g, intent)))
      throw Error("sdk_successor_unconfirmed");
  }
  async exists(g: string, intent: WakeIntent): Promise<boolean> {
    const current = this.state.readSync();
    if (
      current?.epoch !== g ||
      current.wake?.id !== intent.id ||
      current.phase === "idle"
    )
      return false;
    const row = this.rows().find((r) => {
      const p = wakePayload(JSON.parse(r.payload));
      return (
        p.epoch === g &&
        p.intentId === intent.id &&
        !this.consuming.has(r.id) &&
        // A due but unconsumed row remains dispatchable at the next native alarm.
        // Logical at alone is no proof: getAlarm below must confirm persistence.
        r.time <= Math.ceil(intent.at / 1000)
      );
    });
    const alarm = await this.storage.getAlarm();
    return !!row && alarm !== null && alarm > Date.now();
  }
  cancel(g: string, intent: WakeIntent): Promise<void> {
    for (const row of this.rows()) {
      const p = wakePayload(JSON.parse(row.payload));
      if (p.epoch === g && p.intentId === intent.id) this.erase(row);
    }
    return Promise.resolve();
  }
}
