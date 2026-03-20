import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';
import '../models/storage_unit.dart';
import '../services/steam_api_service.dart';

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
        if (id.trim().isNotEmpty) {
          dev.log('Loaded saved Steam ID: $id');
          state = id.trim();
        }
      }
    } catch (e) {
      dev.log('Error loading saved Steam ID: $e');
    }
  }

  Future<void> _saveId(String id) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(id);
    } catch (e) {
      dev.log('Error saving Steam ID: $e');
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
    dev.log('InventoryNotifier.build() called, steamId: "$steamId"');
    if (steamId.isEmpty) return [];

    final service = ref.read(steamApiServiceProvider);

    // Try loading from cache first
    final cached = await service.loadInventoryCache(steamId);
    if (cached != null && cached.isNotEmpty) {
      dev.log('Loaded ${cached.length} items from cache');
      return cached;
    }

    // No cache — fetch from Steam
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
      dev.log('Fetched ${items.length} items from Steam');
      return items;
    } catch (e, stack) {
      dev.log('Error fetching inventory: $e\n$stack');
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
  void updatePrices(Map<String, double> prices) {
    final items = state.when(
      data: (items) => items,
      loading: () => null,
      error: (_, _) => null,
    );
    if (items == null) {
      dev.log('updatePrices: state has no data, skipping');
      return;
    }

    dev.log('updatePrices: updating ${prices.length} prices on ${items.length} items');
    final updatedItems = items.map((item) {
      final price = prices[item.marketHashName];
      if (price != null) {
        return item.copyWith(currentPrice: price);
      }
      return item;
    }).toList();

    state = AsyncValue.data(updatedItems);
    _updateCache(updatedItems);
  }

  /// Updates CSFloat prices separately from Steam Market prices.
  void updateCsfloatPrices(Map<String, double> prices) {
    final items = state.when(
      data: (items) => items,
      loading: () => null,
      error: (_, _) => null,
    );
    if (items == null) {
      dev.log('updateCsfloatPrices: state has no data, skipping');
      return;
    }

    dev.log('updateCsfloatPrices: updating ${prices.length} prices on ${items.length} items');
    final updatedItems = items.map((item) {
      final price = prices[item.marketHashName];
      if (price != null) {
        return item.copyWith(csfloatPrice: price);
      }
      return item;
    }).toList();

    state = AsyncValue.data(updatedItems);
    _updateCache(updatedItems);
  }

  /// Saves current inventory state to cache (preserves prices).
  Future<void> _updateCache(List<CS2Item> items) async {
    final steamId = ref.read(steamIdProvider);
    if (steamId.isEmpty) return;
    final service = ref.read(steamApiServiceProvider);
    await service.saveInventoryCache(steamId, items);
  }

  /// Force re-fetch the inventory from Steam (ignores cache).
  Future<void> refresh() async {
    final steamId = ref.read(steamIdProvider);
    dev.log('refresh() called, steamId: "$steamId"');
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

/// Provides storage units with their items.
/// In Phase 6 this will fetch real storage unit contents.
final storageUnitsProvider = Provider<List<StorageUnit>>((ref) {
  return <StorageUnit>[];
});

/// Total portfolio value across all items (Steam Market prices).
final portfolioValueProvider = Provider<double>((ref) {
  final items = ref.watch(mainInventoryProvider);
  return items.fold(0.0, (sum, item) => sum + (item.currentPrice * item.quantity));
});

/// Total portfolio value using CSFloat prices where available,
/// falling back to Steam Market price for items without CSFloat listings.
final csfloatPortfolioValueProvider = Provider<double>((ref) {
  final items = ref.watch(mainInventoryProvider);
  return items.fold(0.0, (sum, item) {
    final price = item.csfloatPrice ?? item.currentPrice;
    return sum + (price * item.quantity);
  });
});

/// Total number of items (counting quantities).
final totalItemCountProvider = Provider<int>((ref) {
  final items = ref.watch(mainInventoryProvider);
  return items.fold(0, (sum, item) => sum + item.quantity);
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
