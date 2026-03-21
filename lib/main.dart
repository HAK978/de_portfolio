import 'dart:developer' as dev;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();

  // Initialize Firebase — wrapped in try/catch so the app works
  // even if Firebase isn't configured yet. Once you run
  // `flutterfire configure`, this will connect to your project.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    dev.log('Firebase initialized');
  } catch (e) {
    dev.log('Firebase not configured yet, running in offline mode: $e');
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
