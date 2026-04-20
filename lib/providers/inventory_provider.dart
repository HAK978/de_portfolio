import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';
import '../models/storage_unit.dart';
import '../services/steam_api_service.dart';
import 'auth_provider.dart'; // for firestoreServiceProvider
import 'storage_provider.dart';

/// Holds the Steam ID the user wants to view.
///
/// Persists to disk so the user doesn't have to re-enter it
/// after a restart.
final steamIdProvider = NotifierProvider<SteamIdNotifier, String>(
  SteamIdNotifier.new,
);

class SteamIdNotifier extends Notifier<String> {
  static const _fileName = 'steam_id.txt';

  @override
  String build() {
    // Keep alive so Riverpod 3's auto-dispose doesn't reset auth state
    // mid-session (e.g. during Navigator push/pop transitions).
    ref.keepAlive();
    // Load saved Steam ID on startup (async, sets state when done)
    _loadSavedId();
    return ''; // empty initially
  }

  void set(String value) {
    state = value;
    _saveId(value);
  }

  Future<void> _loadSavedId() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) {
        final id = await file.readAsString();
        // Don't overwrite if already set (e.g. sign-in completed before disk read)
        if (id.trim().isNotEmpty && state.isEmpty) {
          debugPrint('Loaded saved Steam ID: $id');
          state = id.trim();
        }
      }
    } catch (e) {
      debugPrint('Error loading saved Steam ID: $e');
    }
  }

  Future<void> _saveId(String id) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(id);
    } catch (e) {
      debugPrint('Error saving Steam ID: $e');
    }
  }
}

/// Service instance for fetching inventory.
final steamApiServiceProvider = Provider<SteamApiService>((ref) {
  return SteamApiService();
});

/// Tracks inventory fetch progress (items fetched, pages loaded).
class InventoryFetchState {
  final bool isFetching;
  final int itemsFetched;
  final int pagesFetched;

  const InventoryFetchState({
    this.isFetching = false,
    this.itemsFetched = 0,
    this.pagesFetched = 0,
  });

  InventoryFetchState copyWith({
    bool? isFetching,
    int? itemsFetched,
    int? pagesFetched,
  }) {
    return InventoryFetchState(
      isFetching: isFetching ?? this.isFetching,
      itemsFetched: itemsFetched ?? this.itemsFetched,
      pagesFetched: pagesFetched ?? this.pagesFetched,
    );
  }
}

final inventoryFetchProgressProvider =
    NotifierProvider<InventoryFetchProgressNotifier, InventoryFetchState>(
  InventoryFetchProgressNotifier.new,
);

class InventoryFetchProgressNotifier extends Notifier<InventoryFetchState> {
  @override
  InventoryFetchState build() => const InventoryFetchState();

  void update(InventoryFetchProgress progress) {
    state = state.copyWith(
      isFetching: progress.hasMore,
      itemsFetched: progress.itemsFetched,
      pagesFetched: progress.pagesFetched,
    );
  }

  void setFetching(bool value) {
    state = state.copyWith(isFetching: value);
  }

  void reset() {
    state = const InventoryFetchState();
  }
}

/// Fetches the full inventory from Steam.
///
/// This is an AsyncNotifierProvider — it holds an AsyncValue which
/// can be loading, data, or error. The UI reacts to all three states.
/// Calling `ref.invalidate(inventoryProvider)` re-triggers the fetch.
final inventoryProvider =
    AsyncNotifierProvider<InventoryNotifier, List<CS2Item>>(
  InventoryNotifier.new,
);

class InventoryNotifier extends AsyncNotifier<List<CS2Item>> {
  @override
  Future<List<CS2Item>> build() async {
    final steamId = ref.watch(steamIdProvider);
    debugPrint('InventoryNotifier.build() called, steamId: "$steamId"');
    if (steamId.isEmpty) return [];

    final service = ref.read(steamApiServiceProvider);

    // Try loading from local cache first
    final cached = await service.loadInventoryCache(steamId);
    if (cached != null && cached.isNotEmpty) {
      debugPrint('Loaded ${cached.length} items from local cache');
      return cached;
    }

    // No local cache — try Firestore (only if authenticated)
    final firestore = ref.read(firestoreServiceProvider);
    if (firestore.isAuthenticated) {
      try {
        final cloudItems = await firestore.loadInventory(steamId);
        if (cloudItems.isNotEmpty) {
          debugPrint('Loaded ${cloudItems.length} items from Firestore');
          // Save to local cache so next startup is faster
          await service.saveInventoryCache(steamId, cloudItems);
          return cloudItems;
        }
      } catch (e) {
        debugPrint('Firestore load failed (offline?): $e');
      }
    }

    // No cache anywhere — fetch from Steam
    return _fetchFromSteam(steamId);
  }

