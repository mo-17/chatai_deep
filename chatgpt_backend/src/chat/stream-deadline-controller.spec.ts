import { StreamDeadlineController } from './stream-deadline-controller';

describe('StreamDeadlineController', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('expires a translation stream with no first bytes at 45 seconds', () => {
    const upstream = new AbortController();
    const deadlines = new StreamDeadlineController({
      profile: 'translation',
      upstreamController: upstream,
    });

    jest.advanceTimersByTime(44_999);
    expect(upstream.signal.aborted).toBe(false);

    jest.advanceTimersByTime(1);
    expect(upstream.signal.aborted).toBe(true);
    expect(deadlines.expiredKind).toBe('first_event');

    deadlines.dispose();
  });

  it('resets the translation idle deadline on every upstream byte activity', () => {
    const upstream = new AbortController();
    const deadlines = new StreamDeadlineController({
      profile: 'translation',
      upstreamController: upstream,
    });

    deadlines.markActivity();
    jest.advanceTimersByTime(59_999);
    expect(upstream.signal.aborted).toBe(false);

    deadlines.markActivity();
    jest.advanceTimersByTime(59_999);
    expect(upstream.signal.aborted).toBe(false);

    jest.advanceTimersByTime(1);
    expect(upstream.signal.aborted).toBe(true);
    expect(deadlines.expiredKind).toBe('idle');

    deadlines.dispose();
  });

  it('keeps the translation total deadline fixed at 300 seconds', () => {
    const upstream = new AbortController();
    const deadlines = new StreamDeadlineController({
      profile: 'translation',
      upstreamController: upstream,
    });

    deadlines.markActivity();
    for (let elapsed = 0; elapsed < 295_000; elapsed += 59_000) {
      jest.advanceTimersByTime(59_000);
      deadlines.markActivity();
    }
    jest.advanceTimersByTime(4_999);
    expect(upstream.signal.aborted).toBe(false);

    jest.advanceTimersByTime(1);
    expect(upstream.signal.aborted).toBe(true);
    expect(deadlines.expiredKind).toBe('total');

    deadlines.dispose();
  });

  it('preserves the standard profile total deadline at 60 seconds', () => {
    const upstream = new AbortController();
    const deadlines = new StreamDeadlineController({
      profile: 'standard',
      upstreamController: upstream,
    });

    jest.advanceTimersByTime(30_000);
    deadlines.markActivity();
    jest.advanceTimersByTime(29_999);
    expect(upstream.signal.aborted).toBe(false);

    jest.advanceTimersByTime(1);
    expect(upstream.signal.aborted).toBe(true);
    expect(deadlines.expiredKind).toBe('total');

    deadlines.dispose();
  });

  it('clears every owned timer when disposed', () => {
    const upstream = new AbortController();
    const deadlines = new StreamDeadlineController({
      profile: 'translation',
      upstreamController: upstream,
    });
    deadlines.markActivity();

    deadlines.dispose();
    jest.advanceTimersByTime(300_000);

    expect(jest.getTimerCount()).toBe(0);
    expect(upstream.signal.aborted).toBe(false);
    expect(deadlines.expiredKind).toBeNull();
  });
});
