import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';
import '../models/storage_unit.dart';
import '../services/csfloat_service.dart';
import '../services/firestore_service.dart' show ServerPriceData;
import '../services/price_service.dart';
import '../services/secure_setting.dart';
import '../services/storage_service.dart';
import 'auth_provider.dart';
import 'price_provider.dart';

/// The base URL for the storage service.
final storageServiceUrlProvider = NotifierProvider<StorageServiceUrlNotifier, String>(
  StorageServiceUrlNotifier.new,
);

class StorageServiceUrlNotifier extends Notifier<String> {
  static const _fileName = 'storage_service_url.txt';

  @override
  String build() {
    _loadSaved();
    return 'https://harshcs2.duckdns.org';
  }

  void set(String url) {
    state = url;
    _save(url);
  }

  Future<void> _loadSaved() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) {
        final url = await file.readAsString();
        if (url.trim().isNotEmpty) state = url.trim();
      }
    } catch (e) {
      debugPrint('Error loading storage service URL: $e');
    }
  }

  Future<void> _save(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(url);
    } catch (e) {
      debugPrint('Error saving storage service URL: $e');
    }
  }
}

/// API key for the remote storage service.
final storageApiKeyProvider = NotifierProvider<StorageApiKeyNotifier, String>(
  StorageApiKeyNotifier.new,
);

/// The storage-service API key grants access to the VM (and so to the
/// owner's Steam storage), so it lives in secure storage.
class StorageApiKeyNotifier extends SecureSettingNotifier {
  @override
  SecureSetting get setting => Secrets.storageApiKey;
}

/// StorageService instance, rebuilt when URL or API key changes.
final storageServiceProvider = Provider<StorageService>((ref) {
  final url = ref.watch(storageServiceUrlProvider);
  final apiKey = ref.watch(storageApiKeyProvider);
  return StorageService(baseUrl: url, apiKey: apiKey.isNotEmpty ? apiKey : null);
});

/// Connection status — checked when user taps "Connect".
final storageStatusProvider = FutureProvider.autoDispose<StorageStatus>((ref) async {
  final service = ref.read(storageServiceProvider);
  return service.getStatus();
});

/// Progress of pricing a storage unit's items.
class PricingProgress {
  final int fetched;
  final int total;
  final String label; // "Steam" or "CSFloat"

  const PricingProgress({required this.fetched, required this.total, this.label = 'Steam'});

  double get percent => total > 0 ? fetched / total : 0;
}

/// Holds the full storage state: list of units + their contents.
class StorageState {
  final bool isLoading;
  final List<StorageUnit> units;
  final Set<String> loadingCaskets;
  final Set<String> pricingCaskets;
  final Map<String, PricingProgress> pricingProgress;
  final String? error;

  /// Cumulative item-level progress across all storage units in the
  /// CURRENT batch (set by [fetchAllStorageSteamPrices] /
  /// [fetchAllStorageCsfloatPrices]). Lets the home progress bar show
  /// inventory + storage as a single fetched/total pair.
  final int steamBatchFetched;
  final int steamBatchTotal;
  final int csfloatBatchFetched;
  final int csfloatBatchTotal;

  const StorageState({
    this.isLoading = false,
    this.units = const [],
    this.loadingCaskets = const {},
    this.pricingCaskets = const {},
    this.pricingProgress = const {},
    this.error,
    this.steamBatchFetched = 0,
    this.steamBatchTotal = 0,
    this.csfloatBatchFetched = 0,
    this.csfloatBatchTotal = 0,
  });

