import * as admin from "firebase-admin";
import {onCall, HttpsError} from "firebase-functions/v2/https";
import {onSchedule} from "firebase-functions/v2/scheduler";

admin.initializeApp();

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
 * Daily maintenance of 24-hour price-change figures.
 *
 * The `prices/{marketHashName}` collection stores the latest known
 * Steam Market price per item, written by the app whenever a user
 * fetches prices. Those docs carry `currentPrice` but no notion of
 * how the price has moved — so the app's price-change badge always
 * read 0.
 *
 * This scheduled function runs once a day and, for each price doc:
 *   1. Computes `priceChange24h` as the percent change between the
 *      current price and the baseline snapshotted on the previous run.
 *   2. Re-snapshots `previousPrice24h = currentPrice` so tomorrow's run
 *      compares against today.
 *
 * Because prices are only refreshed when the app fetches them, a
 * `currentPrice` that hasn't moved since the last snapshot yields a
 * 0% change — which is the honest answer ("no new price observed"),
 * not an error. Items with a missing or non-positive current/baseline
 * price are skipped to avoid divide-by-zero and bogus percentages.
 *
 * Requires the Blaze plan (scheduled functions use Cloud Scheduler).
 * At ~150 price docs this is ~150 reads + ~150 writes/day, comfortably
 * within the free allotment.
 */
export const updatePriceChanges = onSchedule(
  {schedule: "every day 00:00", timeZone: "Etc/UTC"},
  async () => {
    const db = admin.firestore();
    const snapshot = await db.collection("prices").get();

    if (snapshot.empty) {
      console.log("updatePriceChanges: no price docs to process");
      return;
    }

    let updated = 0;
    let skipped = 0;

    // Firestore batches cap at 500 ops; chunk to stay safe as the
    // collection grows.
    const CHUNK = 450;
    const docs = snapshot.docs;

    for (let i = 0; i < docs.length; i += CHUNK) {
      const batch = db.batch();
      const chunk = docs.slice(i, i + CHUNK);

      for (const doc of chunk) {
        const data = doc.data();
        const current = typeof data.currentPrice === "number" ?
          data.currentPrice : null;
        const baseline = typeof data.previousPrice24h === "number" ?
          data.previousPrice24h : null;

        if (current === null || current <= 0) {
          skipped++;
          continue;
        }

        const update: Record<string, unknown> = {
          previousPrice24h: current,
          priceChangeComputedAt: admin.firestore.FieldValue.serverTimestamp(),
        };

        // Only compute a change once we have a valid prior baseline.
        if (baseline !== null && baseline > 0) {
          const change = ((current - baseline) / baseline) * 100;
          // Round to one decimal to match the badge's display precision.
          update.priceChange24h = Math.round(change * 10) / 10;
        }

        batch.set(doc.ref, update, {merge: true});
        updated++;
      }

      await batch.commit();
    }

    console.log(
      `updatePriceChanges: updated ${updated}, skipped ${skipped} ` +
      `(of ${docs.length} price docs)`
    );
  }
);
