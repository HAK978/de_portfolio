import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'price_service.dart' show PriceFetchProgress;

/// Snapshot of CSFloat's rate-limit headers from the most recent
/// response. Callers can consult [CsfloatService.lastRateLimit] before
/// the next call to throttle precisely instead of guessing.
class CsfloatRateLimit {
  final int limit;
  final int remaining;
  final DateTime reset;

  const CsfloatRateLimit({
    required this.limit,
    required this.remaining,
    required this.reset,
  });

  /// How long until the window resets. Zero if already past.
  Duration timeUntilReset([DateTime? now]) {
    final diff = reset.difference(now ?? DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  @override
  String toString() =>
      'CsfloatRateLimit(remaining=$remaining/$limit, reset=$reset)';
}

/// Fetches the lowest listing price for items on CSFloat Market.
///
/// CSFloat is a peer-to-peer marketplace — prices represent what
/// real sellers are asking, not Steam's median sale price. This
/// often gives a more accurate "street value" for items.
///
/// Key differences from Steam Market:
/// - Prices are in cents (350 = $3.50)
/// - Not all items have listings (no one may be selling right now)
/// - No auth required for reading listings
class CsfloatService {
  static const _baseUrl = 'https://csfloat.com/api/v1/listings';
  static const _delayBetweenRequests = Duration(milliseconds: 1000);
  static const _cacheFileName = 'csfloat_price_cache.json';
  static const _cacheMaxAge = Duration(hours: 1);

  final String? apiKey;

  CsfloatRateLimit? _lastRateLimit;

  /// The rate-limit state CSFloat reported in the most recent response.
  /// Null until the first request returns. The search drainer reads
  /// this before each call and waits until [CsfloatRateLimit.reset]
  /// when [CsfloatRateLimit.remaining] gets low.
  CsfloatRateLimit? get lastRateLimit => _lastRateLimit;

  CsfloatService({this.apiKey});

  /// Parse the x-ratelimit-* headers (present on every CSFloat response,
  /// including 429s and 405s) into [_lastRateLimit].
  void _parseRateLimitHeaders(http.Response r) {
    final limit = int.tryParse(r.headers['x-ratelimit-limit'] ?? '');
    final remaining = int.tryParse(r.headers['x-ratelimit-remaining'] ?? '');
    final resetEpoch = int.tryParse(r.headers['x-ratelimit-reset'] ?? '');
    if (limit == null || remaining == null || resetEpoch == null) return;
    _lastRateLimit = CsfloatRateLimit(
      limit: limit,
      remaining: remaining,
      reset: DateTime.fromMillisecondsSinceEpoch(resetEpoch * 1000),
    );
  }

  /// Fetches the lowest listing price for a single item on CSFloat.
  ///
  /// Returns the price in dollars (converted from cents), or null
  /// if there are no listings for this item.
  Future<double?> fetchPrice(String marketHashName) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'market_hash_name': marketHashName,
      'sort_by': 'lowest_price',
      'type': 'buy_now',
      'limit': '1',
    });

