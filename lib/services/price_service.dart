import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// Result from search/render containing price and image URL.
class MarketItemResult {
  final String hashName;
  final double price;
  final String? iconUrl;
  const MarketItemResult({required this.hashName, required this.price, this.iconUrl});
}

/// Fetches item prices from the Steam Community Market.
///
/// The endpoint returns prices as formatted strings like "$3.50"
/// which we parse into doubles. Rate limited to ~20 requests/min,
/// so we wait 3 seconds between requests to stay safe.
class PriceService {
  static const _baseUrl =
      'https://steamcommunity.com/market/priceoverview/';
  static const _searchRenderUrl =
      'https://steamcommunity.com/market/search/render/';
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
        debugPrint('Rate limited, waiting 5s before retry: $marketHashName');
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
        debugPrint('Price fetch failed (${response.statusCode}) for: $marketHashName');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] != true) {
        debugPrint('Price API returned success=false for: $marketHashName');
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
      debugPrint('Error fetching price for $marketHashName: $e');
      return null;
    }
  }

  /// Fetches prices for a list of items one by one from Steam Market.
  /// Yields progress after each item. 1s delay between requests.
  Stream<PriceFetchProgress> fetchPrices(List<String> marketHashNames) async* {
    final prices = <String, double>{};

    // Load cached prices first
    final cached = await loadCachedPrices();
    prices.addAll(cached);

    final remaining = marketHashNames.where((n) => !cached.containsKey(n)).toList();

    debugPrint('Price fetch: ${cached.length} cached, ${remaining.length} to fetch');

    int fetchedCount = marketHashNames.length - remaining.length;

    if (cached.isNotEmpty) {
      yield PriceFetchProgress(
        fetched: fetchedCount,
        total: marketHashNames.length,
        currentItem: 'Loaded ${cached.length} cached prices',
        prices: Map.of(prices),
      );
    }

    if (remaining.isEmpty) {
      await _savePriceCache(prices);
      return;
    }

    for (final name in remaining) {
      final result = await fetchPrice(name);

      if (result != null) {
        final price = result.lowestPrice ?? result.medianPrice;
        if (price != null) prices[name] = price;
      }

      fetchedCount++;

      yield PriceFetchProgress(
        fetched: fetchedCount,
        total: marketHashNames.length,
        currentItem: name,
        prices: Map.of(prices),
      );

      if (name != remaining.last) {
        await Future.delayed(_delayBetweenRequests);
      }
    }

    await _savePriceCache(prices);
  }

  static const _imageBase =
      'https://community.cloudflare.steamstatic.com/economy/image/';

  /// Fetches prices and image URLs for a list of market hash names
  /// using the bulk search/render endpoint.
  ///
  /// Returns a map of marketHashName → {price, imageUrl}.
  /// Used by storage provider to price + image storage items.
  Stream<Map<String, MarketItemResult>> fetchMarketData(
      List<String> marketHashNames) async* {
    final results = <String, MarketItemResult>{};

    debugPrint('Market data fetch: ${marketHashNames.length} items');

    for (int i = 0; i < marketHashNames.length; i++) {
      final name = marketHashNames[i];

      try {
        debugPrint('[${i + 1}/${marketHashNames.length}] "$name"');
        // Wrap in quotes for exact phrase matching
        final query = '"$name"';
        final batch = await _searchRender(query, count: 10);
        // Try exact match first, then case-insensitive
        final match = batch.where((r) => r.hashName == name).firstOrNull
            ?? batch.where((r) => r.hashName.toLowerCase() == name.toLowerCase()).firstOrNull;
        if (match != null) {
          results[name] = match;
          debugPrint('  → \$${match.price}, image: ${match.iconUrl != null}');
        } else {
          debugPrint('  → not found (${batch.length} results, none matched)');
        }
      } catch (e) {
        debugPrint('  → error: $e');
      }

      yield Map.of(results);

      if (i < marketHashNames.length - 1) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }
  }

  /// Builds a full Steam CDN image URL from an icon_url hash.
  static String buildImageUrl(String iconUrl) => '$_imageBase$iconUrl';

  /// Fetches items from Steam's search/render endpoint.
  /// Returns up to [count] results matching the query.
  Future<List<MarketItemResult>> _searchRender(String query, {int count = 100}) async {
    final uri = Uri.parse(_searchRenderUrl).replace(queryParameters: {
      'norender': '1',
      'appid': '730',
      'currency': '1', // USD
      'query': query,
      'start': '0',
      'count': count.toString(),
      'search_descriptions': '0',
      'sort_column': 'popular',
      'sort_dir': 'desc',
    });

    final response = await http.get(uri);

    if (response.statusCode == 429) {
      debugPrint('search/render rate limited, waiting 15s...');
      await Future.delayed(const Duration(seconds: 15));
      final retry = await http.get(uri);
      if (retry.statusCode == 429) {
        debugPrint('search/render still rate limited, waiting 30s...');
        await Future.delayed(const Duration(seconds: 30));
        final retry2 = await http.get(uri);
        if (retry2.statusCode != 200) return [];
        return _parseSearchResults(retry2.body);
      }
      if (retry.statusCode != 200) return [];
      return _parseSearchResults(retry.body);
    }

    if (response.statusCode != 200) {
      debugPrint('search/render failed (${response.statusCode}) for "$query"');
      return [];
    }

    return _parseSearchResults(response.body);
  }

  /// Parses the JSON response from search/render into a list of results.
  List<MarketItemResult> _parseSearchResults(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['success'] != true) return [];

      final results = data['results'] as List<dynamic>? ?? [];
      return results.map((item) {
        final hashName = item['hash_name'] as String? ?? '';
        // sell_price is in cents
        final sellPriceCents = item['sell_price'] as int? ?? 0;
        // Extract icon_url from asset_description
        final assetDesc = item['asset_description'] as Map<String, dynamic>?;
        final iconUrl = assetDesc?['icon_url'] as String?;
        return MarketItemResult(
          hashName: hashName,
          price: sellPriceCents / 100.0,
          iconUrl: iconUrl,
        );
      }).where((r) => r.hashName.isNotEmpty && r.price > 0).toList();
    } catch (e) {
      debugPrint('Error parsing search/render response: $e');
      return [];
    }
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
        debugPrint('Price cache expired, will re-fetch');
        return {};
      }

      final prices = (data['prices'] as Map<String, dynamic>?)
              ?.map((key, value) => MapEntry(key, (value as num).toDouble())) ??
          {};

      debugPrint('Loaded ${prices.length} prices from cache');
      return prices;
    } catch (e) {
      debugPrint('Error loading price cache: $e');
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
      debugPrint('Saved ${prices.length} prices to cache');
    } catch (e) {
      debugPrint('Error saving price cache: $e');
    }
  }
}
