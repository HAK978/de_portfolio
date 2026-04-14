import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'background/price_refresh_task.dart';
import 'firebase_options.dart';
import 'theme/app_theme.dart';

/// Returns the duration until the next 6-hour slot: 12 AM, 6 AM, 12 PM, 6 PM.
Duration _delayUntilNextSlot() {
  final now = DateTime.now();
  for (final hour in [0, 6, 12, 18]) {
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
  WakelockPlus.enable();

  // Register the 6-hour background price refresh
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'cs2-price-refresh',
    'priceRefreshTask',
    frequency: const Duration(hours: 6),
    initialDelay: _delayUntilNextSlot(),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );

  // Initialize Firebase — wrapped in try/catch so the app works
  // even if Firebase isn't configured yet. Once you run
  // `flutterfire configure`, this will connect to your project.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Firebase initialized');
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

class CS2PortfolioApp extends StatelessWidget {
  const CS2PortfolioApp({super.key});

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
