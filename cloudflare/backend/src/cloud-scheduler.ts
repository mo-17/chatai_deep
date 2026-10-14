/** C3a pure durable protocol. No SDK, listener, timer or production wiring. */
export interface WakeIntent {
  id: string;
  // Future confirmation point. A trusted SDK adapter may retain an older due
  // native row only while a persisted future alarm still guarantees dispatch.
  at: number;
}
export interface SchedulerState {
  version: 1;
  epoch: string;
  phase: "idle" | "arming" | "armed";
  wake: WakeIntent | null;
}
export interface DurableSchedulerState {
  read(): Promise<SchedulerState | null>;
  // Adapter serializes this short synchronous transition; no business I/O in it.
  mutate<T>(
    transition: (state: SchedulerState | null) => {
      state: SchedulerState;
      result: T;
    },
  ): Promise<T>;
}
export interface DurableWakes {
  ensure(epoch: string, intent: WakeIntent): Promise<void>;
  exists(epoch: string, intent: WakeIntent): Promise<boolean>;
  cancel(epoch: string, intent: WakeIntent): Promise<void>; // Exact epoch/id only, never delete-by-name.
}
export interface GateStatus {
  epoch: string;
  accepting: boolean;
  work: "pending" | "busy" | "idle";
}
export interface SchedulerControl {
  open(epoch: string): Promise<{ epoch: string; accepting: boolean }>;
  status(): Promise<GateStatus>;
  closeIfIdle(epoch: string): Promise<GateStatus>;
  kick(epoch: string): Promise<GateStatus>;
}
const maxEpoch = 9223372036854775807n;
function epoch(v: string): string {
  if (
    typeof v !== "string" ||
    !/^(0|[1-9][0-9]{0,18})$/.test(v) ||
    BigInt(v) > maxEpoch
  )
    throw Error("scheduler_epoch_invalid");
  return v;
}
function checked(s: SchedulerState | null): SchedulerState {
  if (s === null) return { version: 1, epoch: "0", phase: "idle", wake: null };
  if (
    s.version !== 1 ||
    !["idle", "arming", "armed"].includes(s.phase) ||
    Object.keys(s).sort().join() !== "epoch,phase,version,wake"
  )
    throw Error("scheduler_state_invalid");
  epoch(s.epoch);
  if (
    s.wake &&
    (Object.keys(s.wake).sort().join() !== "at,id" ||
      typeof s.wake.id !== "string" ||
      !/^[A-Za-z0-9_-]{1,80}$/.test(s.wake.id) ||
      !Number.isSafeInteger(s.wake.at) ||
      s.wake.at <= 0)
  )
    throw Error("scheduler_wake_invalid");
  if (
    (s.phase === "idle" && s.wake !== null) ||
    (s.phase !== "idle" && !s.wake)
  )
    throw Error("scheduler_state_invalid");
  return s;
}
function status(s: GateStatus): GateStatus {
  epoch(s.epoch);
  if (
    typeof s.accepting !== "boolean" ||
    !["pending", "busy", "idle"].includes(s.work)
  )
    throw Error("scheduler_status_unknown");
  return s;
}

export class CloudScheduler {
  constructor(
    private readonly state: DurableSchedulerState,
    private readonly wakes: DurableWakes,
    private readonly control: SchedulerControl,
    private readonly now: () => number,
    private readonly newId: () => string,
    // Trusted adapter only: current native row which has not entered callback.
    private readonly pendingIdentity?: (epoch: string) => string | undefined,
  ) {}
  private wake(): WakeIntent {
    return { id: this.newId(), at: this.now() + 20000 };
  }
  private async current(g: string): Promise<boolean> {
    const s = checked(await this.state.read());
    return s.epoch === g && s.phase !== "idle";
  }
  private async successor(
    g: string,
    consumingIntentId?: string,
  ): Promise<boolean> {
    const pending = this.pendingIdentity?.(g);
    const intent = await this.state.mutate((s) => {
      const old = checked(s);
      if (old.epoch !== g || old.phase === "idle")
        return { state: old, result: null };
      const next =
        old.wake!.id === pending && old.wake!.id !== consumingIntentId
          ? old.wake!.at > this.now()
            ? old
            : {
                ...old,
                wake: { id: old.wake!.id, at: this.now() + 20000 },
              }
          : old.wake!.at > this.now() && old.wake!.id !== consumingIntentId
            ? old
            : { ...old, wake: this.wake() };
      checked(next);
      return { state: next, result: next.wake };
    });
    if (!intent) return false;
    try {
      await this.wakes.ensure(g, intent);
    } catch (e) {
      if (!(await this.wakes.exists(g, intent))) throw e;
    } // Query back ambiguous schedule ACK.
    if (!(await this.wakes.exists(g, intent)) || intent.at <= this.now())
      throw Error("scheduler_successor_unconfirmed");
    return this.current(g);
  }
  async armForAdmission(): Promise<{ epoch: string }> {
    const g = await this.state.mutate((s) => {
      const old = checked(s);
      if (old.phase === "armed") return { state: old, result: old.epoch };
      if (BigInt(old.epoch) === maxEpoch)
        throw Error("scheduler_epoch_exhausted");
      const next: SchedulerState = {
        version: 1,
        epoch: (BigInt(old.epoch) + 1n).toString(),
        phase: "arming",
        wake: this.wake(),
      };
      checked(next);
      return { state: next, result: next.epoch };
    });
    if (!(await this.successor(g))) throw Error("scheduler_superseded");
    let ack: { epoch: string; accepting: boolean };
    try {
      ack = await this.control.open(g);
    } catch {
      ack = status(await this.control.status());
    } // No user mutation replay.
    if (ack.epoch !== g || ack.accepting !== true)
      throw Error("scheduler_gate_unconfirmed");
    const armed = await this.state.mutate((s) => {
      const old = checked(s);
      if (old.epoch !== g || old.phase === "idle")
        return { state: old, result: false };
      return { state: { ...old, phase: "armed" }, result: true };
    });
    if (!armed) throw Error("scheduler_superseded");
    return { epoch: g };
  }
  async ensureSuccessor(consumingIntentId?: string): Promise<void> {
    const s = checked(await this.state.read());
    if (
      s.phase !== "idle" &&
      !(await this.successor(s.epoch, consumingIntentId))
    )
      throw Error("scheduler_superseded");
  }
  async onWake(g: string, consumingIntentId?: string): Promise<void> {
    epoch(g);
    if (
      !(await this.current(g)) ||
      !(await this.successor(g, consumingIntentId))
    )
      return;
    // Business errors keep the already persisted successor; ensure errors escape this entry.
    const next = status(await this.control.kick(g));
    if (!(await this.current(g)) || next.work !== "idle") return;
    // Only a positively acknowledged close for this generation can disarm.
    const closed = status(await this.control.closeIfIdle(g));
    if (closed.epoch !== g || closed.accepting || closed.work !== "idle")
      return;
    const intent = await this.state.mutate((s) => {
      const old = checked(s);
      if (old.epoch !== g || old.phase === "idle")
        return { state: old, result: null };
      return { state: { ...old, phase: "idle", wake: null }, result: old.wake };
    });
    if (intent) await this.wakes.cancel(g, intent);
  }
}