  StorageState copyWith({
    bool? isLoading,
    List<StorageUnit>? units,
    Set<String>? loadingCaskets,
    Set<String>? pricingCaskets,
    Map<String, PricingProgress>? pricingProgress,
    String? error,
    int? steamBatchFetched,
    int? steamBatchTotal,
    int? csfloatBatchFetched,
    int? csfloatBatchTotal,
  }) {
    return StorageState(
      isLoading: isLoading ?? this.isLoading,
      units: units ?? this.units,
      loadingCaskets: loadingCaskets ?? this.loadingCaskets,
      pricingCaskets: pricingCaskets ?? this.pricingCaskets,
      pricingProgress: pricingProgress ?? this.pricingProgress,
      error: error,
      steamBatchFetched: steamBatchFetched ?? this.steamBatchFetched,
      steamBatchTotal: steamBatchTotal ?? this.steamBatchTotal,
      csfloatBatchFetched: csfloatBatchFetched ?? this.csfloatBatchFetched,
      csfloatBatchTotal: csfloatBatchTotal ?? this.csfloatBatchTotal,
    );
  }
}

final storageProvider = NotifierProvider<StorageNotifier, StorageState>(
  StorageNotifier.new,
);

/// Most distinct storage item names a user can list for server pricing
/// (the same cap is enforced in firestore.rules).
const maxStorageItemNamesForPricing = 5000;

/// The distinct item names across all loaded storage units, sorted, for the
/// server's price watch list.
List<String> storageItemNamesForPricing(List<StorageUnit> units) {
  final names = <String>{
    for (final unit in units)
      for (final item in unit.items)
        if (item.marketHashName.isNotEmpty) item.marketHashName,
  }.toList()
    ..sort();
  return names.length > maxStorageItemNamesForPricing
      ? names.sublist(0, maxStorageItemNamesForPricing)
      : names;
}

/// Applies server-refreshed prices and 24h/7d/30d changes to storage items,
/// recomputing each changed unit's totals. Unchanged units are returned as
/// the same objects. Returns null if nothing changed.
List<StorageUnit>? applyServerPricesToUnits(
  List<StorageUnit> units,
  Map<String, ServerPriceData> prices,
) {
  var anyChanged = false;
  final updated = units.map((unit) {
    var unitChanged = false;
    final items = unit.items.map((item) {
      final sp = prices[item.marketHashName];
      if (sp == null) return item;
      final newCurrent = sp.currentPrice ?? item.currentPrice;
      final newCsfloat = sp.csfloatPrice ?? item.csfloatPrice;
      if (newCurrent == item.currentPrice &&
          newCsfloat == item.csfloatPrice &&
          sp.priceChange24h == item.priceChange24h &&
          sp.priceChange7d == item.priceChange7d &&
          sp.priceChange30d == item.priceChange30d) {
        return item;
      }
      unitChanged = true;
      return item.copyWith(
        currentPrice: newCurrent,
        csfloatPrice: newCsfloat,
        priceChange24h: sp.priceChange24h,
        priceChange7d: sp.priceChange7d,
        priceChange30d: sp.priceChange30d,
      );
    }).toList();
    if (!unitChanged) return unit;
    anyChanged = true;
    return StorageUnit(
      id: unit.id,
      name: unit.name,
      itemCount: unit.itemCount,
      totalValue: items.fold(0.0, (sum, i) => sum + (i.currentPrice * i.quantity)),
      totalCsfloatValue: items.fold(0.0, (sum, i) => sum + ((i.csfloatPrice ?? 0) * i.quantity)),
      items: items,
    );
  }).toList();
  return anyChanged ? updated : null;
}

class StorageNotifier extends Notifier<StorageState> {
  static const _cachePrefix = 'storage_cache_';
  static const _unitsIndexFile = 'storage_units_index.json';

  // Cancellation flags for the price-fetch streams. Flipping to true
  // causes the active `await for` to bail at the next yield (or
  // between units in the per-unit loops). Reset to false at the start
  // of every new fetch.
  bool _steamCanceled = false;
  bool _csfloatCanceled = false;

  // The item-name list last shared with the server (see
  // syncItemNamesForPricing), so unchanged lists aren't rewritten.
  String? _syncedNames;

