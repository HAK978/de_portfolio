import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';
import '../services/csfloat_service.dart';
import '../services/price_service.dart';
import 'auth_provider.dart';
import 'inventory_provider.dart';
import 'storage_provider.dart';

/// Service instance for fetching prices.
final priceServiceProvider = Provider<PriceService>((ref) {
  return PriceService();
});

/// Tracks the state of a batch price fetch operation.
///
/// This is NOT an AsyncNotifierProvider because we need more granular
/// control — we want to track progress (fetched/total), not just
/// loading/done. So we use a regular NotifierProvider with a custom
/// state class that holds the progress info.
class PriceFetchState {
  final bool isFetching;
  final int fetched;
  final int total;
  final String currentItem;
  final String? error;

  const PriceFetchState({
    this.isFetching = false,
    this.fetched = 0,
    this.total = 0,
    this.currentItem = '',
    this.error,
  });

  PriceFetchState copyWith({
    bool? isFetching,
    int? fetched,
    int? total,
    String? currentItem,
    String? error,
  }) {
    return PriceFetchState(
      isFetching: isFetching ?? this.isFetching,
      fetched: fetched ?? this.fetched,
      total: total ?? this.total,
      currentItem: currentItem ?? this.currentItem,
      error: error,
    );
  }

  double get percent => total > 0 ? fetched / total : 0;
  bool get isDone => !isFetching && fetched > 0 && fetched >= total;
}

/// Keeps track of how many fetches are active so we only release
/// wakelock when all are done.
/// Items that can't be sold on the market — skip these during price fetch.
bool _isMarketable(CS2Item item) {
  // Extraordinary/Collectible items (service medals, pins, etc.)
  if (item.rarity == 'Extraordinary') return false;

  // Specific non-marketable items
  const nonMarketable = [
    'Music Kit | Valve, CS:GO',
  ];
  if (nonMarketable.contains(item.marketHashName)) return false;

  return true;
}

/// Extracts unique marketable item names from inventory.
List<String> _getMarketableNames(List<CS2Item> items) {
  return items
      .where(_isMarketable)
      .map((item) => item.marketHashName)
      .toSet()
      .toList();
}

final priceFetchProvider =
    NotifierProvider<PriceFetchNotifier, PriceFetchState>(
  PriceFetchNotifier.new,
);

class PriceFetchNotifier extends Notifier<PriceFetchState> {
  StreamSubscription<PriceFetchProgress>? _subscription;

  @override
  PriceFetchState build() => const PriceFetchState();

  /// Starts fetching prices for all unique items in the inventory.
  ///
  /// This listens to the Stream from PriceService and updates the
  /// state on each progress event. When the stream completes, it
  /// merges the fetched prices into the inventory items.
  void fetchPrices() {
    // Don't start if already fetching
    if (state.isFetching) return;

    final items = ref.read(inventoryProvider).when(
      data: (items) => items,
      loading: () => <CS2Item>[],
      error: (_, _) => <CS2Item>[],
    );
    if (items.isEmpty) {
      state = state.copyWith(error: 'No inventory loaded');
      return;
    }

    // Get unique marketable item names (skip non-tradeable items)
    final uniqueNames = _getMarketableNames(items);
    debugPrint('Starting price fetch for ${uniqueNames.length} marketable items');

    state = PriceFetchState(
      isFetching: true,
      total: uniqueNames.length,
      currentItem: 'Starting...',
    );

    final service = ref.read(priceServiceProvider);
    Map<String, double> lastPrices = {};

    _subscription = service.fetchPrices(uniqueNames).listen(
      (progress) {
        state = state.copyWith(
          fetched: progress.fetched,
          total: progress.total,
          currentItem: progress.currentItem,
        );
        lastPrices = progress.prices;

        // Merge prices into inventory on each update so the UI
        // updates progressively — persist:false skips disk/cloud writes
        ref.read(inventoryProvider.notifier).updatePrices(progress.prices, persist: false);
      },
      onDone: () {
        debugPrint('Price fetch complete: ${state.fetched}/${state.total}');
        ref.read(inventoryProvider.notifier).persistCurrentState();
        _syncPricesToFirestore(lastPrices);
        saveLastPriceFetchTimestamp();
        state = state.copyWith(isFetching: false);
        _subscription = null;
        // Also refresh Steam prices for all loaded storage units
        ref.read(storageProvider.notifier).fetchAllStorageSteamPrices();
      },
      onError: (error) {
        debugPrint('Price fetch error: $error');
        state = state.copyWith(
          isFetching: false,
          error: error.toString(),
        );
        _subscription = null;
      },
    );
  }

  /// Syncs fetched prices to the shared Firestore prices collection.
  Future<void> _syncPricesToFirestore(Map<String, double> prices) async {
    debugPrint('_syncPricesToFirestore: ${prices.length} prices to sync');
    if (prices.isEmpty) return;
    try {
      final firestore = ref.read(firestoreServiceProvider);
      await firestore.savePrices(prices);
    } catch (e) {
      debugPrint('Price sync to Firestore failed: $e');
    }
  }

  /// Stops an in-progress price fetch.
  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    state = state.copyWith(isFetching: false);
  }

  /// Auto-fetches prices if the last fetch was more than 24 hours ago.
  Future<void> autoRefreshIfStale() async {
    if (state.isFetching) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/last_price_fetch.txt');
      if (file.existsSync()) {
        final ts = int.tryParse(await file.readAsString()) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - ts;
        if (age < const Duration(hours: 24).inMilliseconds) return;
      }
      debugPrint('[Prices] Cache stale — auto-refreshing inventory prices');
      fetchPrices();
    } catch (e) {
      debugPrint('[Prices] Auto-refresh check failed: $e');
    }
  }

}

