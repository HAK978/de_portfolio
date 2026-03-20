import 'dart:developer' as dev;

import 'package:cloud_firestore/cloud_firestore.dart';

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
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── User Profile ──────────────────────────────────────────

  /// Creates or updates a user document after login.
  Future<void> saveUserProfile({
    required String steamId,
    String? displayName,
    String? avatarUrl,
  }) async {
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

  /// Saves the full inventory to Firestore.
  ///
  /// Uses a batch write to update all items at once. Firestore
  /// batches can hold up to 500 operations — for larger inventories
  /// we split into multiple batches.
  Future<void> saveInventory(String steamId, List<CS2Item> items) async {
    final collectionRef = _db
        .collection('inventories')
        .doc(steamId)
        .collection('items');

    // Process in batches of 500 (Firestore limit)
    const batchSize = 500;
    for (int i = 0; i < items.length; i += batchSize) {
      final batch = _db.batch();
      final end = (i + batchSize).clamp(0, items.length);
      final chunk = items.sublist(i, end);

      for (final item in chunk) {
        final docRef = collectionRef.doc(item.id);
        batch.set(docRef, item.toJson());
      }

      await batch.commit();
      dev.log('Saved inventory batch: ${i + chunk.length}/${items.length}');
    }

    // Update last sync timestamp
    await _db.collection('inventories').doc(steamId).set({
      'itemCount': items.length,
      'lastSync': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    dev.log('Inventory saved to Firestore: ${items.length} items');
  }

  /// Loads inventory from Firestore.
  Future<List<CS2Item>> loadInventory(String steamId) async {
    final snapshot = await _db
        .collection('inventories')
        .doc(steamId)
        .collection('items')
        .get();

    return snapshot.docs
        .map((doc) => CS2Item.fromJson(doc.data()))
        .toList();
  }

  // ── Prices (shared collection) ────────────────────────────

  /// Saves price data for an item. Prices are shared across all users
  /// since they're the same for everyone.
  Future<void> savePrice({
    required String marketHashName,
    required double currentPrice,
    double? csfloatPrice,
  }) async {
    await _db.collection('prices').doc(_sanitizeDocId(marketHashName)).set({
      'marketHashName': marketHashName,
      'currentPrice': currentPrice,
      'csfloatPrice': csfloatPrice,
      'lastUpdated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Batch-saves prices for multiple items.
  Future<void> savePrices(Map<String, double> prices) async {
    const batchSize = 500;
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

      await batch.commit();
    }

    dev.log('Saved ${prices.length} prices to Firestore');
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

    dev.log('Loaded ${prices.length} prices from Firestore');
    return prices;
  }

  // ── Helpers ───────────────────────────────────────────────

  /// Firestore doc IDs can't contain forward slashes.
  /// Market hash names like "M4A4 | Asiimov (Field-Tested)" are fine,
  /// but some edge cases might have slashes.
  String _sanitizeDocId(String name) {
    return name.replaceAll('/', '_');
  }
}
