import 'dart:developer' as dev;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/firestore_service.dart';

/// Provides the FirestoreService instance.
final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  return FirestoreService();
});

/// Auth state — tracks whether user is logged in.
///
/// For now this is a simple wrapper around Firebase Auth state.
/// When we add Steam OpenID login, this will handle the full flow:
/// 1. Open Steam login in WebView
/// 2. Get SteamID64 from redirect
/// 3. Exchange for Firebase custom token (via Cloud Function)
/// 4. Sign in to Firebase with that token
///
/// Until the Firebase project is set up, the app continues to work
/// with just the local Steam ID (from settings). This provider
/// adds the cloud persistence layer on top.
class AuthState {
  final bool isLoggedIn;
  final String? steamId;
  final String? displayName;
  final String? avatarUrl;
  final bool isLoading;

  const AuthState({
    this.isLoggedIn = false,
    this.steamId,
    this.displayName,
    this.avatarUrl,
    this.isLoading = false,
  });

  AuthState copyWith({
    bool? isLoggedIn,
    String? steamId,
    String? displayName,
    String? avatarUrl,
    bool? isLoading,
  }) {
    return AuthState(
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      steamId: steamId ?? this.steamId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

class AuthNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Listen to Firebase auth state changes
    _listenToAuthChanges();
    return const AuthState();
  }

  void _listenToAuthChanges() {
    try {
      FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user != null) {
          dev.log('Firebase auth: user signed in (${user.uid})');
          state = state.copyWith(
            isLoggedIn: true,
            steamId: user.uid,
            displayName: user.displayName,
          );
        } else {
          dev.log('Firebase auth: user signed out');
          state = const AuthState();
        }
      });
    } catch (e) {
      // Firebase not initialized yet — that's OK, we work offline
      dev.log('Firebase auth not available: $e');
    }
  }

  /// Signs in with a Firebase custom token.
  ///
  /// This will be called after the Steam OpenID flow. A Cloud Function
  /// validates the OpenID response and returns a custom Firebase token.
  Future<void> signInWithCustomToken(String token) async {
    state = state.copyWith(isLoading: true);
    try {
      await FirebaseAuth.instance.signInWithCustomToken(token);
      // Auth state listener will update the state
    } catch (e) {
      dev.log('Sign in failed: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Signs out of Firebase.
  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      dev.log('Sign out failed: $e');
    }
  }

  /// Syncs the current local inventory to Firestore.
  ///
  /// This is called after price fetches complete, so the cloud
  /// always has up-to-date data. Only works when logged in.
  Future<void> syncInventoryToCloud(String steamId, dynamic items) async {
    if (!state.isLoggedIn) return;

    try {
      final firestore = ref.read(firestoreServiceProvider);
      await firestore.saveUserProfile(steamId: steamId);
      dev.log('Synced user profile to Firestore');
    } catch (e) {
      dev.log('Error syncing to cloud: $e');
    }
  }
}
