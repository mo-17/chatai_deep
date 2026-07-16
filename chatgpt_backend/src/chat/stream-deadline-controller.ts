export type StreamRequestProfile = 'standard' | 'translation';
export type StreamDeadlineKind = 'first_event' | 'idle' | 'total';

type Timer = ReturnType<typeof setTimeout>;

export class StreamDeadlineController {
  private firstEventTimer: Timer | undefined;
  private idleTimer: Timer | undefined;
  private totalTimer: Timer | undefined;
  private disposed = false;
  private _expiredKind: StreamDeadlineKind | null = null;

  constructor(
    private readonly options: {
      profile: StreamRequestProfile;
      upstreamController: AbortController;
    },
  ) {
    if (options.profile === 'translation') {
      this.firstEventTimer = setTimeout(
        () => this.expire('first_event'),
        45_000,
      );
      this.totalTimer = setTimeout(() => this.expire('total'), 300_000);
    } else {
      this.totalTimer = setTimeout(() => this.expire('total'), 60_000);
    }
  }

  get expiredKind(): StreamDeadlineKind | null {
    return this._expiredKind;
  }

  markActivity(): void {
    if (
      this.disposed ||
      this._expiredKind !== null ||
      this.options.profile !== 'translation'
    ) {
      return;
    }
    this.clearTimer('firstEventTimer');
    this.clearTimer('idleTimer');
    this.idleTimer = setTimeout(() => this.expire('idle'), 60_000);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.clearTimers();
  }

  private expire(kind: StreamDeadlineKind): void {
    if (
      this.disposed ||
      this._expiredKind !== null ||
      this.options.upstreamController.signal.aborted
    ) {
      return;
    }
    this._expiredKind = kind;
    this.clearTimers();
    this.options.upstreamController.abort();
  }

  private clearTimers(): void {
    this.clearTimer('firstEventTimer');
    this.clearTimer('idleTimer');
    this.clearTimer('totalTimer');
  }

  private clearTimer(
    key: 'firstEventTimer' | 'idleTimer' | 'totalTimer',
  ): void {
    const timer = this[key];
    if (timer === undefined) return;
    clearTimeout(timer);
    this[key] = undefined;
  }
}