  /// Fetches inventory from Steam with progress reporting.
  Future<List<CS2Item>> _fetchFromSteam(String steamId) async {
    final service = ref.read(steamApiServiceProvider);
    final progressNotifier = ref.read(inventoryFetchProgressProvider.notifier);

    progressNotifier.setFetching(true);

    // Wire up progress callback
    service.onProgress = (progress) {
      progressNotifier.update(progress);
    };

    try {
      final items = await service.fetchInventory(steamId);
      debugPrint('Fetched ${items.length} items from Steam');
      _syncToFirestore(steamId, items);
      // Auto-fetch floats from GC in the background after inventory loads
      Future.microtask(() => fetchInventoryFloats());
      return items;
    } catch (e, stack) {
      debugPrint('Error fetching inventory: $e\n$stack');
      rethrow;
    } finally {
      service.onProgress = null;
      progressNotifier.reset();
    }
  }

  /// Updates item prices from a map of marketHashName → price.
  ///
  /// Uses copyWith to create new item instances with updated prices,
  /// since CS2Item is immutable. Only updates the state if the
  /// inventory is already loaded (not loading or error).
  ///
  /// When [persist] is false, only updates in-memory state (fast).
  /// When true, also writes to disk cache and syncs to Firestore.
  /// Call with persist:false during streaming, persist:true at the end.
  void updatePrices(Map<String, double> prices, {bool persist = true}) {
    final items = state.when(
      data: (items) => items,
      loading: () => null,
      error: (_, _) => null,
    );
    if (items == null) return;

    final updatedItems = items.map((item) {
      final price = prices[item.marketHashName];
      if (price != null) {
        return item.copyWith(currentPrice: price);
      }
      return item;
    }).toList();

    state = AsyncValue.data(updatedItems);

    if (persist) {
      _updateCache(updatedItems);
      final steamId = ref.read(steamIdProvider);
      if (steamId.isNotEmpty) _syncToFirestore(steamId, updatedItems);
    }
  }

  /// Updates CSFloat prices separately from Steam Market prices.
  ///
  /// Same [persist] logic as [updatePrices].
  void updateCsfloatPrices(Map<String, double> prices, {bool persist = true}) {
    final items = state.when(
      data: (items) => items,
      loading: () => null,
      error: (_, _) => null,
    );
    if (items == null) return;

    final updatedItems = items.map((item) {
      final price = prices[item.marketHashName];
      if (price != null) {
        return item.copyWith(csfloatPrice: price);
      }
      return item;
    }).toList();

    state = AsyncValue.data(updatedItems);

    if (persist) {
      _updateCache(updatedItems);
      final steamId = ref.read(steamIdProvider);
      if (steamId.isNotEmpty) _syncToFirestore(steamId, updatedItems);
    }
  }

  /// Saves current inventory state to cache (preserves prices).
  Future<void> _updateCache(List<CS2Item> items) async {
    final steamId = ref.read(steamIdProvider);
    if (steamId.isEmpty) return;
    final service = ref.read(steamApiServiceProvider);
    await service.saveInventoryCache(steamId, items);
  }

  /// Persists the current inventory state to disk cache and Firestore.
  /// Call this once after a batch of price updates completes.
  void persistCurrentState() {
    final items = state.when(
      data: (items) => items,
      loading: () => null,
      error: (_, _) => null,
    );
    if (items == null) return;

    _updateCache(items);
    final steamId = ref.read(steamIdProvider);
    if (steamId.isNotEmpty) {
      _syncToFirestore(steamId, items);
    }
  }

  /// Pushes inventory to Firestore in the background.
  /// Fire-and-forget — failures are logged but don't block the UI.
  Future<void> _syncToFirestore(String steamId, List<CS2Item> items) async {
    try {
      final firestore = ref.read(firestoreServiceProvider);
      await firestore.saveInventory(steamId, items);
    } catch (e) {
      debugPrint('Firestore sync failed: $e');
    }
  }

