/**
 * Bulk price files published by the CS2 Trader project
 * (prices.csgotrader.app). One download per marketplace covers every CS2
 * item, replacing hundreds of rate-limited per-item lookups, and needs no
 * API key. The files refresh roughly every three hours. Casemove read its
 * prices from the same source for years.
 */

export const BULK_PRICE_BASE = "https://prices.csgotrader.app/latest";

export const APP_USER_AGENT =
  "CS2PortfolioManager/1.3 (+https://github.com/HAK978/de_portfolio)";

/**
 * A real file lists 30,000+ items. Anything far smaller is treated as a
 * broken or truncated download, so it can't wipe out prices.
 */
export const MIN_BULK_ITEMS = 10_000;

/**
 * Steam entries are average sale prices over these windows, newest first.
 * Rarely traded items often have no recent sales, so the first window with
 * a price wins (the same fallback Casemove uses).
 */
export const STEAM_WINDOWS = ["last_24h", "last_7d", "last_30d", "last_90d"] as const;
export type SteamWindow = typeof STEAM_WINDOWS[number];

export interface BulkFile {
  items: Record<string, unknown>;
  /** The file's Last-Modified header, i.e. when the source refreshed it. */
  updatedAt: string | null;
}

const positive = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;

/** The Steam price for one entry of steam.json, and which window it came from. */
export function pickSteamPrice(entry: unknown): {price: number; window: SteamWindow} | null {
  if (!entry || typeof entry !== "object") return null;
  const windows = entry as Record<string, unknown>;
  for (const window of STEAM_WINDOWS) {
    const price = positive(windows[window]);
    if (price !== null) return {price, window};
  }
  return null;
}

/** The lowest CSFloat listing for one entry of csfloat.json. */
export function pickCsfloatPrice(entry: unknown): number | null {
  if (!entry || typeof entry !== "object") return null;
  const listing = entry as {price?: unknown; starting_at?: {price?: unknown}};
  return positive(listing.price) ?? positive(listing.starting_at?.price);
}

/** Downloads one marketplace's file (e.g. "steam" or "csfloat"). */
export async function fetchBulkFile(
  marketplace: string,
  fetcher: typeof fetch = fetch,
): Promise<BulkFile> {
  const res = await fetcher(`${BULK_PRICE_BASE}/${marketplace}.json`, {
    headers: {"User-Agent": APP_USER_AGENT, "Accept": "application/json"},
    signal: AbortSignal.timeout(60_000),
  });
  if (!res.ok) throw new Error(`${marketplace}.json: HTTP ${res.status}`);

  const items = await res.json() as unknown;
  if (!items || typeof items !== "object" || Array.isArray(items)) {
    throw new Error(`${marketplace}.json: unexpected format`);
  }
  const count = Object.keys(items).length;
  if (count < MIN_BULK_ITEMS) {
    throw new Error(`${marketplace}.json: only ${count} items, looks truncated`);
  }
  return {items: items as Record<string, unknown>, updatedAt: res.headers.get("last-modified")};
}

/** Firestore document IDs can't contain "/". Matches the app's own mapping. */
export const priceDocId = (marketHashName: string): string =>
  marketHashName.replace(/\//g, "_");