/// Saves the current time as the last price fetch timestamp.
/// Called by both inventory and storage price fetches.
Future<void> saveLastPriceFetchTimestamp() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/last_price_fetch.txt')
        .writeAsString(DateTime.now().millisecondsSinceEpoch.toString());
  } catch (_) {}
}

/// True if Steam Market is being fetched anywhere (inventory or storage).
final steamFetchInProgressProvider = Provider<bool>((ref) {
  final inventoryFetching = ref.watch(priceFetchProvider).isFetching;
  final storageFetching = ref.watch(storageProvider).pricingCaskets
      .any((key) => key.endsWith('_steam'));
  return inventoryFetching || storageFetching;
});

/// True if CSFloat is being fetched anywhere (inventory or storage).
final csfloatFetchInProgressProvider = Provider<bool>((ref) {
  final inventoryFetching = ref.watch(csfloatFetchProvider).isFetching;
  final storageFetching = ref.watch(storageProvider).pricingCaskets
      .any((key) => key.endsWith('_csfloat'));
  return inventoryFetching || storageFetching;
});

/// True if any price fetch is in progress — used to disable storage unit
/// fetch buttons (which trigger both Steam and CSFloat simultaneously).
final anyPriceFetchInProgressProvider = Provider<bool>((ref) {
  return ref.watch(steamFetchInProgressProvider) ||
      ref.watch(csfloatFetchInProgressProvider);
});

// ── CSFloat pricing ─────────────────────────────────────────

/// CSFloat API key — set from settings or loaded from disk.
final csfloatApiKeyProvider = NotifierProvider<CsfloatApiKeyNotifier, String>(
  CsfloatApiKeyNotifier.new,
);

class CsfloatApiKeyNotifier extends Notifier<String> {
  static const _fileName = 'csfloat_api_key.txt';

  @override
  String build() {
    _loadSavedKey();
    return '';
  }

  void set(String value) {
    state = value;
    _saveKey(value);
  }

  Future<void> _loadSavedKey() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) {
        final key = await file.readAsString();
        if (key.trim().isNotEmpty) {
          state = key.trim();
        }
      }
    } catch (e) {
      debugPrint('Error loading CSFloat API key: $e');
    }
  }

  Future<void> _saveKey(String key) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(key);
    } catch (e) {
      debugPrint('Error saving CSFloat API key: $e');
    }
  }
}

final csfloatServiceProvider = Provider<CsfloatService>((ref) {
  final apiKey = ref.watch(csfloatApiKeyProvider);
  return CsfloatService(apiKey: apiKey.isNotEmpty ? apiKey : null);
});

final csfloatFetchProvider =
    NotifierProvider<CsfloatFetchNotifier, PriceFetchState>(
  CsfloatFetchNotifier.new,
);

class CsfloatFetchNotifier extends Notifier<PriceFetchState> {
  StreamSubscription<PriceFetchProgress>? _subscription;

  @override
  PriceFetchState build() => const PriceFetchState();

  Future<void> fetchPrices() async {
    if (state.isFetching) return;

    final items = ref.read(inventoryProvider).when(
      data: (items) => items,
      loading: () => <CS2Item>[],
      error: (_, _) => <CS2Item>[],
    );
    if (items.isEmpty) {
      state = state.copyWith(error: 'No inventory loaded');
      return;
    }

    // Wait for CSFloat API key to load from disk if needed
    var apiKey = ref.read(csfloatApiKeyProvider);
    if (apiKey.isEmpty) {
      state = PriceFetchState(
        isFetching: true,
        total: 0,
        currentItem: 'Waiting for API key...',
      );
      // Give async key loading up to 3 seconds
      for (var i = 0; i < 6; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        apiKey = ref.read(csfloatApiKeyProvider);
        if (apiKey.isNotEmpty) break;
      }
      if (apiKey.isEmpty) {
        state = const PriceFetchState(
          error: 'CSFloat API key not set — add it in Settings',
        );
        return;
      }
    }

    final uniqueNames = _getMarketableNames(items);

    state = PriceFetchState(
      isFetching: true,
      total: uniqueNames.length,
      currentItem: 'Starting...',
    );

    // Re-read service now that key is guaranteed loaded
    final service = ref.read(csfloatServiceProvider);

    Map<String, double> lastPrices = {};

    _subscription = service.fetchPrices(uniqueNames).listen(
      (progress) {
        state = state.copyWith(
          fetched: progress.fetched,
          total: progress.total,
          currentItem: progress.currentItem,
        );
        lastPrices = progress.prices;
        ref.read(inventoryProvider.notifier).updateCsfloatPrices(progress.prices, persist: false);
      },
      onDone: () {
        debugPrint('CSFloat fetch complete: ${state.fetched}/${state.total}');
        ref.read(inventoryProvider.notifier).persistCurrentState();
        _syncCsfloatPricesToFirestore(lastPrices);
        state = state.copyWith(isFetching: false);
        _subscription = null;
        // Also refresh CSFloat prices for all loaded storage units
        ref.read(storageProvider.notifier).fetchAllStorageCsfloatPrices();
      },
      onError: (error) {
        debugPrint('CSFloat fetch error: $error');
        state = state.copyWith(
          isFetching: false,
          error: error.toString(),
        );
        _subscription = null;
      },
    );
  }

  /// Syncs CSFloat prices to Firestore shared prices collection.
  void _syncCsfloatPricesToFirestore(Map<String, double> prices) async {
    if (prices.isEmpty) return;
    try {
      final firestore = ref.read(firestoreServiceProvider);
      await firestore.saveCsfloatPrices(prices);
    } catch (e) {
      debugPrint('CSFloat price sync to Firestore failed: $e');
    }
  }

  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    state = state.copyWith(isFetching: false);
  }
}
