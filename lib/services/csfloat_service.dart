import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'price_service.dart' show PriceFetchProgress;

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

  CsfloatService({this.apiKey});

  /// Fetches the lowest listing price for a single item on CSFloat.
  ///
  /// Returns the price in dollars (converted from cents), or null
  /// if there are no listings for this item.
  Future<double?> fetchPrice(String marketHashName) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'market_hash_name': marketHashName,
      'sort_by': 'lowest_price',
      'limit': '1',
    });

    try {
      final headers = <String, String>{};
      if (apiKey != null) {
        headers['Authorization'] = apiKey!;
      }

      final response = await http.get(uri, headers: headers);

      if (response.statusCode == 429) {
        dev.log('CSFloat rate limited for: $marketHashName');
        return null;
      }

      if (response.statusCode != 200) {
        dev.log('CSFloat fetch failed (${response.statusCode}) for: $marketHashName');
        return null;
      }

      final data = jsonDecode(response.body);

      // Response is {"data": [...]} with auth
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
    } catch (e) {
      dev.log('Error fetching CSFloat price for $marketHashName: $e');
      return null;
    }
  }

  /// Fetches CSFloat prices for a list of items, yielding progress.
  ///
  /// Reuses the same PriceFetchProgress class from price_service.dart
  /// so the UI can show the same progress pattern.
  Stream<PriceFetchProgress> fetchPrices(List<String> marketHashNames) async* {
    final prices = <String, double>{};

    // Load cached prices first
    final cached = await loadCachedPrices();
    prices.addAll(cached);

    final toFetch = marketHashNames
        .where((name) => !cached.containsKey(name))
        .toList();

    dev.log('CSFloat: ${cached.length} cached, ${toFetch.length} to fetch');

    if (cached.isNotEmpty) {
      yield PriceFetchProgress(
        fetched: cached.length,
        total: marketHashNames.length,
        currentItem: 'Loaded ${cached.length} cached CSFloat prices',
        prices: Map.of(prices),
      );
    }

    int fetchedCount = cached.length;

    for (final name in toFetch) {
      final price = await fetchPrice(name);

      if (price != null) {
        prices[name] = price;
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
        dev.log('CSFloat price cache expired');
        return {};
      }

      final prices = (data['prices'] as Map<String, dynamic>?)
              ?.map((key, value) => MapEntry(key, (value as num).toDouble())) ??
          {};

      dev.log('Loaded ${prices.length} CSFloat prices from cache');
      return prices;
    } catch (e) {
      dev.log('Error loading CSFloat price cache: $e');
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
      dev.log('Saved ${prices.length} CSFloat prices to cache');
    } catch (e) {
      dev.log('Error saving CSFloat price cache: $e');
    }
  }
}
