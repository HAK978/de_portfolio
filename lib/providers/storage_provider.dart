import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/cs2_item.dart';
import '../models/storage_unit.dart';
import '../services/price_service.dart';
import '../services/storage_service.dart';

/// The base URL for the local storage service.
/// On Android emulator: 10.0.2.2 maps to host localhost.
/// On a real phone on the same Wi-Fi: use the PC's local IP.
final storageServiceUrlProvider = NotifierProvider<StorageServiceUrlNotifier, String>(
  StorageServiceUrlNotifier.new,
);

class StorageServiceUrlNotifier extends Notifier<String> {
  @override
  String build() => 'http://localhost:3456';

  void set(String url) => state = url;
}

/// StorageService instance, rebuilt when URL changes.
final storageServiceProvider = Provider<StorageService>((ref) {
  final url = ref.watch(storageServiceUrlProvider);
  return StorageService(baseUrl: url);
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

  const PricingProgress({required this.fetched, required this.total});

  double get percent => total > 0 ? fetched / total : 0;
}

/// Holds the full storage state: list of units + their contents.
class StorageState {
  final bool isLoading;
  final List<StorageUnit> units;
  final Set<String> loadingCaskets; // casket IDs currently being fetched
  final Set<String> pricingCaskets; // casket IDs currently being priced
  final Map<String, PricingProgress> pricingProgress; // casketId → progress
  final String? error;

  const StorageState({
    this.isLoading = false,
    this.units = const [],
    this.loadingCaskets = const {},
    this.pricingCaskets = const {},
    this.pricingProgress = const {},
    this.error,
  });

  StorageState copyWith({
    bool? isLoading,
    List<StorageUnit>? units,
    Set<String>? loadingCaskets,
    Set<String>? pricingCaskets,
    Map<String, PricingProgress>? pricingProgress,
    String? error,
  }) {
    return StorageState(
      isLoading: isLoading ?? this.isLoading,
      units: units ?? this.units,
      loadingCaskets: loadingCaskets ?? this.loadingCaskets,
      pricingCaskets: pricingCaskets ?? this.pricingCaskets,
      pricingProgress: pricingProgress ?? this.pricingProgress,
      error: error,
    );
  }
}

final storageProvider = NotifierProvider<StorageNotifier, StorageState>(
  StorageNotifier.new,
);

class StorageNotifier extends Notifier<StorageState> {
  @override
  StorageState build() => const StorageState();

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
          items: existing?.items ?? [],
        );
      }).toList();

      state = state.copyWith(isLoading: false, units: units);
      debugPrint('Fetched ${units.length} storage units');
    } catch (e) {
      debugPrint('Failed to fetch caskets: $e');
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Fetch the contents of a specific storage unit.
  /// Called when the user expands a unit card.
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

      // Calculate total value
      final totalValue = grouped.fold(0.0,
          (sum, item) => sum + (item.currentPrice * item.quantity));

      // Update the specific unit
      final updatedUnits = state.units.map((unit) {
        if (unit.id == casketId) {
          return StorageUnit(
            id: unit.id,
            name: unit.name,
            itemCount: unit.itemCount,
            totalValue: totalValue,
            items: grouped,
          );
        }
        return unit;
      }).toList();

      final newLoading = {...state.loadingCaskets}..remove(casketId);
      state = state.copyWith(units: updatedUnits, loadingCaskets: newLoading);
      debugPrint('Loaded $casketId: ${items.length} raw → ${grouped.length} unique items');

      // Auto-fetch prices + images from Steam Market
      _fetchMarketData(casketId, grouped);
    } catch (e) {
      debugPrint('Failed to fetch contents for $casketId: $e');
      final newLoading = {...state.loadingCaskets}..remove(casketId);
      state = state.copyWith(loadingCaskets: newLoading, error: e.toString());
    }
  }

  /// Fetches prices and image URLs from Steam Market for storage items.
  /// Updates items progressively as results come in.
  Future<void> _fetchMarketData(String casketId, List<CS2Item> items) async {
    if (state.pricingCaskets.contains(casketId)) return;

    state = state.copyWith(
      pricingCaskets: {...state.pricingCaskets, casketId},
    );

    final priceService = PriceService();
    final marketHashNames = items.map((i) => i.marketHashName).toList();
    final total = marketHashNames.length;

    state = state.copyWith(
      pricingProgress: {
        ...state.pricingProgress,
        casketId: PricingProgress(fetched: 0, total: total),
      },
    );

    try {
      await for (final results in priceService.fetchMarketData(marketHashNames)) {
        // Update items with prices and images
        final updatedItems = items.map((item) {
          final result = results[item.marketHashName];
          if (result == null) return item;

          return item.copyWith(
            currentPrice: result.price,
            imageUrl: result.iconUrl != null
                ? PriceService.buildImageUrl(result.iconUrl!)
                : item.imageUrl,
          );
        }).toList();

        final totalValue = updatedItems.fold(
            0.0, (sum, item) => sum + (item.currentPrice * item.quantity));

        final updatedUnits = state.units.map((unit) {
          if (unit.id == casketId) {
            return StorageUnit(
              id: unit.id,
              name: unit.name,
              itemCount: unit.itemCount,
              totalValue: totalValue,
              items: updatedItems,
            );
          }
          return unit;
        }).toList();

        state = state.copyWith(
          units: updatedUnits,
          pricingProgress: {
            ...state.pricingProgress,
            casketId: PricingProgress(fetched: results.length, total: total),
          },
        );
      }

      debugPrint('Finished pricing casket $casketId');
    } catch (e) {
      debugPrint('Market data fetch failed for $casketId: $e');
    } finally {
      final newPricing = {...state.pricingCaskets}..remove(casketId);
      final newProgress = {...state.pricingProgress}..remove(casketId);
      state = state.copyWith(
        pricingCaskets: newPricing,
        pricingProgress: newProgress,
      );
    }
  }

  /// Groups items by marketHashName, summing quantities.
  List<CS2Item> _groupItems(List<CS2Item> items) {
    final map = <String, CS2Item>{};
    for (final item in items) {
      final existing = map[item.marketHashName];
      if (existing != null) {
        map[item.marketHashName] = existing.copyWith(
          quantity: existing.quantity + 1,
        );
      } else {
        map[item.marketHashName] = item;
      }
    }
    return map.values.toList()
      ..sort((a, b) => b.quantity.compareTo(a.quantity));
  }
}
