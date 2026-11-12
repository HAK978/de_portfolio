import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/cs2_item.dart';
import 'inventory_sync.dart';

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

/// Server-maintained price fields for one item, read from the shared
/// `prices` collection. Any field may be null if the scheduled refresh
/// hasn't populated it yet.
class ServerPriceData {
  final double? currentPrice;
  final double? csfloatPrice;
  final double? priceChange24h;
  final double? priceChange7d;
  final double? priceChange30d;

  const ServerPriceData({
    this.currentPrice,
    this.csfloatPrice,
    this.priceChange24h,
    this.priceChange7d,
    this.priceChange30d,
  });
}

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  late final InventorySynchronizer _inventorySync =
      InventorySynchronizer(_FirestoreInventoryStore(_db));

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

  /// Saves the distinct item names in the signed-in user's storage units so
  /// the scheduled price job prices them too (it otherwise only sees synced
  /// inventories). Names only, never contents or quantities. Returns false
  /// if nobody is signed in yet, so the caller can retry later.
  Future<bool> saveStorageItemNames(List<String> names) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _quotaExhausted) return false;
    await _db.collection('users').doc(uid).set({
      'storageItemNames': names,
      'storageItemsUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return true;
  }

  /// Gets user profile data.
  Future<Map<String, dynamic>?> getUserProfile(String steamId) async {
    final doc = await _db.collection('users').doc(steamId).get();
    return doc.data();
  }

  // ── Inventory ─────────────────────────────────────────────

  /// Only a complete Steam response may remove missing cloud items.
  Future<void> saveInventory(
    String steamId,
    List<CS2Item> items, {
    bool removeMissing = false,
  }) async {
    if (FirebaseAuth.instance.currentUser?.uid != steamId) {
      _setSyncState(const SyncState(status: SyncStatus.error, message: 'Sign in to this Steam account to sync'));
      return;
    }
    if (_quotaExhausted) {
      _setSyncState(const SyncState(status: SyncStatus.error, message: 'Quota exhausted'));
      return;
    }
    _setSyncState(const SyncState(status: SyncStatus.syncing, message: 'inventory'));
    try {
      await _inventorySync.save(steamId, items, removeMissing: removeMissing);
      _setSyncState(SyncState(
        status: SyncStatus.success,
        message: 'Inventory synced',
        lastSyncTime: DateTime.now(),
      ));
    } catch (e) {
      if (e is FirebaseException && e.code == 'resource-exhausted') {
        _quotaExhausted = true;
      }
      _setSyncState(SyncState(
        status: SyncStatus.error,
        message: 'Inventory sync incomplete. Retry to finish.',
      ));
      debugPrint('Inventory sync failed: $e');
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

    return items;
  }

  // ── Prices (shared collection) ────────────────────────────
  //
  // Written only by the scheduled `updatePriceChanges` Cloud Function; the
  // security rules reject client writes.

  /// Loads server-maintained price data (currentPrice, csfloatPrice,
  /// priceChange24h) from the shared prices collection, keyed by
  /// marketHashName.
  ///
  /// These fields are refreshed every 4 hours by the `updatePriceChanges`
  /// scheduled Cloud Function from bulk price files. The app reads them on
  /// open so prices stay current without depending on a manual fetch.
  /// Reads the whole collection in one query.
  Future<Map<String, ServerPriceData>> loadServerPrices() async {
    final snapshot = await _db.collection('prices').get();
    final result = <String, ServerPriceData>{};

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final name = data['marketHashName'] as String?;
      if (name == null) continue;
      result[name] = ServerPriceData(
        currentPrice: (data['currentPrice'] as num?)?.toDouble(),
        csfloatPrice: (data['csfloatPrice'] as num?)?.toDouble(),
        priceChange24h: data['priceHistoryVersion'] == 2 ? (data['priceChange24h'] as num?)?.toDouble() : null,
        priceChange7d: data['priceHistoryVersion'] == 2 ? (data['priceChange7d'] as num?)?.toDouble() : null,
        priceChange30d: data['priceHistoryVersion'] == 2 ? (data['priceChange30d'] as num?)?.toDouble() : null,
      );
    }

    debugPrint('Loaded ${result.length} server prices from Firestore');
    return result;
  }

  /// Reads the timestamp of the last server-side price refresh from
  /// `meta/priceRefresh`. Returns null if the doc/field is missing or
  /// the read fails. Used by the home "prices updated at" label.
  Future<DateTime?> loadPriceRefreshTime() async {
    try {
      final doc = await _db.collection('meta').doc('priceRefresh').get();
      final ts = doc.data()?['lastRun'];
      if (ts is Timestamp) return ts.toDate();
      return null;
    } catch (e) {
      debugPrint('loadPriceRefreshTime failed: $e');
      return null;
    }
  }

}

class _FirestoreInventoryStore implements InventorySyncStore {
  _FirestoreInventoryStore(this.db);
  final FirebaseFirestore db;

  CollectionReference<Map<String, dynamic>> _items(String steamId) =>
      db.collection('inventories').doc(steamId).collection('items');

  @override
  Future<Map<String, CS2Item>> load(String steamId) async {
    // Reconciliation must use server data; an offline cache can omit documents.
    final snapshot = await _items(steamId).get(const GetOptions(source: Source.server));
    return {for (final doc in snapshot.docs) doc.id: CS2Item.fromJson(doc.data())};
  }

  @override
  Future<void> writeBatch(String steamId, Map<String, CS2Item> updates, List<String> deletions) async {
    final batch = db.batch();
    for (final entry in updates.entries) {
      batch.set(_items(steamId).doc(entry.key), entry.value.toJson());
    }
    for (final id in deletions) {
      batch.delete(_items(steamId).doc(id));
    }
    // Await actual completion. A timeout does not cancel a Firestore write and
    // would let a stale write arrive after the next queued snapshot.
    await batch.commit();
  }

  @override
  Future<void> writeMetadata(String steamId, int itemCount) async {
    await db.collection('inventories').doc(steamId).set({
      'itemCount': itemCount,
      'lastSync': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