  @override
  StorageState build() {
    // Sign-in is restored asynchronously on startup, so the name sync may
    // have been skipped; retry it once the user is signed in.
    ref.listen(authProvider.select((s) => s.isLoggedIn), (_, loggedIn) {
      if (loggedIn) {
        syncItemNamesForPricing();
      } else {
        _syncedNames = null;
      }
    });
    // Fire off async cache load — state starts empty, updates when cache loads
    _loadCachedUnits();
    return const StorageState();
  }

  /// Shares the distinct item names in the loaded storage units with the
  /// server, so its scheduled price job covers them too. Skips the write
  /// when the list hasn't changed since the last successful sync.
  Future<void> syncItemNamesForPricing() async {
    final names = storageItemNamesForPricing(state.units);
    if (names.isEmpty) return;
    final signature = names.join('\n');
    if (signature == _syncedNames) return;
    try {
      if (await ref.read(firestoreServiceProvider).saveStorageItemNames(names)) {
        _syncedNames = signature;
      }
    } catch (e) {
      debugPrint('Storage item name sync failed: $e');
    }
  }

  /// Applies server-refreshed prices (loaded once on app open by
  /// InventoryNotifier.applyServerPrices) to storage items, and saves the
  /// caches of the units that changed.
  Future<void> applyServerPrices(Map<String, ServerPriceData> prices) async {
    final before = state.units;
    final updated = applyServerPricesToUnits(before, prices);
    if (updated == null) return;
    state = state.copyWith(units: updated);
    for (var i = 0; i < updated.length; i++) {
      if (i >= before.length || !identical(updated[i], before[i])) {
        await _saveCache(updated[i].id, updated[i].items);
      }
    }
  }

  /// Stop any in-flight Steam Market or CSFloat price fetches across
  /// all loaded storage units. The Cancel button on the home price
  /// cards calls this in addition to cancelling the inventory stream.
  void cancelAllPrices() {
    _steamCanceled = true;
    _csfloatCanceled = true;
    state = state.copyWith(
      pricingCaskets: const {},
      pricingProgress: const {},
      steamBatchFetched: 0,
      steamBatchTotal: 0,
      csfloatBatchFetched: 0,
      csfloatBatchTotal: 0,
    );
  }

  /// Seed the Steam batch total upfront when an inventory price fetch
  /// kicks off, so the home progress bar covers (inventory + storage)
  /// from the start instead of jumping mid-progress.
  void seedSteamBatchTotal(int total) {
    state = state.copyWith(steamBatchFetched: 0, steamBatchTotal: total);
  }

  void seedCsfloatBatchTotal(int total) {
    state = state.copyWith(csfloatBatchFetched: 0, csfloatBatchTotal: total);
  }

  /// Loads cached unit index + each unit's cached items from disk.
  /// Called automatically on build() so portfolio values are available on startup.
  Future<void> _loadCachedUnits() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final indexFile = File('${dir.path}/$_unitsIndexFile');
      if (!indexFile.existsSync()) return;

      final content = await indexFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final unitsList = data['units'] as List<dynamic>;

      final units = <StorageUnit>[];
      for (final unitJson in unitsList) {
        final id = unitJson['id'] as String;
        final name = unitJson['name'] as String;
        final itemCount = unitJson['itemCount'] as int;

        // Load cached items for this unit
        final cached = await _loadCache(id);
        final items = cached.values.toList();
        final totalValue = items.fold(
            0.0, (sum, item) => sum + (item.currentPrice * item.quantity));
        final totalCsfloatValue = items.fold(
            0.0, (sum, item) => sum + ((item.csfloatPrice ?? 0) * item.quantity));

        units.add(StorageUnit(
          id: id,
          name: name,
          itemCount: itemCount,
          totalValue: totalValue,
          totalCsfloatValue: totalCsfloatValue,
          items: items,
        ));
      }

