export function toInt(v: unknown, dflt = 0): number {
  if (typeof v === 'number') return Math.trunc(v);
  if (typeof v === 'string') {
    const n = parseInt(v, 10);
    return isNaN(n) ? dflt : n;
  }
  return dflt;
}
