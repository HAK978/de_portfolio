import * as admin from "firebase-admin";
import {onCall, HttpsError} from "firebase-functions/v2/https";

admin.initializeApp();

/**
 * Creates a Firebase custom auth token for a Steam user.
 *
 * Called by the Flutter app after the user logs in via Steam OpenID.
 * The Steam ID becomes the Firebase UID, so Firestore security rules
 * can enforce document ownership with request.auth.uid == steamId.
 */
export const createCustomToken = onCall({invoker: "public"}, async (request) => {
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
});
