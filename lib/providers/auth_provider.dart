import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/firestore_service.dart';

/// Provides the FirestoreService instance.
final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  return FirestoreService();
});

/// Auth state — tracks whether user is logged in via Firebase.
class AuthState {
  final bool isLoggedIn;
  final String? steamId;
  final String? displayName;
  final String? avatarUrl;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.isLoggedIn = false,
    this.steamId,
    this.displayName,
    this.avatarUrl,
    this.isLoading = false,
    this.error,
  });

  AuthState copyWith({
    bool? isLoggedIn,
    String? steamId,
    String? displayName,
    String? avatarUrl,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      steamId: steamId ?? this.steamId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    _listenToAuthChanges();
    return const AuthState();
  }

  void _listenToAuthChanges() {
    try {
      FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user != null) {
          debugPrint('Firebase auth: signed in as ${user.uid}');
          state = state.copyWith(
            isLoggedIn: true,
            steamId: user.uid,
            displayName: user.displayName,
            isLoading: false,
          );
        } else {
          debugPrint('Firebase auth: signed out');
          state = const AuthState();
        }
      });
    } catch (e) {
      debugPrint('Firebase auth not available: $e');
    }
  }

  /// Exchanges a Steam ID for a Firebase auth session.
  ///
  /// Flow:
  /// 1. Call Cloud Function with Steam ID
  /// 2. Cloud Function validates + creates custom token
  /// 3. Sign in to Firebase with that token
  /// 4. Auth state listener picks up the sign-in
  Future<void> signInWithSteamId(String steamId) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      debugPrint('Requesting Firebase token for Steam ID: $steamId');

      final callable = FirebaseFunctions.instance.httpsCallable(
        'createCustomToken',
      );
      final result = await callable.call<Map<String, dynamic>>({
        'steamId': steamId,
      });

      final token = result.data['token'] as String?;
      if (token == null) {
        throw Exception('No token returned from Cloud Function');
      }

      debugPrint('Got custom token, signing in...');
      await FirebaseAuth.instance.signInWithCustomToken(token);
      // Auth state listener will update state to isLoggedIn: true
    } catch (e) {
      debugPrint('Firebase sign-in failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Signs out of Firebase.
  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('Sign out failed: $e');
    }
  }
}
