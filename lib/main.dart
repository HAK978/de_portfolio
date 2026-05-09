import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'background/price_refresh_task.dart';
import 'firebase_options.dart';
import 'theme/app_theme.dart';

/// Returns the duration until the next 3-hour slot: 12 AM, 3, 6, 9, 12 PM, 3, 6, 9.
Duration _delayUntilNextSlot() {
  final now = DateTime.now();
  for (final hour in [0, 3, 6, 9, 12, 15, 18, 21]) {
    final slot = DateTime(now.year, now.month, now.day, hour);
    if (slot.isAfter(now)) return slot.difference(now);
  }
  // All slots today have passed — next is midnight tomorrow
  return DateTime(now.year, now.month, now.day + 1).difference(now);
}

/// Called by WorkManager in a background isolate — must be top-level.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    return runPriceRefreshBackground();
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Wakelock is now scoped to active price fetches (see CS2PortfolioApp
  // below) instead of staying on for the whole app session, which was
  // burning battery while the user just browsed.

  // Register the 3-hour background price refresh
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'cs2-price-refresh',
    'priceRefreshTask',
    frequency: const Duration(hours: 3),
    initialDelay: _delayUntilNextSlot(),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );

  // Initialize Firebase — wrapped in try/catch so the app works
  // even if Firebase isn't configured yet. Once you run
  // `flutterfire configure`, this will connect to your project.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Firebase initialized');
    // Activate App Check before any callable function or Firestore
    // request fires. Play Integrity attests that this is a real
    // install of our app; createCustomToken (and any future
    // enforceAppCheck-flagged endpoints) reject calls without a
    // valid attestation token.
    //
    // In debug builds we use the Debug provider so emulator runs
    // still work — register the printed debug token in the Firebase
    // Console > App Check > Apps > Manage debug tokens.
    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
        providerApple: kDebugMode
            ? const AppleDebugProvider()
            : const AppleDeviceCheckProvider(),
      );
      debugPrint('App Check activated');
    } catch (e) {
      debugPrint('App Check activation failed: $e');
    }
  } catch (e) {
    debugPrint('Firebase not configured yet, running in offline mode: $e');
  }

  runApp(
    // ProviderScope is required at the root of every Riverpod app.
    // It stores the state of all providers. Think of it as the
    // "container" that holds your entire app state tree.
    const ProviderScope(child: CS2PortfolioApp()),
  );
}

class CS2PortfolioApp extends ConsumerStatefulWidget {
  const CS2PortfolioApp({super.key});

  @override
  ConsumerState<CS2PortfolioApp> createState() => _CS2PortfolioAppState();
}

class _CS2PortfolioAppState extends ConsumerState<CS2PortfolioApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // App is foreground at startup — engage wakelock immediately so
    // the very first session matches the "screen stays on while
    // app is open" expectation.
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground-aware: keep the screen on while you're actively
    // using the app, release the wakelock the moment you task-switch
    // or lock the phone so the OS can sleep normally. Avoids the
    // "always on whether you're using it or not" battery drain of
    // the original startup-only Enable() call.
    switch (state) {
      case AppLifecycleState.resumed:
        WakelockPlus.enable();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        WakelockPlus.disable();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CS2 Portfolio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: goRouter,
    );
  }
}