  /// Fetches float values for inventory items from the GC service.
  /// Merges floats into existing items and persists to cache.
  Future<void> fetchInventoryFloats() async {
    final items = state.when(
      data: (items) => items,
      loading: () => null,
      error: (_, _) => null,
    );
    if (items == null || items.isEmpty) return;

    try {
      final service = ref.read(storageServiceProvider);
      final floatsMap = await service.getInventoryFloats();

      final updatedItems = items.map((item) {
        final floats = floatsMap[item.marketHashName];
        if (floats == null || floats.isEmpty) return item;

        final sortedFloats = floats.map((f) => f.floatValue).toList()..sort();
        return item.copyWith(
          floatValue: sortedFloats.first,
          individualFloats: sortedFloats,
        );
      }).toList();

      state = AsyncValue.data(updatedItems);
      _updateCache(updatedItems);
    } catch (e) {
      debugPrint('Failed to fetch inventory floats: $e');
    }
  }

  /// Force re-fetch the inventory from Steam (ignores cache).
  Future<void> refresh() async {
    final steamId = ref.read(steamIdProvider);
    debugPrint('refresh() called, steamId: "$steamId"');
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      if (steamId.isEmpty) return [];
      return _fetchFromSteam(steamId);
    });
  }
}

/// Provides only items in the main inventory (not in storage units).
final mainInventoryProvider = Provider<List<CS2Item>>((ref) {
  final itemsAsync = ref.watch(inventoryProvider);
  return itemsAsync.when(
    data: (items) => items.where((item) => item.location == 'inventory').toList(),
    loading: () => <CS2Item>[],
    error: (_, _) => <CS2Item>[],
  );
});

/// Provides storage units from the storage provider.
/// Used by the home screen for stats and portfolio values.
final storageUnitsProvider = Provider<List<StorageUnit>>((ref) {
  final storage = ref.watch(storageProvider);
  return storage.units;
});

/// All storage items flattened from all units.
final _storageItemsProvider = Provider<List<CS2Item>>((ref) {
  final units = ref.watch(storageUnitsProvider);
  return units.expand((u) => u.items).toList();
});

/// Inventory-only Steam Market value.
final inventorySteamValueProvider = Provider<double>((ref) {
  final items = ref.watch(mainInventoryProvider);
  return items.fold(0.0, (sum, item) => sum + (item.currentPrice * item.quantity));
});

/// Inventory-only CSFloat value.
final inventoryCsfloatValueProvider = Provider<double>((ref) {
  final items = ref.watch(mainInventoryProvider);
  return items.fold(0.0, (sum, item) {
    final price = item.csfloatPrice ?? item.currentPrice;
    return sum + (price * item.quantity);
  });
});

/// Inventory-only item count.
final inventoryItemCountProvider = Provider<int>((ref) {
  final items = ref.watch(mainInventoryProvider);
  return items.fold(0, (sum, item) => sum + item.quantity);
});

/// Total portfolio value across all items (Steam Market prices).
/// Includes both main inventory and storage units.
final portfolioValueProvider = Provider<double>((ref) {
  final invValue = ref.watch(inventorySteamValueProvider);
  final storageItems = ref.watch(_storageItemsProvider);
  final storValue = storageItems.fold(0.0, (sum, item) => sum + (item.currentPrice * item.quantity));
  return invValue + storValue;
});

/// Total portfolio value using CSFloat prices where available.
/// Includes both main inventory and storage units.
final csfloatPortfolioValueProvider = Provider<double>((ref) {
  final invValue = ref.watch(inventoryCsfloatValueProvider);
  final storageItems = ref.watch(_storageItemsProvider);
  final storValue = storageItems.fold(0.0, (sum, item) {
    final price = item.csfloatPrice ?? item.currentPrice;
    return sum + (price * item.quantity);
  });
  return invValue + storValue;
});

/// Total number of items (counting quantities).
/// Includes both main inventory and storage units.
final totalItemCountProvider = Provider<int>((ref) {
  final invCount = ref.watch(inventoryItemCountProvider);
  final storageItems = ref.watch(_storageItemsProvider);
  final storCount = storageItems.fold(0, (sum, item) => sum + item.quantity);
  return invCount + storCount;
});

/// Top gainers — items with biggest positive 24h price change.
final topGainersProvider = Provider<List<CS2Item>>((ref) {
  final items = ref.watch(mainInventoryProvider);
  final sorted = [...items]..sort(
    (a, b) => b.priceChange24h.compareTo(a.priceChange24h),
  );
  return sorted.where((i) => i.priceChange24h > 0).take(5).toList();
});

/// Top losers — items with biggest negative 24h price change.
final topLosersProvider = Provider<List<CS2Item>>((ref) {
  final items = ref.watch(mainInventoryProvider);
  final sorted = [...items]..sort(
    (a, b) => a.priceChange24h.compareTo(b.priceChange24h),
  );
  return sorted.where((i) => i.priceChange24h < 0).take(5).toList();
});
