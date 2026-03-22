import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/cs2_item.dart';

/// Handles all Firestore read/write operations.
///
/// Firestore is a NoSQL document database — data is stored in
/// documents, which live inside collections. Unlike SQL, there are
/// no tables or joins. Instead, you nest collections inside documents
/// (subcollections) or denormalize data by duplicating it.
///
/// Our schema:
///   users/{steamId}           — user profile (displayName, settings)
///   inventories/{steamId}     — inventory metadata
///     items/{itemId}          — individual inventory items
///   prices/{marketHashName}   — shared price data (not per-user)
/// Tracks the current Firestore sync state.
enum SyncStatus { idle, syncing, success, error }

class SyncState {
  final SyncStatus status;
  final String? message;
  final DateTime? lastSyncTime;

  const SyncState({
    this.status = SyncStatus.idle,
    this.message,
    this.lastSyncTime,
  });
}

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Tracks the last-synced price per item so we only write changes.
  /// Key: item id, Value: "steamPrice|csfloatPrice"
  final Map<String, String> _lastSyncedPrices = {};

  /// If true, skip all writes until the app restarts.
  /// Set when we get RESOURCE_EXHAUSTED from Firestore.
  bool _quotaExhausted = false;

  /// Returns true if the user is signed in to Firebase.
  bool get isAuthenticated => FirebaseAuth.instance.currentUser != null;

  /// Current sync state — UI can read this to show status.
  SyncState _syncState = const SyncState();
  SyncState get syncState => _syncState;

  /// Callback for when sync state changes — wired by the provider.
  void Function(SyncState)? onSyncStateChanged;

  void _setSyncState(SyncState s) {
    _syncState = s;
    onSyncStateChanged?.call(s);
  }

  // ── User Profile ──────────────────────────────────────────

  /// Creates or updates a user document after login.
  Future<void> saveUserProfile({
    required String steamId,
    String? displayName,
    String? avatarUrl,
  }) async {
    if (_quotaExhausted || !isAuthenticated) return;
    await _db.collection('users').doc(steamId).set({
      'displayName': displayName ?? '',
      'avatarUrl': avatarUrl ?? '',
      'lastSync': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Gets user profile data.
  Future<Map<String, dynamic>?> getUserProfile(String steamId) async {
    final doc = await _db.collection('users').doc(steamId).get();
    return doc.data();
  }

  // ── Inventory ─────────────────────────────────────────────

  /// Saves inventory to Firestore, but only items whose prices changed.
  ///
  /// On first sync (empty _lastSyncedPrices), writes everything.
  /// On subsequent syncs, compares each item's prices to last sync
  /// and only writes the diff. This keeps writes low for the free tier.
  Future<void> saveInventory(String steamId, List<CS2Item> items) async {
    if (!isAuthenticated) {
      debugPrint('saveInventory: skipping — not authenticated');
      _setSyncState(const SyncState(status: SyncStatus.error, message: 'Not signed in'));
      return;
    }
    if (_quotaExhausted) {
      debugPrint('saveInventory: skipping — quota exhausted');
      _setSyncState(const SyncState(status: SyncStatus.error, message: 'Quota exhausted'));
      return;
    }

    // Find items that actually changed since last sync
    final changedItems = <CS2Item>[];
    final isFirstSync = _lastSyncedPrices.isEmpty;

    for (final item in items) {
      final priceKey = _priceKey(item);
      if (_lastSyncedPrices[item.id] != priceKey) {
        changedItems.add(item);
      }
    }

    if (changedItems.isEmpty) {
      debugPrint('saveInventory: no changes to sync');
      return;
    }

    debugPrint('saveInventory: ${changedItems.length}/${items.length} items changed'
        '${isFirstSync ? " (first sync)" : ""}');
    _setSyncState(SyncState(status: SyncStatus.syncing, message: '${changedItems.length} items'));

    final collectionRef = _db
        .collection('inventories')
        .doc(steamId)
        .collection('items');

    // Write in batches of 50
    const batchSize = 50;
    int written = 0;

    for (int i = 0; i < changedItems.length; i += batchSize) {
      final batch = _db.batch();
      final end = (i + batchSize).clamp(0, changedItems.length);
      final chunk = changedItems.sublist(i, end);

      for (final item in chunk) {
        final docRef = collectionRef.doc(item.id);
        batch.set(docRef, item.toJson());
      }

      final batchNum = i ~/ batchSize + 1;
      try {
        await _commitWithRetry(batch, batchNum);
        written += chunk.length;
        debugPrint('saveInventory: batch $batchNum committed (${chunk.length} items)');

        // Update tracked prices for successfully written items
        for (final item in chunk) {
          _lastSyncedPrices[item.id] = _priceKey(item);
        }
      } catch (e) {
        final msg = e.toString();
        if (msg.contains('RESOURCE_EXHAUSTED') || msg.contains('Quota exceeded')) {
          debugPrint('saveInventory: QUOTA EXHAUSTED — disabling Firestore writes');
          _quotaExhausted = true;
          _setSyncState(const SyncState(status: SyncStatus.error, message: 'Quota exhausted'));
          return;
        }
        if (msg.contains('PERMISSION_DENIED')) {
          debugPrint('saveInventory: PERMISSION DENIED — not signed in to Firebase?');
          _setSyncState(const SyncState(status: SyncStatus.error, message: 'Permission denied'));
          return;
        }
        debugPrint('saveInventory: batch $batchNum FAILED — $e');
      }
    }

    // Update metadata only if we wrote something
    if (written > 0) {
      try {
        await _db.collection('inventories').doc(steamId).set({
          'itemCount': items.length,
          'lastSync': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).timeout(const Duration(seconds: 10));
        debugPrint('saveInventory: DONE ($written items written)');
        _setSyncState(SyncState(
          status: SyncStatus.success,
          message: '$written items synced',
          lastSyncTime: DateTime.now(),
        ));
      } catch (e) {
        debugPrint('saveInventory: lastSync write failed — $e');
        _setSyncState(SyncState(status: SyncStatus.error, message: e.toString()));
      }
    }
  }

  /// Loads inventory from Firestore.
  Future<List<CS2Item>> loadInventory(String steamId) async {
    final snapshot = await _db
        .collection('inventories')
        .doc(steamId)
        .collection('items')
        .get();

    final items = snapshot.docs
        .map((doc) => CS2Item.fromJson(doc.data()))
        .toList();

    // Populate last-synced prices so next sync only writes changes
    for (final item in items) {
      _lastSyncedPrices[item.id] = _priceKey(item);
    }

    return items;
  }

  // ── Prices (shared collection) ────────────────────────────

  /// Saves price data for an item. Prices are shared across all users
  /// since they're the same for everyone.
  Future<void> savePrice({
    required String marketHashName,
    required double currentPrice,
    double? csfloatPrice,
  }) async {
    if (_quotaExhausted || !isAuthenticated) return;
    await _db.collection('prices').doc(_sanitizeDocId(marketHashName)).set({
      'marketHashName': marketHashName,
      'currentPrice': currentPrice,
      'csfloatPrice': csfloatPrice,
      'lastUpdated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Batch-saves prices for multiple items.
  Future<void> savePrices(Map<String, double> prices) async {
    debugPrint('savePrices: called with ${prices.length} prices, auth=$isAuthenticated, quota=$_quotaExhausted');
    if (!isAuthenticated) {
      debugPrint('savePrices: skipping — not authenticated');
      return;
    }
    if (_quotaExhausted) return;

    const batchSize = 50;
    final entries = prices.entries.toList();

    for (int i = 0; i < entries.length; i += batchSize) {
      final batch = _db.batch();
      final end = (i + batchSize).clamp(0, entries.length);
      final chunk = entries.sublist(i, end);

      for (final entry in chunk) {
        final docRef = _db.collection('prices').doc(_sanitizeDocId(entry.key));
        batch.set(docRef, {
          'marketHashName': entry.key,
          'currentPrice': entry.value,
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      try {
        await batch.commit().timeout(const Duration(seconds: 20));
      } catch (e) {
        if (e.toString().contains('RESOURCE_EXHAUSTED')) {
          _quotaExhausted = true;
          return;
        }
        debugPrint('savePrices: batch failed — $e');
      }
    }

    debugPrint('savePrices: saved ${prices.length} prices');
  }

  /// Batch-saves CSFloat prices — only updates the csfloatPrice field.
  Future<void> saveCsfloatPrices(Map<String, double> prices) async {
    if (!isAuthenticated) {
      debugPrint('saveCsfloatPrices: skipping — not authenticated');
      return;
    }
    if (_quotaExhausted) return;

    const batchSize = 50;
    final entries = prices.entries.toList();

    for (int i = 0; i < entries.length; i += batchSize) {
      final batch = _db.batch();
      final end = (i + batchSize).clamp(0, entries.length);
      final chunk = entries.sublist(i, end);

      for (final entry in chunk) {
        final docRef = _db.collection('prices').doc(_sanitizeDocId(entry.key));
        batch.set(docRef, {
          'marketHashName': entry.key,
          'csfloatPrice': entry.value,
          'lastUpdated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      try {
        await batch.commit().timeout(const Duration(seconds: 20));
      } catch (e) {
        if (e.toString().contains('RESOURCE_EXHAUSTED')) {
          _quotaExhausted = true;
          return;
        }
        debugPrint('saveCsfloatPrices: batch failed — $e');
      }
    }

    debugPrint('saveCsfloatPrices: saved ${prices.length} prices');
  }

  /// Loads all cached prices from Firestore.
  Future<Map<String, double>> loadPrices() async {
    final snapshot = await _db.collection('prices').get();
    final prices = <String, double>{};

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final name = data['marketHashName'] as String?;
      final price = (data['currentPrice'] as num?)?.toDouble();
      if (name != null && price != null) {
        prices[name] = price;
      }
    }

    debugPrint('Loaded ${prices.length} prices from Firestore');
    return prices;
  }

  // ── Retry Logic ─────────────────────────────────────────

  /// Commits a Firestore batch with one retry on timeout.
  Future<void> _commitWithRetry(WriteBatch batch, int batchNum) async {
    try {
      await batch.commit().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      debugPrint('saveInventory: batch $batchNum timed out, retrying...');
      await Future.delayed(const Duration(seconds: 5));
      await batch.commit().timeout(const Duration(seconds: 30));
    }
  }

  // ── Helpers ───────────────────────────────────────────────

  /// Firestore doc IDs can't contain forward slashes.
  String _sanitizeDocId(String name) {
    return name.replaceAll('/', '_');
  }

  /// Creates a string key from an item's prices for change detection.
  String _priceKey(CS2Item item) {
    return '${item.currentPrice}|${item.csfloatPrice ?? 0}';
  }
}
