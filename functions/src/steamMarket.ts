/**
 * Steam Market price lookups for the scheduled refresh.
 *
 * Steam's priceoverview endpoint answers HTTP 429 to requests that carry
 * Node's default User-Agent (the same request from the same IP works with
 * curl, or with any User-Agent that identifies the app), so lookups
 * identify themselves. Separately, if Steam refuses many requests in a
 * row, the run stops asking for a while instead of spending its whole
 * time budget waiting out 429s.
 */

export const STEAM_USER_AGENT =
  "CS2PortfolioManager/1.3 (+https://github.com/HAK978/de_portfolio)";

/**
 * What happened to one lookup:
 *  - ok:         a price was returned
 *  - no_listing: Steam answered but has no price for the item
 *  - blocked:    Steam refused (429 after a retry, or 403)
 *  - error:      network error, timeout or another HTTP failure
 */
export type SteamOutcome = "ok" | "no_listing" | "blocked" | "error";

export interface SteamResult {
  price: number | null;
  outcome: SteamOutcome;
}

export interface SteamDeps {
  fetcher?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Parses a USD price string from the Steam Market (e.g. "$1,234.96")
 * into a number. Returns null for missing/zero/unparseable values.
 */
export function parseUsdPrice(raw: string | undefined): number | null {
  if (!raw) return null;
  // Strip everything except digits and the decimal point ($ and the
  // thousands comma both go). USD format uses "." as the decimal sep.
  const cleaned = raw.replace(/[^0-9.]/g, "");
  const n = parseFloat(cleaned);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * Fetches the lowest Steam Market price for an item via priceoverview.
 * One retry after 5s on HTTP 429.
 */
export async function fetchSteamPrice(
  marketHashName: string,
  deps: SteamDeps = {},
): Promise<SteamResult> {
  const fetcher = deps.fetcher ?? fetch;
  const sleep = deps.sleep ?? defaultSleep;
  const url = "https://steamcommunity.com/market/priceoverview/" +
    `?appid=730&currency=1&market_hash_name=${encodeURIComponent(marketHashName)}`;
  const request = () => fetcher(url, {
    headers: {"User-Agent": STEAM_USER_AGENT, "Accept": "application/json"},
    signal: AbortSignal.timeout(15_000),
  });

  try {
    let res = await request();
    if (res.status === 429) {
      await sleep(5000);
      res = await request();
    }
    if (res.status === 429 || res.status === 403) {
      return {price: null, outcome: "blocked"};
    }
    if (!res.ok) return {price: null, outcome: "error"};

    const data = await res.json() as {
      success?: boolean; lowest_price?: string; median_price?: string;
    };
    if (data.success !== true) return {price: null, outcome: "no_listing"};
    const price = parseUsdPrice(data.lowest_price ?? data.median_price);
    return price === null ?
      {price: null, outcome: "no_listing"} : {price, outcome: "ok"};
  } catch (e) {
    console.warn(`Steam price fetch failed for "${marketHashName}":`, e);
    return {price: null, outcome: "error"};
  }
}

/**
 * Stops sending Steam requests after [threshold] refusals in a row, then
 * lets one probe request through every [probeEvery] skipped lookups. A
 * successful probe closes the breaker again. Only refusals count:
 * ordinary errors and missing listings never open it.
 */
export class BlockBreaker {
  private consecutiveBlocked = 0;
  private open = false;
  private skippedSinceProbe = 0;

  constructor(
    private readonly threshold = 10,
    private readonly probeEvery = 20,
  ) {}

  get isOpen(): boolean {
    return this.open;
  }

  /** Whether the next lookup should actually call Steam. */
  shouldAttempt(): boolean {
    if (!this.open) return true;
    if (this.skippedSinceProbe >= this.probeEvery) {
      this.skippedSinceProbe = 0;
      return true;
    }
    this.skippedSinceProbe++;
    return false;
  }

  /** Report the outcome of a lookup that was actually sent. */
  record(outcome: SteamOutcome): void {
    if (outcome === "blocked") {
      this.consecutiveBlocked++;
      if (this.consecutiveBlocked >= this.threshold) this.open = true;
    } else if (outcome === "ok" || outcome === "no_listing") {
      this.consecutiveBlocked = 0;
      this.open = false;
    }
  }
}
