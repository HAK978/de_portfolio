import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';
import '../services/csfloat_service.dart';
import '../services/price_service.dart';
import 'inventory_provider.dart';

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
    dev.log('Starting price fetch for ${uniqueNames.length} marketable items');

    state = PriceFetchState(
      isFetching: true,
      total: uniqueNames.length,
      currentItem: 'Starting...',
    );

    final service = ref.read(priceServiceProvider);

    _subscription = service.fetchPrices(uniqueNames).listen(
      (progress) {
        state = state.copyWith(
          fetched: progress.fetched,
          total: progress.total,
          currentItem: progress.currentItem,
        );

        // Merge prices into inventory on each update so the UI
        // updates progressively as prices come in
        ref.read(inventoryProvider.notifier).updatePrices(progress.prices);
      },
      onDone: () {
        dev.log('Price fetch complete: ${state.fetched}/${state.total}');
        state = state.copyWith(isFetching: false);
        _subscription = null;
      },
      onError: (error) {
        dev.log('Price fetch error: $error');
        state = state.copyWith(
          isFetching: false,
          error: error.toString(),
        );
        _subscription = null;
      },
    );
  }

  /// Stops an in-progress price fetch.
  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    state = state.copyWith(isFetching: false);
  }
}

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
      dev.log('Error loading CSFloat API key: $e');
    }
  }

  Future<void> _saveKey(String key) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(key);
    } catch (e) {
      dev.log('Error saving CSFloat API key: $e');
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

  void fetchPrices() {
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

    final uniqueNames = _getMarketableNames(items);
    dev.log('Starting CSFloat price fetch for ${uniqueNames.length} marketable items');

    state = PriceFetchState(
      isFetching: true,
      total: uniqueNames.length,
      currentItem: 'Starting...',
    );

    final service = ref.read(csfloatServiceProvider);

    _subscription = service.fetchPrices(uniqueNames).listen(
      (progress) {
        state = state.copyWith(
          fetched: progress.fetched,
          total: progress.total,
          currentItem: progress.currentItem,
        );
        ref.read(inventoryProvider.notifier).updateCsfloatPrices(progress.prices);
      },
      onDone: () {
        dev.log('CSFloat fetch complete: ${state.fetched}/${state.total}');
        state = state.copyWith(isFetching: false);
        _subscription = null;
      },
      onError: (error) {
        dev.log('CSFloat fetch error: $error');
        state = state.copyWith(
          isFetching: false,
          error: error.toString(),
        );
        _subscription = null;
      },
    );
  }

  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    state = state.copyWith(isFetching: false);
  }
}
