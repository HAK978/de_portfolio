import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/firestore_service.dart';
import '../models/steam_login_session.dart';

/// Provides the FirestoreService instance.
final firestoreServiceProvider = Provider<FirestoreService>((ref) {
  final service = FirestoreService();
  // Wire sync state changes to the provider
  service.onSyncStateChanged = (syncState) {
    ref.read(firestoreSyncProvider.notifier).set(syncState);
  };
  return service;
});

/// Tracks Firestore sync status for the UI.
final firestoreSyncProvider = NotifierProvider<FirestoreSyncNotifier, SyncState>(
  FirestoreSyncNotifier.new,
);

class FirestoreSyncNotifier extends Notifier<SyncState> {
  @override
  SyncState build() => const SyncState();

  void set(SyncState s) => state = s;
}

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
      // Intentional: error is overwritten with the passed value (not
      // `error ?? this.error`) so callers can clear it by passing null.
      error: error,
    );
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

class AuthNotifier extends Notifier<AuthState> {
  StreamSubscription<User?>? _authSubscription;

  @override
  AuthState build() {
    _listenToAuthChanges();
    ref.onDispose(() {
      _authSubscription?.cancel();
    });
    return const AuthState();
  }

  void _listenToAuthChanges() {
    try {
      _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) async {
        if (user != null) {
          try {
            final token = await user.getIdTokenResult();
            if (!ref.mounted || FirebaseAuth.instance.currentUser?.uid != user.uid) return;
            if (token.claims?['steamVerified'] != true) {
              state = const AuthState(error: 'Please sign in with Steam again to enable cloud sync.');
              return;
            }
          } catch (_) {
            if (ref.mounted) state = const AuthState(error: 'Could not verify cloud sign-in.');
            return;
          }
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

  Future<SteamLoginSession> beginSteamLogin() async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('beginSteamLogin').call<Map<String, dynamic>>();
    return SteamLoginSession(result.data);
  }

  Future<String> signInWithSteamAssertion(
    String sessionId,
    Map<String, String> assertion,
  ) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('createCustomToken').call<Map<String, dynamic>>({
        'sessionId': sessionId,
        'assertion': assertion,
      });
      final token = result.data['token'] as String;
      final credential = await FirebaseAuth.instance.signInWithCustomToken(token);
      final steamId = credential.user!.uid;
      if (ref.mounted) {
        state = state.copyWith(isLoggedIn: true, steamId: steamId, isLoading: false);
      }
      return steamId;
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: 'Steam sign-in could not be verified.');
      }
      rethrow;
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
