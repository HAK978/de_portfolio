import * as admin from "firebase-admin";
import {onCall, HttpsError} from "firebase-functions/v2/https";

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