    try {
      final headers = <String, String>{};
      if (apiKey != null) {
        headers['Authorization'] = apiKey!;
      }

      final response = await http.get(uri, headers: headers);
      _parseRateLimitHeaders(response);

      if (response.statusCode == 429) {
        // Wait exactly until the server says the bucket refills (capped
        // to keep UI responsive), then retry once.
        final wait = _lastRateLimit?.timeUntilReset() ?? const Duration(seconds: 5);
        final clamped = Duration(
          seconds: wait.inSeconds.clamp(2, 120),
        );
        debugPrint('CSF 429 RATE LIMITED: $marketHashName — '
            'waiting ${clamped.inSeconds}s until reset');
        await Future.delayed(clamped);
        final retry = await http.get(uri, headers: headers);
        _parseRateLimitHeaders(retry);
        if (retry.statusCode == 200) {
          final price = _parsePriceFromResponse(retry.body);
          debugPrint('CSF RETRY ${price != null ? "OK \$${price.toStringAsFixed(2)}" : "NO LISTING"}: $marketHashName');
          return price;
        }
        debugPrint('CSF RETRY FAILED (${retry.statusCode}): $marketHashName');
        return null;
      }

      if (response.statusCode != 200) {
        debugPrint('CSF ERROR ${response.statusCode}: $marketHashName');
        return null;
      }

      final price = _parsePriceFromResponse(response.body);
      if (price == null) {
        debugPrint('CSF NO LISTING: $marketHashName');
      }
      return price;
    } catch (e) {
      debugPrint('CSF EXCEPTION: $marketHashName — $e');
      return null;
    }
  }

  /// Parses a CSFloat API response body to extract the lowest listing price.
  double? _parsePriceFromResponse(String body) {
    final data = jsonDecode(body);

    List<dynamic>? listings;
    if (data is List) {
      listings = data;
    } else if (data is Map<String, dynamic>) {
      listings = data['data'] as List<dynamic>?;
    }

    if (listings == null || listings.isEmpty) return null;

    final listing = listings[0] as Map<String, dynamic>;
    final priceInCents = listing['price'] as int?;

    if (priceInCents == null) return null;

    return priceInCents / 100.0;
  }

  /// Fetches CSFloat prices for a list of items, yielding progress.
  ///
  /// Reuses the same PriceFetchProgress class from price_service.dart
  /// so the UI can show the same progress pattern.
  Stream<PriceFetchProgress> fetchPrices(List<String> marketHashNames) async* {
    debugPrint('═══ CSFloat fetch start ═══');
    debugPrint('CSF API key: ${apiKey != null ? "YES" : "NO KEY"}');
    debugPrint('CSF items requested: ${marketHashNames.length}');

    final prices = <String, double>{};

    // Load cached prices first
    final cached = await loadCachedPrices();
    prices.addAll(cached);

    final toFetch = marketHashNames
        .where((name) => !cached.containsKey(name))
        .toList();

    // Only count cached items that are in the current request
    int fetchedCount = marketHashNames.length - toFetch.length;

    debugPrint('CSF cache hits: $fetchedCount/${marketHashNames.length}, to fetch: ${toFetch.length}');

    if (fetchedCount > 0) {
      yield PriceFetchProgress(
        fetched: fetchedCount,
        total: marketHashNames.length,
        currentItem: 'Loaded $fetchedCount cached CSFloat prices',
        prices: Map.of(prices),
      );
    }

    int newPriced = 0;
    int noListing = 0;

    for (final name in toFetch) {
      // Preflight throttle using the rate-limit headers from the last
      // response. If we're nearly out of budget, sleep until the
      // window resets — same pattern the search drainer uses, applied
      // here so the inventory + storage batch fetches don't blindly
      // burn the remaining quota and trip 429s.
      final rl = _lastRateLimit;
      if (rl != null && rl.remaining <= 2) {
        final wait = rl.timeUntilReset();
        if (wait > Duration.zero) {
          final clamped = Duration(
            seconds: (wait.inSeconds + 1).clamp(1, 120),
          );
          debugPrint('CSF batch preflight: remaining=${rl.remaining}, '
              'waiting ${clamped.inSeconds}s until reset');
          await Future.delayed(clamped);
        }
      }

      final price = await fetchPrice(name);

      if (price != null) {
        prices[name] = price;
        newPriced++;
      } else {
        noListing++;
      }

      fetchedCount++;

      yield PriceFetchProgress(
        fetched: fetchedCount,
        total: marketHashNames.length,
        currentItem: name,
        prices: Map.of(prices),
      );

      if (name != toFetch.last) {
        await Future.delayed(_delayBetweenRequests);
      }
    }

    // Count how many of the requested items actually have prices
    final totalPriced = marketHashNames.where((n) => prices.containsKey(n)).length;
    debugPrint('═══ CSFloat fetch done ═══');
    debugPrint('CSF results: $totalPriced/${marketHashNames.length} items have prices');
    debugPrint('CSF this run: $newPriced new prices, $noListing no listing');

    await _savePriceCache(prices);
  }

  Future<Map<String, double>> loadCachedPrices() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFileName');

      if (!file.existsSync()) return {};

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      final timestamp = data['timestamp'] as int? ?? 0;
      final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(cacheTime) > _cacheMaxAge) {
        debugPrint('CSFloat price cache expired');
        return {};
      }

      final prices = (data['prices'] as Map<String, dynamic>?)
              ?.map((key, value) => MapEntry(key, (value as num).toDouble())) ??
          {};

      debugPrint('Loaded ${prices.length} CSFloat prices from cache');
      return prices;
    } catch (e) {
      debugPrint('Error loading CSFloat price cache: $e');
      return {};
    }
  }

  Future<void> _savePriceCache(Map<String, double> prices) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFileName');

      final data = {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'prices': prices,
      };

      await file.writeAsString(jsonEncode(data));
      debugPrint('Saved ${prices.length} CSFloat prices to cache');
    } catch (e) {
      debugPrint('Error saving CSFloat price cache: $e');
    }
  }
}
