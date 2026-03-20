import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Result of a price lookup for a single item.
class PriceResult {
  final String marketHashName;
  final double? lowestPrice;
  final double? medianPrice;
  final int? volume;

  const PriceResult({
    required this.marketHashName,
    this.lowestPrice,
    this.medianPrice,
    this.volume,
  });
}

/// Progress update emitted during a batch price fetch.
class PriceFetchProgress {
  final int fetched;
  final int total;
  final String currentItem;
  final Map<String, double> prices; // all prices fetched so far

  const PriceFetchProgress({
    required this.fetched,
    required this.total,
    required this.currentItem,
    required this.prices,
  });

  double get percent => total > 0 ? fetched / total : 0;
}

/// Fetches item prices from the Steam Community Market.
///
/// The endpoint returns prices as formatted strings like "$3.50"
/// which we parse into doubles. Rate limited to ~20 requests/min,
/// so we wait 3 seconds between requests to stay safe.
class PriceService {
  static const _baseUrl =
      'https://steamcommunity.com/market/priceoverview/';
  static const _delayBetweenRequests = Duration(milliseconds: 1000);
  static const _cacheFileName = 'price_cache.json';
  static const _cacheMaxAge = Duration(hours: 1);

  /// Fetches the price for a single item from the Steam Market.
  ///
  /// Returns null if the item has no market listing (e.g., agents,
  /// graffiti, or items that can't be sold on the market).
  Future<PriceResult?> fetchPrice(String marketHashName) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'appid': '730',
      'currency': '1', // USD
      'market_hash_name': marketHashName,
    });

    try {
      final response = await http.get(uri);

      if (response.statusCode == 429) {
        // Rate limited — wait longer and retry once
        dev.log('Rate limited, waiting 5s before retry: $marketHashName');
        await Future.delayed(const Duration(seconds: 5));
        final retry = await http.get(uri);
        if (retry.statusCode == 200) {
          final retryData = jsonDecode(retry.body) as Map<String, dynamic>;
          if (retryData['success'] == true) {
            return PriceResult(
              marketHashName: marketHashName,
              lowestPrice: _parsePrice(retryData['lowest_price'] as String?),
              medianPrice: _parsePrice(retryData['median_price'] as String?),
              volume: int.tryParse(
                (retryData['volume'] as String?)?.replaceAll(',', '') ?? '',
              ),
            );
          }
        }
        return null;
      }

      if (response.statusCode != 200) {
        dev.log('Price fetch failed (${response.statusCode}) for: $marketHashName');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] != true) {
        dev.log('Price API returned success=false for: $marketHashName');
        return null;
      }

      return PriceResult(
        marketHashName: marketHashName,
        lowestPrice: _parsePrice(data['lowest_price'] as String?),
        medianPrice: _parsePrice(data['median_price'] as String?),
        volume: int.tryParse(
          (data['volume'] as String?)?.replaceAll(',', '') ?? '',
        ),
      );
    } catch (e) {
      dev.log('Error fetching price for $marketHashName: $e');
      return null;
    }
  }

  /// Fetches prices for a list of items, yielding progress updates.
  ///
  /// This is a Stream — it emits a [PriceFetchProgress] after each
  /// item is fetched, so the UI can show "47/153 fetched".
  /// Unlike a Future (which gives you one result at the end), a Stream
  /// gives you multiple values over time using `yield`.
  ///
  /// The `async*` keyword marks this as an async generator — it can
  /// both `await` futures and `yield` values to the stream.
  Stream<PriceFetchProgress> fetchPrices(List<String> marketHashNames) async* {
    final prices = <String, double>{};

    // Load cached prices first
    final cached = await loadCachedPrices();
    prices.addAll(cached);

    // Filter out items that already have a cached price
    final toFetch = marketHashNames
        .where((name) => !cached.containsKey(name))
        .toList();

    dev.log('Price fetch: ${cached.length} cached, ${toFetch.length} to fetch');

    // Yield initial progress with cached prices
    if (cached.isNotEmpty) {
      yield PriceFetchProgress(
        fetched: cached.length,
        total: marketHashNames.length,
        currentItem: 'Loaded ${cached.length} cached prices',
        prices: Map.of(prices),
      );
    }

    int fetchedCount = cached.length;

    for (final name in toFetch) {
      final result = await fetchPrice(name);

      if (result != null) {
        // Use lowest_price if available, fall back to median_price
        final price = result.lowestPrice ?? result.medianPrice;
        if (price != null) {
          prices[name] = price;
        }
      }

      fetchedCount++;

      yield PriceFetchProgress(
        fetched: fetchedCount,
        total: marketHashNames.length,
        currentItem: name,
        prices: Map.of(prices),
      );

      // Rate limit: wait between requests (skip delay for the last item)
      if (name != toFetch.last) {
        await Future.delayed(_delayBetweenRequests);
      }
    }

    // Save all prices to cache
    await _savePriceCache(prices);
  }

  /// Parses a Steam price string like "$3.50" or "€3,50" into a double.
  ///
  /// Steam returns prices as locale-formatted strings, not numbers.
  /// We strip everything except digits, dots, and commas, then parse.
  double? _parsePrice(String? priceStr) {
    if (priceStr == null || priceStr.isEmpty) return null;

    // Remove currency symbols and whitespace, keep digits, dots, commas
    var cleaned = priceStr.replaceAll(RegExp(r'[^0-9.,]'), '');

    if (cleaned.isEmpty) return null;

    // Handle European format: "3,50" or "1.234,50"
    // If there's a comma after the last dot, it's a decimal separator
    if (cleaned.contains(',')) {
      final lastComma = cleaned.lastIndexOf(',');
      final lastDot = cleaned.lastIndexOf('.');

      if (lastComma > lastDot) {
        // Comma is decimal separator: "1.234,50" → "1234.50"
        cleaned = cleaned.replaceAll('.', '').replaceAll(',', '.');
      } else {
        // Dot is decimal separator: "1,234.50" → "1234.50"
        cleaned = cleaned.replaceAll(',', '');
      }
    }

    return double.tryParse(cleaned);
  }

  /// Loads cached prices from disk.
  ///
  /// Returns an empty map if no cache exists or it's expired.
  Future<Map<String, double>> loadCachedPrices() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFileName');

      if (!file.existsSync()) return {};

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      // Check cache age
      final timestamp = data['timestamp'] as int? ?? 0;
      final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(cacheTime) > _cacheMaxAge) {
        dev.log('Price cache expired, will re-fetch');
        return {};
      }

      final prices = (data['prices'] as Map<String, dynamic>?)
              ?.map((key, value) => MapEntry(key, (value as num).toDouble())) ??
          {};

      dev.log('Loaded ${prices.length} prices from cache');
      return prices;
    } catch (e) {
      dev.log('Error loading price cache: $e');
      return {};
    }
  }

  /// Saves prices to disk for caching.
  Future<void> _savePriceCache(Map<String, double> prices) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFileName');

      final data = {
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'prices': prices,
      };

      await file.writeAsString(jsonEncode(data));
      dev.log('Saved ${prices.length} prices to cache');
    } catch (e) {
      dev.log('Error saving price cache: $e');
    }
  }
}
