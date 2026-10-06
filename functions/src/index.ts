import * as admin from "firebase-admin";
import {onCall, onRequest, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {defineSecret} from "firebase-functions/params";
import {LOGIN_TTL_MS, newSteamLogin, sessionKey, verifySteamAssertion} from "./steamAuth";

admin.initializeApp();

// CSFloat API key, stored in Google Secret Manager (set once via
// `firebase functions:secrets:set CSFLOAT_API_KEY`). Steam Market needs
// no key; CSFloat requires this in the Authorization header.
const csfloatApiKey = defineSecret("CSFLOAT_API_KEY");

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Parses a USD price string from the Steam Market (e.g. "$1,234.96")
 * into a number. Returns null for missing/zero/unparseable values.
 */
function parseUsdPrice(raw: string | undefined): number | null {
  if (!raw) return null;
  // Strip everything except digits and the decimal point ($ and the
  // thousands comma both go). USD format uses "." as the decimal sep.
  const cleaned = raw.replace(/[^0-9.]/g, "");
  const n = parseFloat(cleaned);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * Fetches the lowest Steam Market price for an item via priceoverview.
 * One 429-retry after a 5s wait. Returns dollars, or null if no listing.
 */
async function fetchSteamPrice(marketHashName: string): Promise<number | null> {
  const url = "https://steamcommunity.com/market/priceoverview/" +
    `?appid=730&currency=1&market_hash_name=${encodeURIComponent(marketHashName)}`;
  try {
    let res = await fetch(url);
    if (res.status === 429) {
      await sleep(5000);
      res = await fetch(url);
    }
    if (!res.ok) return null;
    const data = await res.json() as {
      success?: boolean; lowest_price?: string; median_price?: string;
    };
    if (data.success !== true) return null;
    return parseUsdPrice(data.lowest_price ?? data.median_price);
  } catch (e) {
    console.warn(`Steam price fetch failed for "${marketHashName}":`, e);
    return null;
  }
}

/**
 * Fetches the lowest CSFloat listing price (cents -> dollars). Honors
 * the x-ratelimit-reset header on a 429 with a single bounded retry.
 */
async function fetchCsfloatPrice(
  marketHashName: string,
  apiKey: string,
): Promise<number | null> {
  const url = "https://csfloat.com/api/v1/listings" +
    `?market_hash_name=${encodeURIComponent(marketHashName)}` +
    "&sort_by=lowest_price&type=buy_now&limit=1";
  const headers = {Authorization: apiKey};
  try {
    let res = await fetch(url, {headers});
    if (res.status === 429) {
      const reset = parseInt(res.headers.get("x-ratelimit-reset") ?? "0", 10);
      const waitMs = reset > 0 ?
        Math.min(Math.max(reset * 1000 - Date.now(), 2000), 120000) : 5000;
      await sleep(waitMs);
      res = await fetch(url, {headers});
    }
    if (!res.ok) return null;
    const data = await res.json() as
      {price?: number}[] | {data?: {price?: number}[]};
    const listings = Array.isArray(data) ? data : (data.data ?? []);
    if (listings.length === 0) return null;
    const cents = listings[0]?.price;
    return typeof cents === "number" && cents > 0 ? cents / 100 : null;
  } catch (e) {
    console.warn(`CSFloat price fetch failed for "${marketHashName}":`, e);
    return null;
  }
}

// The WebView intercepts this URL before loading it. A fallback page contains
// no assertion data or tokens and is safe if opened outside the app.
export const steamLoginReturn = onRequest({invoker: "public"}, (_req, res) => {
  res.set("Cache-Control", "no-store");
  res.set("Referrer-Policy", "no-referrer");
  res.status(200).send("Return to CS2 Portfolio to finish signing in.");
});

export const beginSteamLogin = onCall(
  {invoker: "public", enforceAppCheck: true},
  async () => {
    const project = process.env.GCLOUD_PROJECT;
    if (!project) throw new HttpsError("internal", "Missing project configuration");
    const login = newSteamLogin(
      `https://us-central1-${project}.cloudfunctions.net/steamLoginReturn`,
    );
    await admin.firestore().collection("steamLoginSessions").doc(sessionKey(login.sessionId)).set({
      returnTo: login.returnTo,
      expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + LOGIN_TTL_MS),
    });
    return login;
  },
);

// Legacy requests containing only a Steam ID are rejected. Identity comes only
// from the assertion verified directly with Steam, then bound to a one-use session.
export const createCustomToken = onCall(
  {invoker: "public", enforceAppCheck: true},
  async (request) => {
    let key: string;
    try {
      key = sessionKey(request.data?.sessionId);
    } catch {
      throw new HttpsError("invalid-argument", "Start a new Steam login");
    }
    const db = admin.firestore();
    const sessionRef = db.collection("steamLoginSessions").doc(key);
    const session = (await sessionRef.get()).data();
    if (!session || session.expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("unauthenticated", "Steam login expired. Please try again.");
    }
    let steamId: string;
    try {
      steamId = await verifySteamAssertion(request.data?.assertion, session.returnTo);
    } catch {
      // Never log assertions, session secrets, cookies or Firebase tokens.
      throw new HttpsError("unauthenticated", "Steam login could not be verified. Please try again.");
    }
    const token = await admin.auth().createCustomToken(steamId, {steamVerified: true});
    await db.runTransaction(async (transaction) => {
      const current = (await transaction.get(sessionRef)).data();
      if (!current || current.expiresAt.toMillis() <= Date.now()) {
        throw new HttpsError("unauthenticated", "Steam login already used or expired");
      }
      transaction.delete(sessionRef);
    });
    return {token, steamId};
  },
);

// How old each baseline may get before it's re-snapshotted. Decoupled
// from the 4h fetch cadence so each change figure stays a true delta
// over its window (a small buffer under the nominal period lets the
// roll land on a 4h run near the boundary).
const BASELINE_24H_MS = 23 * 60 * 60 * 1000;
const BASELINE_7D_MS = (7 * 24 - 2) * 60 * 60 * 1000;
const BASELINE_30D_MS = (30 * 24 - 2) * 60 * 60 * 1000;

function asNumber(v: unknown): number | null {
  return typeof v === "number" ? v : null;
}

/**
 * Computes a percent change against a stored baseline and decides
 * whether to roll (re-snapshot) that baseline. The change is computed
 * BEFORE rolling, so the roll run still reports the full-window delta.
 */
function rollBaseline(
  current: number,
  baseline: number | null,
  baselineAt: number | null,
  maxAgeMs: number,
  nowMs: number,
): {change: number | null; newBaseline: number; newBaselineAt: number} {
  let change: number | null = null;
  if (baseline !== null && baseline > 0) {
    change = Math.round(((current - baseline) / baseline) * 100 * 10) / 10;
  }
  const stale = baseline === null || baselineAt === null ||
    (nowMs - baselineAt) >= maxAgeMs;
  return {
    change,
    newBaseline: stale ? current : baseline,
    newBaselineAt: stale ? nowMs : baselineAt,
  };
}

/**
 * Server-side price refresh (every 4 hours) + 24-hour change tracking.
 *
 * The `prices/{marketHashName}` collection is the watch list — every
 * item the app has ever priced. Each run, for every doc:
 *   1. Fetches a fresh Steam Market price and CSFloat price (queried
 *      concurrently per item).
 *   2. Writes `currentPrice` / `csfloatPrice` on every run, so prices
 *      stay fresh to within ~4 hours.
 *   3. Computes `priceChange24h` against `previousPrice24h`, the daily
 *      baseline. The baseline is only re-snapshotted when it's ~24h old
 *      (tracked by `baselineTakenAt`), so the change stays a true
 *      day-over-day delta even though the fetch runs 6×/day.
 *
 * After the loop it stamps `meta/priceRefresh` with `lastRun` so the
 * app can show "prices updated at <time>" from the real server run.
 *
 * Pacing: items are processed serially with a ~2s gap to respect Steam
 * Market's rate limit; both source calls per item run in parallel. A
 * wall-clock guard stops before the 900s timeout — any unreached items
 * keep their existing prices and refresh on the next run.
 *
 * Requires the Blaze plan (Cloud Scheduler) and the CSFLOAT_API_KEY
 * secret.
 */
export const updatePriceChanges = onSchedule(
  {
    schedule: "every 4 hours",
    timeZone: "Etc/UTC",
    // ~200 items at ~2.9s each is ~575s; 900s leaves headroom so the
    // whole watch list refreshes in one run (no permanently-stale tail).
    timeoutSeconds: 900,
    memory: "256MiB",
    secrets: [csfloatApiKey],
  },
  async () => {
    const db = admin.firestore();
    const snapshot = await db.collection("prices").get();

    if (snapshot.empty) {
      console.log("updatePriceChanges: no price docs to process");
      return;
    }

    const apiKey = csfloatApiKey.value();
    const startMs = Date.now();
    // Safety net under the 900s timeout so in-flight writes finish.
    const TIME_BUDGET_MS = 850_000;

    let updated = 0;
    let steamOk = 0;
    let csfloatOk = 0;
    let rolled = 0;
    let skipped = 0;
    let unreached = 0;

    for (const doc of snapshot.docs) {
      if (Date.now() - startMs > TIME_BUDGET_MS) {
        unreached = snapshot.size - (updated + skipped);
        console.log(`updatePriceChanges: time budget hit, ${unreached} unreached`);
        break;
      }

      const data = doc.data();
      const name = typeof data.marketHashName === "string" ?
        data.marketHashName : null;
      if (!name) {
        skipped++;
        continue;
      }

      const [steamPrice, csfloatPrice] = await Promise.all([
        fetchSteamPrice(name),
        fetchCsfloatPrice(name, apiKey),
      ]);

      if (steamPrice === null && csfloatPrice === null) {
        skipped++;
        await sleep(2000);
        continue;
      }

      const update: Record<string, unknown> = {
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        priceChangeComputedAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      if (steamPrice !== null) {
        update.currentPrice = steamPrice;
        const nowMs = Date.now();

        // Maintain three independent baselines (24h / 7d / 30d). Each
        // computes its change against its current baseline, then rolls
        // only when that baseline has aged past its window. 7d/30d stay
        // unset (null) until enough time has passed for a real figure.
        const r24 = rollBaseline(steamPrice, asNumber(data.previousPrice24h),
          asNumber(data.baselineTakenAt), BASELINE_24H_MS, nowMs);
        const r7 = rollBaseline(steamPrice, asNumber(data.previousPrice7d),
          asNumber(data.baseline7dTakenAt), BASELINE_7D_MS, nowMs);
        const r30 = rollBaseline(steamPrice, asNumber(data.previousPrice30d),
          asNumber(data.baseline30dTakenAt), BASELINE_30D_MS, nowMs);

        if (r24.change !== null) update.priceChange24h = r24.change;
        if (r7.change !== null) update.priceChange7d = r7.change;
        if (r30.change !== null) update.priceChange30d = r30.change;

        update.previousPrice24h = r24.newBaseline;
        update.baselineTakenAt = r24.newBaselineAt;
        update.previousPrice7d = r7.newBaseline;
        update.baseline7dTakenAt = r7.newBaselineAt;
        update.previousPrice30d = r30.newBaseline;
        update.baseline30dTakenAt = r30.newBaselineAt;
        if (r24.newBaselineAt === nowMs) rolled++;
        steamOk++;
      }
      if (csfloatPrice !== null) {
        update.csfloatPrice = csfloatPrice;
        csfloatOk++;
      }

      await doc.ref.set(update, {merge: true});
      updated++;

      // Pace to respect Steam Market's rate limit.
      await sleep(2000);
    }

    // Stamp the run so the app can show a real "prices updated at" time.
    await db.collection("meta").doc("priceRefresh").set({
      lastRun: admin.firestore.FieldValue.serverTimestamp(),
      updated,
      steamOk,
      csfloatOk,
      skipped,
      unreached,
      total: snapshot.size,
    }, {merge: true});

    console.log(
      `updatePriceChanges: ${updated} updated ` +
      `(steam ${steamOk}, csfloat ${csfloatOk}, baselines rolled ${rolled}), ` +
      `${skipped} skipped, ${unreached} unreached of ${snapshot.size}`
    );
  }
);
