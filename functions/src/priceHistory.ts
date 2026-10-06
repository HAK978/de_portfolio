export interface PriceSample { at: number; price: number }
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/** Compare with a sample at/before each lookback, within two refresh intervals. */
export function updatePriceHistory(raw: unknown, current: number, now: number) {
  const samples: PriceSample[] = Array.isArray(raw) ? raw.filter(
    (s): s is PriceSample => s && Number.isFinite(s.at) &&
      Number.isFinite(s.price) && s.price > 0 && s.at <= now && s.at >= now - 31 * DAY,
  ) : [];
  samples.sort((a, b) => a.at - b.at);
  const change = (days: number): number | null => {
    const target = now - days * DAY;
    const baseline = [...samples].reverse().find((s) => s.at <= target);
    if (!baseline || target - baseline.at > 8 * HOUR) return null;
    return Math.round((current / baseline.price - 1) * 1000) / 10;
  };
  const changes = {
    priceChange24h: change(1),
    priceChange7d: change(7),
    priceChange30d: change(30),
  };
  // Keep the first observation in each hour, bounding the document to 745 entries.
  const byHour = new Map<number, PriceSample>();
  for (const sample of [...samples, {at: now, price: current}]) {
    const hour = Math.floor(sample.at / HOUR);
    if (!byHour.has(hour)) byHour.set(hour, sample);
  }
  return {...changes, priceHistory: [...byHour.values()]};
}
