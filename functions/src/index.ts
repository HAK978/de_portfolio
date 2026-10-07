import * as admin from "firebase-admin";
import {onCall, onRequest, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {defineSecret} from "firebase-functions/params";
import {LOGIN_TTL_MS, newSteamLogin, sessionKey, verifySteamAssertion} from "./steamAuth";
import {updatePriceHistory} from "./priceHistory";
import {orderAfterCursor} from "./cursor";
import {BlockBreaker, fetchSteamPrice} from "./steamMarket";

admin.initializeApp();

// CSFloat API key, stored in Google Secret Manager (set once via
// `firebase functions:secrets:set CSFLOAT_API_KEY`). Steam Market needs
// no key; CSFloat requires this in the Authorization header.
const csfloatApiKey = defineSecret("CSFLOAT_API_KEY");

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

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
    let res = await fetch(url, {headers, signal: AbortSignal.timeout(15_000)});
    if (res.status === 429) {
      const reset = parseInt(res.headers.get("x-ratelimit-reset") ?? "0", 10);
      const waitMs = reset > 0 ?
        Math.min(Math.max(reset * 1000 - Date.now(), 2000), 10_000) : 5000;
      await sleep(waitMs);
      res = await fetch(url, {headers, signal: AbortSignal.timeout(15_000)});
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

/**
 * Server-side price refresh, every 4 hours.
 *
 * `prices/{id}` is the watch list (every item the app has priced) and
 * the small document the app downloads: current Steam + CSFloat prices
 * and the 24h / 7d / 30d changes. For each document this:
 *   1. Fetches Steam Market and CSFloat prices concurrently.
 *   2. Appends the Steam price to `priceHistory/{id}`, a server-only
 *      document of hourly samples (31 days max), and derives the changes
 *      from it (see priceHistory.ts). History lives in its own collection
 *      so the app's full read of `prices` stays small.
 *   3. Stamps `meta/priceRefresh` with the run time, counts and a cursor.
 *
 * Items are processed serially with a ~2s gap to respect Steam Market's
 * rate limit. A wall-clock budget stops the run before the timeout, and
 * the next run resumes after the last attempted item (see cursor.ts).
 *
 * Requires the Blaze plan (Cloud Scheduler) and the CSFLOAT_API_KEY secret.
 */
export const updatePriceChanges = onSchedule(
  {
    schedule: "every 4 hours",
    timeZone: "Etc/UTC",
    // ~200 items at ~2.9s each is ~575s; 900s leaves headroom so the
    // whole watch list usually refreshes in one run.
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
    const TIME_BUDGET_MS = 800_000;

    let updated = 0;
    let steamOk = 0;
    let csfloatOk = 0;
    let skipped = 0;
    let unreached = 0;
    // What Steam did this run, so a block shows up in the stats instead of
    // silently producing no prices.
    let steamBlocked = 0;
    let steamSkipped = 0;
    const steamBreaker = new BlockBreaker();

    const metaRef = db.collection("meta").doc("priceRefresh");
    const cursor = (await metaRef.get()).data()?.cursor;
    const docsById = new Map(snapshot.docs.map((doc) => [doc.id, doc]));
    const ordered = orderAfterCursor([...docsById.keys()], cursor);
    let lastAttempted: string | null = typeof cursor === "string" ? cursor : null;

    for (const id of ordered) {
      if (Date.now() - startMs > TIME_BUDGET_MS) {
        unreached = snapshot.size - (updated + skipped);
        console.log(`updatePriceChanges: time budget hit, ${unreached} unreached`);
        break;
      }

      lastAttempted = id;
      const doc = docsById.get(id)!;
      const data = doc.data();
      const name = typeof data.marketHashName === "string" ?
        data.marketHashName : null;
      if (!name) {
        skipped++;
        continue;
      }

      const attemptSteam = steamBreaker.shouldAttempt();
      if (!attemptSteam) steamSkipped++;
      const [steam, csfloatPrice] = await Promise.all([
        attemptSteam ? fetchSteamPrice(name) : Promise.resolve(null),
        fetchCsfloatPrice(name, apiKey),
      ]);
      if (steam) {
        steamBreaker.record(steam.outcome);
        if (steam.outcome === "blocked") steamBlocked++;
      }
      const steamPrice = steam?.price ?? null;

      if (steamPrice === null && csfloatPrice === null) {
        skipped++;
        await sleep(2000);
        continue;
      }

      const {FieldValue} = admin.firestore;
      const update: Record<string, unknown> = {
        lastUpdated: FieldValue.serverTimestamp(),
        priceChangeComputedAt: FieldValue.serverTimestamp(),
      };
      const batch = db.batch();

      if (steamPrice !== null) {
        const historyRef = db.collection("priceHistory").doc(id);
        const history = (await historyRef.get()).data();
        const result = updatePriceHistory(history?.samples, steamPrice, Date.now());

        update.currentPrice = steamPrice;
        update.priceChange24h = result.priceChange24h;
        update.priceChange7d = result.priceChange7d;
        update.priceChange30d = result.priceChange30d;
        update.priceHistoryVersion = 2;
        // Fields from the old rolling-baseline scheme, no longer used.
        for (const field of ["previousPrice24h", "baselineTakenAt",
          "previousPrice7d", "baseline7dTakenAt",
          "previousPrice30d", "baseline30dTakenAt"]) {
          update[field] = FieldValue.delete();
        }
        batch.set(historyRef, {
          marketHashName: name,
          samples: result.priceHistory,
          updatedAt: FieldValue.serverTimestamp(),
        });
        steamOk++;
      }
      if (csfloatPrice !== null) {
        update.csfloatPrice = csfloatPrice;
        csfloatOk++;
      }

      batch.set(doc.ref, update, {merge: true});
      await batch.commit();
      updated++;

      // Pace to respect Steam Market's rate limit.
      await sleep(2000);
    }

    // Stamp the run so the app can show a real "prices updated at" time.
    await metaRef.set({
      lastRun: admin.firestore.FieldValue.serverTimestamp(),
      updated,
      steamOk,
      csfloatOk,
      skipped,
      unreached,
      steamBlocked,
      steamSkipped,
      total: snapshot.size,
      cursor: lastAttempted,
    }, {merge: true});

    console.log(
      `updatePriceChanges: ${updated} updated ` +
      `(steam ${steamOk}, csfloat ${csfloatOk}), ` +
      `steam refused ${steamBlocked}, steam skipped ${steamSkipped}, ` +
      `${skipped} skipped, ${unreached} unreached of ${snapshot.size}`
    );
  }
);