      if (units.isNotEmpty) {
        state = state.copyWith(units: units);
        syncItemNamesForPricing();
      }
    } catch (e) {
      debugPrint('Failed to load cached storage units: $e');
    }
  }

  /// Saves the units index (id, name, itemCount) to disk.
  Future<void> _saveUnitsIndex() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_unitsIndexFile');
      final data = {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'units': state.units.map((u) => {
          'id': u.id,
          'name': u.name,
          'itemCount': u.itemCount,
        }).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Failed to save storage units index: $e');
    }
  }

  /// Fetch the list of storage units from the GC service.
  Future<void> fetchCaskets() async {
    if (state.isLoading) return;

    state = state.copyWith(isLoading: true, error: null);

    try {
      final service = ref.read(storageServiceProvider);
      final caskets = await service.getCaskets();

      // Preserve already-loaded contents
      final existingUnits = {for (final u in state.units) u.id: u};

      final units = caskets.map((c) {
        final existing = existingUnits[c.casketId];
        return StorageUnit(
          id: c.casketId,
          name: c.name,
          itemCount: c.itemCount,
          totalValue: existing?.totalValue ?? 0,
          totalCsfloatValue: existing?.totalCsfloatValue ?? 0,
          items: existing?.items ?? [],
        );
      }).toList();

      state = state.copyWith(isLoading: false, units: units);
      await _saveUnitsIndex();
    } catch (e) {
      debugPrint('Failed to fetch caskets: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Fetch the contents of a specific storage unit.
  /// Loads cached prices/images if available, does NOT auto-fetch prices.
  Future<void> fetchContents(String casketId) async {
    if (state.loadingCaskets.contains(casketId)) return;

    state = state.copyWith(
      loadingCaskets: {...state.loadingCaskets, casketId},
    );

    try {
      final service = ref.read(storageServiceProvider);
      final items = await service.getCasketContents(casketId);

      // Group by marketHashName and sum quantities
      final grouped = _groupItems(items);

      // Apply cached prices/images if available
      final cached = await _loadCache(casketId);
      final withCached = _applyCachedData(grouped, cached);

      final totalValue = withCached.fold(
          0.0, (sum, item) => sum + (item.currentPrice * item.quantity));
      final totalCsfloatValue = withCached.fold(
          0.0, (sum, item) => sum + ((item.csfloatPrice ?? 0) * item.quantity));

      final updatedUnits = state.units.map((unit) {
        if (unit.id == casketId) {
          return StorageUnit(
            id: unit.id,
            name: unit.name,
            itemCount: unit.itemCount,
            totalValue: totalValue,
            totalCsfloatValue: totalCsfloatValue,
            items: withCached,
          );
        }
        return unit;
      }).toList();

      final newLoading = {...state.loadingCaskets}..remove(casketId);
      state = state.copyWith(units: updatedUnits, loadingCaskets: newLoading);

      // Save to cache so collection data persists across restarts
      await _saveCache(casketId, withCached);
      syncItemNamesForPricing();

      // Auto-refresh prices if cache is older than 24 hours
      if (await _isCacheStale(casketId)) {
        debugPrint('[$casketId] Cache is stale — auto-refreshing prices');
        fetchAllPrices(casketId);
      }
    } catch (e) {
      debugPrint('Failed to fetch contents for $casketId: $e');
      final newLoading = {...state.loadingCaskets}..remove(casketId);
      state = state.copyWith(loadingCaskets: newLoading, error: e.toString());
    }
  }

  /// Returns true if the stored cache is older than 24 hours.
  Future<bool> _isCacheStale(String casketId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cachePrefix$casketId.json');
      if (!file.existsSync()) return false; // no cache = no items = don't auto-fetch
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final ts = data['timestamp'] as int?;
      if (ts == null) return false;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      return age > const Duration(hours: 24).inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// Manually fetch Steam Market prices + images for a storage unit.
  Future<void> fetchSteamPrices(String casketId) async {
    final units = state.units.where((u) => u.id == casketId);
    if (units.isEmpty) return;
    final unit = units.first;
    if (unit.items.isEmpty) return;
    // Reset the cancel flag at the entry of every direct (non-batch)
    // fetch — otherwise a previously-cancelled session leaves the flag
    // stuck at true and the new fetch's loop breaks on first iteration.
    _steamCanceled = false;
    await _fetchMarketData(casketId, unit.items);
  }

  /// Manually fetch CSFloat prices for a storage unit.
  Future<void> fetchCsfloatPrices(String casketId) async {
    final units = state.units.where((u) => u.id == casketId);
    if (units.isEmpty) return;
    final unit = units.first;
    if (unit.items.isEmpty) return;
    _csfloatCanceled = false;
    await _fetchCsfloatData(casketId, unit.items);
  }

  /// Fetch Steam prices for every loaded storage unit (called from home screen).
  Future<void> fetchAllStorageSteamPrices() async {
    _steamCanceled = false;
    final total = state.units.fold<int>(
        0,
        (sum, u) =>
            sum + u.items.map((i) => i.marketHashName).toSet().length);
    state = state.copyWith(
      steamBatchFetched: 0,
      steamBatchTotal: total,
    );
    for (final unit in state.units) {
      if (_steamCanceled) break;
      if (unit.items.isNotEmpty) {
        await _fetchMarketData(unit.id, unit.items);
      }
    }
    state = state.copyWith(
      steamBatchFetched: 0,
      steamBatchTotal: 0,
    );
    saveLastPriceFetchTimestamp();
  }

  /// Fetch CSFloat prices for every loaded storage unit (called from home screen).
  Future<void> fetchAllStorageCsfloatPrices() async {
    _csfloatCanceled = false;
    final total = state.units.fold<int>(
        0,
        (sum, u) =>
            sum + u.items.map((i) => i.marketHashName).toSet().length);
    state = state.copyWith(
      csfloatBatchFetched: 0,
      csfloatBatchTotal: total,
    );
    for (final unit in state.units) {
      if (_csfloatCanceled) break;
      if (unit.items.isNotEmpty) {
        await _fetchCsfloatData(unit.id, unit.items);
      }
    }
    state = state.copyWith(
      csfloatBatchFetched: 0,
      csfloatBatchTotal: 0,
    );
  }

  /// Fetch Steam + CSFloat prices in parallel.
  Future<void> fetchAllPrices(String casketId) async {
    final units = state.units.where((u) => u.id == casketId);
    if (units.isEmpty) return;
    final unit = units.first;
    if (unit.items.isEmpty) return;
    _steamCanceled = false;
    _csfloatCanceled = false;
    await Future.wait([
      _fetchMarketData(casketId, unit.items),
      _fetchCsfloatData(casketId, unit.items),
    ]);
    saveLastPriceFetchTimestamp();
  }

  /// Fetches prices and image URLs from Steam Market.
  Future<void> _fetchMarketData(String casketId, List<CS2Item> items) async {
    final key = '${casketId}_steam';
    if (state.pricingCaskets.contains(key)) return;

    state = state.copyWith(
      pricingCaskets: {...state.pricingCaskets, key},
    );

    final priceService = PriceService();
    // Dedupe so we don't waste API calls on duplicate hash names
    // within the same unit (and so the per-unit total matches what
    // the fetcher actually yields).
    final marketHashNames =
        items.map((i) => i.marketHashName).toSet().toList();
    final total = marketHashNames.length;

    state = state.copyWith(
      pricingProgress: {
        ...state.pricingProgress,
        key: PricingProgress(fetched: 0, total: total, label: 'Steam'),
      },
    );

    try {
      var lastResultCount = 0;
      await for (final results in priceService.fetchMarketData(marketHashNames)) {
        if (_steamCanceled) break;
        // Build a map of updates to merge
        final steamUpdates = <String, MarketItemResult>{};
        for (final result in results.entries) {
          steamUpdates[result.key] = result.value;
        }

        _mergeItemUpdates(casketId, (item) {
          final result = steamUpdates[item.marketHashName];
          if (result == null) return item;
          return item.copyWith(
            currentPrice: result.price,
            imageUrl: result.iconUrl != null
                ? PriceService.buildImageUrl(result.iconUrl!)
                : item.imageUrl,
          );
        }, recalcValue: true);

        // Add only the new items priced since the last yield to the
        // cumulative batch counter — the storage stream emits the
        // running total per unit, not just the delta.
        final delta = results.length - lastResultCount;
        lastResultCount = results.length;
        state = state.copyWith(
          pricingProgress: {
            ...state.pricingProgress,
            key: PricingProgress(fetched: results.length, total: total, label: 'Steam'),
          },
          steamBatchFetched: state.steamBatchFetched + delta,
        );
      }

      // Save to cache after steam prices complete
      final finalUnits = state.units.where((u) => u.id == casketId);
      if (finalUnits.isNotEmpty) {
        await _saveCache(casketId, finalUnits.first.items);
      }
    } catch (e) {
      debugPrint('Steam market data fetch failed for $casketId: $e');
    } finally {
      final newPricing = {...state.pricingCaskets}..remove(key);
      final newProgress = {...state.pricingProgress}..remove(key);
      state = state.copyWith(
        pricingCaskets: newPricing,
        pricingProgress: newProgress,
      );
    }
  }

  /// Fetches CSFloat prices for storage items.
  Future<void> _fetchCsfloatData(String casketId, List<CS2Item> items) async {
    final key = '${casketId}_csfloat';
    if (state.pricingCaskets.contains(key)) return;

    // The CSFloat API key loads from secure storage at startup; wait for
    // that load if a fetch starts right after launch.
    var apiKey = ref.read(csfloatApiKeyProvider);
    if (apiKey.isEmpty) {
      await ref.read(csfloatApiKeyProvider.notifier).loaded;
      apiKey = ref.read(csfloatApiKeyProvider);
    }
    final service = CsfloatService(apiKey: apiKey.isNotEmpty ? apiKey : null);

    state = state.copyWith(
      pricingCaskets: {...state.pricingCaskets, key},
    );

    // Dedupe so we don't waste API calls on duplicate hash names
    // within the same unit (and so the per-unit total matches what
    // the fetcher actually yields).
    final marketHashNames =
        items.map((i) => i.marketHashName).toSet().toList();
    final total = marketHashNames.length;

    state = state.copyWith(
      pricingProgress: {
        ...state.pricingProgress,
        key: PricingProgress(fetched: 0, total: total, label: 'CSFloat'),
      },
    );

    try {
      int fetched = 0;

      var lastFetched = 0;
      await for (final progress in service.fetchPrices(marketHashNames)) {
        if (_csfloatCanceled) break;
        fetched = progress.fetched;

        final prices = progress.prices;
        _mergeItemUpdates(casketId, (item) {
          final price = prices[item.marketHashName];
          if (price == null) return item;
          return item.copyWith(csfloatPrice: price);
        }, recalcValue: true);

        final delta = fetched - lastFetched;
        lastFetched = fetched;
        state = state.copyWith(
          pricingProgress: {
            ...state.pricingProgress,
            key: PricingProgress(fetched: fetched, total: total, label: 'CSFloat'),
          },
          csfloatBatchFetched: state.csfloatBatchFetched + delta,
        );
      }

      final finalUnits = state.units.where((u) => u.id == casketId);
      if (finalUnits.isNotEmpty) {
        await _saveCache(casketId, finalUnits.first.items);
      }
    } catch (e) {
      debugPrint('CSFloat data fetch failed for $casketId: $e');
    } finally {
      final newPricing = {...state.pricingCaskets}..remove(key);
      final newProgress = {...state.pricingProgress}..remove(key);
      state = state.copyWith(
        pricingCaskets: newPricing,
        pricingProgress: newProgress,
      );
    }
  }

  /// Merges updates into the current state items for a casket.
  /// Reads the latest items from state so parallel fetches don't overwrite each other.
  void _mergeItemUpdates(String casketId, CS2Item Function(CS2Item) updater, {bool recalcValue = false}) {
    final currentUnits = state.units.where((u) => u.id == casketId);
    if (currentUnits.isEmpty) return;
    final currentUnit = currentUnits.first;
    final updatedItems = currentUnit.items.map(updater).toList();

    final totalValue = recalcValue
        ? updatedItems.fold(0.0, (sum, item) => sum + (item.currentPrice * item.quantity))
        : currentUnit.totalValue;
    final totalCsfloatValue = recalcValue
        ? updatedItems.fold(0.0, (sum, item) => sum + ((item.csfloatPrice ?? 0) * item.quantity))
        : currentUnit.totalCsfloatValue;

    final updatedUnits = state.units.map((unit) {
      if (unit.id == casketId) {
        return StorageUnit(
          id: unit.id,
          name: unit.name,
          itemCount: unit.itemCount,
          totalValue: totalValue,
          totalCsfloatValue: totalCsfloatValue,
          items: updatedItems,
        );
      }
      return unit;
    }).toList();

    state = state.copyWith(units: updatedUnits);
  }

  // ── Caching ──

  /// Saves storage items (with prices/images) to disk.
  Future<void> _saveCache(String casketId, List<CS2Item> items) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cachePrefix$casketId.json');
      final data = {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'items': items.map((i) => i.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Failed to save storage cache: $e');
    }
  }

  /// Loads cached storage items from disk.
  /// Returns a map of marketHashName → cached CS2Item.
  Future<Map<String, CS2Item>> _loadCache(String casketId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cachePrefix$casketId.json');
      if (!file.existsSync()) return {};

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final itemsList = data['items'] as List<dynamic>;

      final map = <String, CS2Item>{};
      for (final json in itemsList) {
        final item = CS2Item.fromJson(json as Map<String, dynamic>);
        map[item.marketHashName] = item;
      }
      return map;
    } catch (e) {
      debugPrint('Failed to load storage cache: $e');
      return {};
    }
  }

  /// Applies cached prices/images to freshly fetched items.
  List<CS2Item> _applyCachedData(List<CS2Item> items, Map<String, CS2Item> cached) {
    if (cached.isEmpty) return items;

    return items.map((item) {
      final cachedItem = cached[item.marketHashName];
      if (cachedItem == null) return item;

      return item.copyWith(
        currentPrice: cachedItem.currentPrice,
        csfloatPrice: cachedItem.csfloatPrice,
        imageUrl: cachedItem.imageUrl.isNotEmpty ? cachedItem.imageUrl : item.imageUrl,
      );
    }).toList();
  }

  /// Groups items by marketHashName, summing quantities and collecting floats.
  List<CS2Item> _groupItems(List<CS2Item> items) {
    final map = <String, CS2Item>{};
    final floats = <String, List<double>>{};
    for (final item in items) {
      final key = item.marketHashName;
      if (item.floatValue != null) {
        (floats[key] ??= []).add(item.floatValue!);
      }
      final existing = map[key];
      if (existing != null) {
        map[key] = existing.copyWith(
          quantity: existing.quantity + 1,
        );
      } else {
        map[key] = item;
      }
    }
    // Attach sorted individual floats to each grouped item
    return map.entries.map((e) {
      final sortedFloats = floats[e.key] ?? [];
      sortedFloats.sort();
      return e.value.copyWith(individualFloats: sortedFloats);
    }).toList()
      ..sort((a, b) => b.quantity.compareTo(a.quantity));
  }
}
