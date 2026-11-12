import {initializeApp} from "firebase-admin/app";
import {getAuth} from "firebase-admin/auth";
import {FieldValue, Firestore, Timestamp, getFirestore} from "firebase-admin/firestore";
import {onCall, onRequest, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {LOGIN_TTL_MS, newSteamLogin, sessionKey, verifySteamAssertion} from "./steamAuth";
import {updatePriceHistory} from "./priceHistory";
import {fetchBulkFile, pickCsfloatPrice, pickSteamPrice, priceDocId} from "./bulkPrices";

initializeApp();

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
    await getFirestore().collection("steamLoginSessions").doc(sessionKey(login.sessionId)).set({
      returnTo: login.returnTo,
      expiresAt: Timestamp.fromMillis(Date.now() + LOGIN_TTL_MS),
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
    const db = getFirestore();
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
    const token = await getAuth().createCustomToken(steamId, {steamVerified: true});
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

/** History samples made from a different source are discarded, not mixed in. */
const HISTORY_SOURCE = "csgotrader-steam";

/**
 * Server-side price refresh, every 4 hours.
 *
 * Prices come from CS2 Trader's bulk files (see bulkPrices.ts): two
 * downloads cover every CS2 item. The watch list is every item already in
 * `prices` plus everything in users' synced inventories and storage units
 * (see loadWatchList), so a new user's items get priced on the next run.
 * For each item this:
 *   1. Picks the Steam price (most recent average available) and the lowest
 *      CSFloat listing.
 *   2. Appends the Steam price to `priceHistory/{id}` (server-only, hourly
 *      samples, 31 days) and derives the 24h / 7d / 30d changes from it.
 *   3. Writes prices and changes to `prices/{id}`, which the app reads.
 * Finally it stamps `meta/priceRefresh` with the run time and counts.
 */
export const updatePriceChanges = onSchedule(
  {
    schedule: "every 4 hours",
    timeZone: "Etc/UTC",
    timeoutSeconds: 300,
    // The two files parse to a few tens of MB of objects.
    memory: "512MiB",
  },
  async () => {
    const db = getFirestore();

    // Steam prices drive the history and changes, so a failed Steam download
    // aborts the run; a failed CSFloat download only skips CSFloat prices.
    const steam = await fetchBulkFile("steam");
    const csfloat = await fetchBulkFile("csfloat").catch((e) => {
      console.warn("updatePriceChanges: CSFloat file unavailable:", e);
      return null;
    });

    const watchList = await loadWatchList(db);
    const ids = [...watchList.keys()];
    const now = Date.now();
    let steamPriced = 0;
    let csfloatPriced = 0;
    let missing = 0;

    // Two writes per item; stay well under Firestore's 500-write batch limit.
    for (let i = 0; i < ids.length; i += 200) {
      const chunk = ids.slice(i, i + 200);
      const histories = await db.getAll(
        ...chunk.map((id) => db.collection("priceHistory").doc(id)));
      const batch = db.batch();

      chunk.forEach((id, index) => {
        const name = watchList.get(id)!;
        const steamPrice = pickSteamPrice(steam.items[name]);
        const csfloatPrice = csfloat ? pickCsfloatPrice(csfloat.items[name]) : null;
        if (!steamPrice && csfloatPrice === null) {
          missing++;
          return;
        }

        const update: Record<string, unknown> = {
          marketHashName: name,
          lastUpdated: FieldValue.serverTimestamp(),
        };
        if (steamPrice) {
          const history = histories[index].data();
          const samples = history?.source === HISTORY_SOURCE ? history.samples : [];
          const result = updatePriceHistory(samples, steamPrice.price, now);
          Object.assign(update, {
            currentPrice: steamPrice.price,
            steamPriceWindow: steamPrice.window,
            priceChange24h: result.priceChange24h,
            priceChange7d: result.priceChange7d,
            priceChange30d: result.priceChange30d,
            priceHistoryVersion: 2,
            priceChangeComputedAt: FieldValue.serverTimestamp(),
          });
          batch.set(histories[index].ref, {
            marketHashName: name,
            source: HISTORY_SOURCE,
            samples: result.priceHistory,
            updatedAt: FieldValue.serverTimestamp(),
          });
          steamPriced++;
        }
        if (csfloatPrice !== null) {
          update.csfloatPrice = csfloatPrice;
          csfloatPriced++;
        }
        batch.set(db.collection("prices").doc(id), update, {merge: true});
      });

      await batch.commit();
    }

    // Overwrite (not merge) so stats from the old per-item job disappear.
    await db.collection("meta").doc("priceRefresh").set({
      lastRun: FieldValue.serverTimestamp(),
      source: "csgotrader",
      items: ids.length,
      steamPriced,
      csfloatPriced,
      missing,
      steamUpdatedAt: steam.updatedAt,
      csfloatUpdatedAt: csfloat?.updatedAt ?? null,
    });

    console.log(
      `updatePriceChanges: ${ids.length} items, steam ${steamPriced}, ` +
      `csfloat ${csfloatPriced}, ${missing} missing ` +
      `(source updated ${steam.updatedAt})`
    );
  }
);

/** Same cap as firestore.rules, enforced again in case a document predates it. */
const MAX_STORAGE_NAMES_PER_USER = 5000;

/**
 * Item names to price, keyed by price document ID: every existing price
 * document, every item in any user's synced inventory, and the item names
 * in each user's storage units (`users/{steamId}.storageItemNames`).
 */
async function loadWatchList(
  db: Firestore,
): Promise<Map<string, string>> {
  const watchList = new Map<string, string>();
  const add = (name: unknown) => {
    if (typeof name === "string" && name.length > 0) watchList.set(priceDocId(name), name);
  };

  const prices = await db.collection("prices").select("marketHashName").get();
  prices.docs.forEach((doc) => add(doc.get("marketHashName")));

  for (const user of await db.collection("inventories").listDocuments()) {
    const items = await user.collection("items").select("marketHashName").get();
    items.docs.forEach((doc) => add(doc.get("marketHashName")));
  }

  const users = await db.collection("users").select("storageItemNames").get();
  for (const user of users.docs) {
    const names = user.get("storageItemNames");
    if (Array.isArray(names)) names.slice(0, MAX_STORAGE_NAMES_PER_USER).forEach(add);
  }
  return watchList;
}
