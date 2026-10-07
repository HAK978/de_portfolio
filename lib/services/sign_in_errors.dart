import 'package:cloud_functions/cloud_functions.dart';

/// Turns a failure from the server's `beginSteamLogin` call into a message
/// that says what actually went wrong. A single "check your connection"
/// for everything hid a server-side App Check rejection behind a
/// connectivity message, which made it hard to diagnose.
String signInStartErrorMessage(Object error) {
  if (error is FirebaseFunctionsException) {
    switch (error.code) {
      // The server only talks to the genuine app. HTTP 401 / 403 here means
      // App Check (Play Integrity) rejected this install.
      case 'unauthenticated':
      case 'permission-denied':
      case 'failed-precondition':
        return 'The server couldn\'t verify this install (App Check). '
            'Install the official release APK from GitHub and try again.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Couldn\'t reach the server. Check your connection and try again.';
    }
  }
  return 'Could not start Steam sign-in. Try again in a moment.';
}
