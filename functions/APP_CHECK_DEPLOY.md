# Firebase App Check + createCustomToken hardening

The `createCustomToken` Cloud Function used to accept any 17-digit
Steam ID without verifying the caller. Anyone who knew your public
Steam ID could call the function and get a Firebase token signed in
as you, then read/write your inventory and prices.

App Check fixes the practical attacker case by rejecting calls from
anything that isn't a verified install of the Android app (Play
Integrity attestation). The code change is already in:
- `functions/src/index.ts` — `enforceAppCheck: true` on the callable
- `lib/main.dart` — `FirebaseAppCheck.instance.activate(...)` after Firebase init
- `pubspec.yaml` — `firebase_app_check` dependency

You still need to do **two manual steps** before deploying:

1. Enable App Check in Firebase Console + register the Play Integrity provider
2. Deploy the updated Cloud Function

## 1. Firebase Console

1. Go to https://console.firebase.google.com/project/cs2-portfolio/appcheck
2. Click **Get started** if it's the first time
3. Find your Android app in the apps list (com.deportfolio.de_portfolio
   or similar — match the `applicationId` in `android/app/build.gradle.kts`)
4. Click the row → choose **Play Integrity** as the provider
5. You'll need the SHA-256 cert fingerprint of your release signing key:
   ```bash
   # Run from project root
   cd android
   ./gradlew signingReport
   # Look for the SHA-256 line under "Variant: release"
   ```
   Paste it into the Firebase Console.
6. Save.

### Debug token (for `flutter run` dev builds)

`flutter run` builds aren't signed with the release key, so they fail
Play Integrity. The code uses `AndroidDebugProvider` in debug mode,
which prints a debug token to logcat on first launch.

After your next debug run:

```
adb logcat | grep -i "DebugAppCheckProvider"
```

Look for a line like:
```
Enter this debug secret into the allow list in the Firebase Console:
abc12345-6789-...
```

In the Firebase Console:
- App Check → Apps → your Android app → ⋮ → **Manage debug tokens**
- Add the token, give it a name (e.g. "S24 dev").

Without this step, debug builds will get rejected by the Cloud
Function with "App Check failed" errors.

## 2. Deploy the Cloud Function

```bash
firebase deploy --only functions
```

Watch for `Function URL (createCustomToken[us-central1]): https://...`
indicating success. The function now rejects any caller without a
valid App Check token.

## Verifying

After deploy + a fresh `flutter run` with the debug token registered:

- Sign in with Steam in the app should still work end-to-end
- Cloud Function logs (`firebase functions:log`) should show
  `Creating custom token for Steam ID: ...` for legit calls
- Try `curl` against the function URL with a fake `steamId` — should
  get a 401 (App Check rejection) instead of a token. That's the
  proof the bypass is closed.

## Limitations

App Check raises the bar from "anyone with curl" to "an attacker
who can ship a tampered build of your app". For single-tenant
deployment (only you running the app) that's the right tier.

A more thorough fix would verify a Steam OpenID claim server-side
(canonical, but ~4 hr of work and changes the WebView flow). App
Check is the simplest meaningful improvement.
