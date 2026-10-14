import {
  CloudScheduler,
  type SchedulerState,
  type DurableSchedulerState,
  type WakeIntent,
  type GateStatus,
} from '../../../cloudflare/backend/src/cloud-scheduler';

/** Persistent state fake, not a Cloudflare SDK/runtime restart test. */
class State implements DurableSchedulerState {
  value: SchedulerState | null = null;
  async read() {
    await Promise.resolve();
    return structuredClone(this.value);
  }
  async mutate<T>(
    f: (s: SchedulerState | null) => { state: SchedulerState; result: T },
  ): Promise<T> {
    await Promise.resolve();
    const next = f(structuredClone(this.value));
    this.value = structuredClone(next.state);
    return next.result;
  }
}
function deferred() {
  let release!: () => void;
  const promise = new Promise<void>((r) => {
    release = r;
  });
  return { promise, release };
}
function fixture() {
  const state = new State(),
    schedules = new Map<string, WakeIntent>(),
    events: string[] = [];
  let time = 100000,
    id = 0,
    gate: GateStatus = { epoch: '0', accepting: false, work: 'idle' };
  const failures = {
    ensure: false,
    ensureAck: false,
    openAck: false,
    status: false,
    kick: false,
    closeAck: false,
  };
  let closeHeld: ReturnType<typeof deferred> | null = null;
  const wakes = {
    async ensure(g: string, w: WakeIntent) {
      await Promise.resolve();
      events.push(`ensure:${g}`);
      if (failures.ensure) throw Error('schedule_write_failed');
      schedules.set(`${g}:${w.id}`, w);
      if (failures.ensureAck) throw Error('schedule_ack_unknown');
    },
    async exists(g: string, w: WakeIntent) {
      await Promise.resolve();
      return schedules.get(`${g}:${w.id}`)?.at === w.at;
    },
    async cancel(g: string, w: WakeIntent) {
      await Promise.resolve();
      events.push(`cancel:${g}`);
      schedules.delete(`${g}:${w.id}`);
    },
  };
  const control = {
    async open(g: string) {
      await Promise.resolve();
      events.push(`open:${g}`);
      if (
        BigInt(g) < BigInt(gate.epoch) ||
        (g === gate.epoch && !gate.accepting)
      )
        throw Error('closed');
      gate = { ...gate, epoch: g, accepting: true };
      if (failures.openAck) throw Error('open_ack_unknown');
      return { ...gate };
    },
    async status() {
      await Promise.resolve();
      if (failures.status) throw Error('db_unknown');
      return { ...gate };
    },
    async kick(g: string) {
      await Promise.resolve();
      events.push(`kick:${g}`);
      if (failures.kick) throw Error('db_down');
      return { ...gate };
    },
    async closeIfIdle(g: string) {
      events.push(`close:${g}`);
      if (gate.work === 'idle' && BigInt(g) >= BigInt(gate.epoch))
        gate = { ...gate, epoch: g, accepting: false };
      const response = { ...gate };
      if (closeHeld) await closeHeld.promise;
      if (failures.closeAck) throw Error('close_ack_unknown');
      return response;
    },
  };
  const make = () =>
    new CloudScheduler(
      state,
      wakes,
      control,
      () => time,
      () => `opaque_${++id}`,
    );
  return {
    state,
    schedules,
    events,
    failures,
    make,
    clock: (n: number) => {
      time += n;
    },
    work: (work: GateStatus['work']) => {
      gate.work = work;
    },
    gate: () => ({ ...gate }),
    holdClose: () => (closeHeld = deferred()),
  };
}
describe('C3a pure persistent DO protocol (fake storage/control, no SDK or HTTP)', () => {
  it('does nothing at construction, pre-arm failure never opens gate', async () => {
    const f = fixture(),
      s = f.make();
    expect(f.events).toEqual([]);
    f.failures.ensure = true;
    await expect(s.armForAdmission()).rejects.toThrow('schedule_write_failed');
    expect(f.events).toEqual(['ensure:1']);
    expect(f.state.value?.phase).toBe('arming');
  });
  it('schedule ack unknown queries back, confirms successor before open', async () => {
    const f = fixture();
    f.failures.ensureAck = true;
    expect(await f.make().armForAdmission()).toEqual({ epoch: '1' });
    expect(f.events).toEqual(['ensure:1', 'open:1']);
    expect(f.schedules.size).toBe(1);
  });
  it('open ack unknown queries gate without replaying any user mutation', async () => {
    const f = fixture();
    f.failures.openAck = true;
    expect(await f.make().armForAdmission()).toEqual({ epoch: '1' });
    expect(f.events.filter((x) => x.startsWith('open'))).toHaveLength(1);
  });
  it('unknown DB result rejects admission while retaining successor', async () => {
    const f = fixture();
    f.failures.openAck = f.failures.status = true;
    await expect(f.make().armForAdmission()).rejects.toThrow('db_unknown');
    expect(f.schedules.size).toBe(1);
    expect(f.state.value?.phase).toBe('arming');
  });
  for (const work of ['pending', 'busy'] as const)
    it(`${work} wake cannot disarm; reconstructed object keeps same persistent state`, async () => {
      const f = fixture();
      await f.make().armForAdmission();
      f.work(work);
      f.clock(20000);
      await f.make().onWake('1');
      expect(f.state.value?.phase).toBe('armed');
      expect(f.schedules.size).toBeGreaterThan(0);
      expect(f.events).not.toContain('close:1');
    });
  it('business callback failure already has a successor; ensure failure escapes before kick', async () => {
    const f = fixture(),
      s = f.make();
    await s.armForAdmission();
    f.clock(20000);
    f.failures.kick = true;
    await expect(s.onWake('1')).rejects.toThrow('db_down');
    expect(f.schedules.size).toBe(2);
    const kicks = f.events.filter((x) => x.startsWith('kick')).length;
    f.clock(20000);
    f.failures.ensure = true;
    await expect(s.onWake('1')).rejects.toThrow('schedule_write_failed');
    expect(f.events.filter((x) => x.startsWith('kick'))).toHaveLength(kicks);
  });
  it('close ack loss stays armed; explicit later acknowledged closed status disarms', async () => {
    const f = fixture(),
      s = f.make();
    await s.armForAdmission();
    f.failures.closeAck = true;
    await expect(s.onWake('1')).rejects.toThrow('close_ack_unknown');
    expect(f.state.value?.phase).toBe('armed');
    expect(f.schedules.size).toBe(1);
    f.failures.closeAck = false;
    await s.onWake('1');
    expect(f.state.value?.phase).toBe('idle');
    expect(f.schedules.size).toBe(0);
  });
  it('old close response cannot clear new generation or cancel its successor', async () => {
    const f = fixture();
    f.failures.openAck = f.failures.status = true;
    await expect(f.make().armForAdmission()).rejects.toThrow();
    f.failures.openAck = f.failures.status = false;
    const held = f.holdClose(),
      closing = f.make().onWake('1');
    for (let i = 0; i < 20 && !f.events.includes('close:1'); i++)
      await Promise.resolve();
    expect(f.events).toContain('close:1');
    expect(await f.make().armForAdmission()).toEqual({ epoch: '2' });
    held.release();
    await closing;
    expect(f.state.value?.epoch).toBe('2');
    expect(f.state.value?.phase).toBe('armed');
    expect([...f.schedules.keys()].some((x) => x.startsWith('2:'))).toBe(true);
  });
  it('stale/duplicate callback cannot touch a new or idle generation', async () => {
    const f = fixture(),
      s = f.make();
    await s.armForAdmission();
    await s.onWake('1');
    await s.armForAdmission();
    const before = [...f.events];
    await s.onWake('1');
    expect(f.events).toEqual(before);
    await s.onWake('2');
    const closed = [...f.events];
    await s.onWake('2');
    expect(f.events).toEqual(closed);
  });
  it('decimal epoch retains precision, never resets/wraps; malformed persisted state fails closed', async () => {
    const f = fixture();
    f.state.value = {
      version: 1,
      epoch: '9007199254740992',
      phase: 'idle',
      wake: null,
    };
    expect(await f.make().armForAdmission()).toEqual({
      epoch: '9007199254740993',
    });
    f.state.value = {
      version: 1,
      epoch: '9223372036854775807',
      phase: 'idle',
      wake: null,
    };
    await expect(f.make().armForAdmission()).rejects.toThrow('exhausted');
    f.state.value.epoch = '01';
    await expect(f.make().armForAdmission()).rejects.toThrow('invalid');
  });
});
