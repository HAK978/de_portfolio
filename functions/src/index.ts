import * as admin from "firebase-admin";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {defineSecret} from "firebase-functions/params";

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

/**
 * Creates a Firebase custom auth token for a Steam user.
 *
 * Called by the Flutter app after the user logs in via Steam OpenID.
 * The Steam ID becomes the Firebase UID, so Firestore security rules
 * can enforce document ownership with request.auth.uid == steamId.
 *
 * Security: `enforceAppCheck: true` rejects calls from anything that
 * isn't a verified install of our app (Play Integrity / DeviceCheck
 * attestation). Without it the function is a wide-open auth bypass —
 * any unauthenticated client can request a Firebase token for any
 * 17-digit Steam ID, including the owner's (which is publicly
 * visible from any Steam profile URL).
 *
 * App Check doesn't stop a *compromised* app instance from claiming
 * any Steam ID, but it raises the bar from "anyone with curl" to
 * "an attacker who can ship a tampered build". For single-tenant
 * deployment that's the right tier of protection.
 */
export const createCustomToken = onCall(
  {invoker: "public", enforceAppCheck: true},
  async (request) => {
    const steamId = request.data?.steamId;

    // Validate Steam ID format: must be a 17-digit number
    if (!steamId || typeof steamId !== "string" || !/^\d{17}$/.test(steamId)) {
      throw new HttpsError(
        "invalid-argument",
        "steamId must be a 17-digit number"
      );
    }

    try {
      console.log(`Creating custom token for Steam ID: ${steamId}`);
      const token = await admin.auth().createCustomToken(steamId);
      console.log("Custom token created successfully");
      return {token};
    } catch (error) {
      console.error("Error creating custom token:", error);
      throw new HttpsError("internal", "Failed to create auth token");
    }
  }
);

/**
 * Daily server-side price refresh + 24-hour change computation.
 *
 * The `prices/{marketHashName}` collection is the watch list — every
 * item the app has ever priced. This scheduled function runs once a
 * day and, for each doc:
 *   1. Fetches a fresh Steam Market price and CSFloat price (the two
 *      sources are queried concurrently per item).
 *   2. Writes `currentPrice` / `csfloatPrice`.
 *   3. Computes `priceChange24h` as the percent change between the new
 *      Steam price and the baseline snapshotted on the previous run,
 *      then re-snapshots `previousPrice24h` to today's price.
 *
 * Centralizing the fetch here (instead of relying on the app to fetch
 * whenever it happens to be opened) gives a regular daily cadence, so
 * the 24h change is a true day-over-day delta. The app still keeps its
 * own manual fetch as a fallback and reads these values on open.
 *
 * Pacing: items are processed serially with a ~2s gap to respect Steam
 * Market's rate limit; both source calls per item run in parallel. A
 * wall-clock guard stops before the 540s timeout — any unreached items
 * keep their existing prices and refresh on the next run.
 *
 * Requires the Blaze plan (Cloud Scheduler) and the CSFLOAT_API_KEY
 * secret. ~200 items is ~200 reads + ~200 writes/day, within free tier.
 */
export const updatePriceChanges = onSchedule(
  {
    schedule: "every day 00:00",
    timeZone: "Etc/UTC",
    timeoutSeconds: 540,
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
    // Leave headroom under the 540s timeout so in-flight writes finish.
    const TIME_BUDGET_MS = 500_000;

    let updated = 0;
    let steamOk = 0;
    let csfloatOk = 0;
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
        const baseline = typeof data.previousPrice24h === "number" ?
          data.previousPrice24h : null;
        update.currentPrice = steamPrice;
        update.previousPrice24h = steamPrice; // baseline for tomorrow
        if (baseline !== null && baseline > 0) {
          const change = ((steamPrice - baseline) / baseline) * 100;
          update.priceChange24h = Math.round(change * 10) / 10;
        }
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

    console.log(
      `updatePriceChanges: ${updated} updated ` +
      `(steam ${steamOk}, csfloat ${csfloatOk}), ${skipped} skipped, ` +
      `${unreached} unreached of ${snapshot.size}`
    );
  }
);
