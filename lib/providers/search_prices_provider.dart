import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/cs2_item.dart';
import 'price_provider.dart';

/// Cap on how many items we auto-fetch prices for per list update.
/// Steam search/render has a ~3s delay between requests, so 50 items =
/// ~2.5 minutes worst case. Above this, the UI nudges the user to
/// narrow their filters before we start pulling.
const int searchPriceAutoFetchCap = 50;

/// Per-item price state for the Search tab.
///
/// [steam] and [csfloat] hold prices that have been resolved — a `null`
/// value means "fetched, no listing", while the key being absent means
/// "not yet fetched". [loading] is the set of market_hash_names
/// currently in-flight.
class SearchPrices {
  final Map<String, double?> steam;
  final Map<String, double?> csfloat;
  final Set<String> loading;

  const SearchPrices({
    this.steam = const {},
    this.csfloat = const {},
    this.loading = const {},
  });

  SearchPrices copyWith({
    Map<String, double?>? steam,
    Map<String, double?>? csfloat,
    Set<String>? loading,
  }) {
    return SearchPrices(
      steam: steam ?? this.steam,
      csfloat: csfloat ?? this.csfloat,
      loading: loading ?? this.loading,
    );
  }
}

final searchPricesProvider =
    NotifierProvider<SearchPricesNotifier, SearchPrices>(
  SearchPricesNotifier.new,
);

class SearchPricesNotifier extends Notifier<SearchPrices> {
  // Pending market_hash_names for each service. Each service runs a
  // single-flight drainer so we respect rate limits.
  final List<String> _steamQueue = [];
  final List<String> _csfloatQueue = [];
  bool _steamBusy = false;
  bool _csfloatBusy = false;
  bool _disposed = false;

  @override
  SearchPrices build() {
    ref.keepAlive();
    ref.onDispose(() {
      _disposed = true;
    });
    // Seed from the shared disk caches so inventory-priced items
    // display immediately without any network round-trip.
    _seedFromCaches();
    return const SearchPrices();
  }

  Future<void> _seedFromCaches() async {
    try {
      final steamCache =
          await ref.read(priceServiceProvider).loadCachedPrices();
      final cfCache =
          await ref.read(csfloatServiceProvider).loadCachedPrices();
      if (_disposed) return;
      state = state.copyWith(
        steam: {
          ...steamCache.map((k, v) => MapEntry(k, v as double?)),
          ...state.steam,
        },
        csfloat: {
          ...cfCache.map((k, v) => MapEntry(k, v as double?)),
          ...state.csfloat,
        },
      );
    } catch (e) {
      debugPrint('searchPrices seed error: $e');
    }
  }

  /// Replace the queues with price fetches for the given items.
  /// Items whose prices are already cached (or in flight) are skipped.
  void fetchForItems(List<CS2Item> items) {
    if (items.isEmpty) return;
    _steamQueue
      ..clear()
      ..addAll(items
          .where((i) =>
              !state.steam.containsKey(i.marketHashName) &&
              !_steamQueue.contains(i.marketHashName))
          .map((i) => i.marketHashName));
    _csfloatQueue
      ..clear()
      ..addAll(items
          .where((i) =>
              !state.csfloat.containsKey(i.marketHashName) &&
              !_csfloatQueue.contains(i.marketHashName))
          .map((i) => i.marketHashName));
    if (!_steamBusy && _steamQueue.isNotEmpty) unawaited(_drainSteam());
    if (!_csfloatBusy && _csfloatQueue.isNotEmpty) unawaited(_drainCsfloat());
  }

  Future<void> _drainSteam() async {
    _steamBusy = true;
    final service = ref.read(priceServiceProvider);
    while (_steamQueue.isNotEmpty && !_disposed) {
      final name = _steamQueue.removeAt(0);
      // Seed may have populated this entry after it was queued.
      if (state.steam.containsKey(name)) continue;
      state = state.copyWith(loading: {...state.loading, name});
      try {
        final match = await service.fetchPriceViaSearch(name);
        if (_disposed) return;
        state = state.copyWith(
          steam: {...state.steam, name: match?.price},
          loading: {...state.loading}..remove(name),
        );
      } catch (e) {
        if (_disposed) return;
        state = state.copyWith(
          loading: {...state.loading}..remove(name),
        );
        debugPrint('searchPrices Steam error $name: $e');
      }
      if (_steamQueue.isNotEmpty) {
        // Steam search/render rate-limits hard at ~20/min — keep 3s between calls.
        await Future.delayed(const Duration(seconds: 3));
      }
    }
    _steamBusy = false;
  }

  Future<void> _drainCsfloat() async {
    _csfloatBusy = true;
    final service = ref.read(csfloatServiceProvider);
    while (_csfloatQueue.isNotEmpty && !_disposed) {
      final name = _csfloatQueue.removeAt(0);
      if (state.csfloat.containsKey(name)) continue;
      try {
        final price = await service.fetchPrice(name);
        if (_disposed) return;
        state = state.copyWith(
          csfloat: {...state.csfloat, name: price},
        );
      } catch (e) {
        debugPrint('searchPrices CF error $name: $e');
      }
      if (_csfloatQueue.isNotEmpty) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    _csfloatBusy = false;
  }
}
