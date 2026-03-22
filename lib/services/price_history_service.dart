import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A single price data point from Steam's price history.
class PriceHistoryPoint {
  final DateTime date;
  final double price;
  final int volume;

  const PriceHistoryPoint({
    required this.date,
    required this.price,
    required this.volume,
  });

  Map<String, dynamic> toJson() => {
    'date': date.millisecondsSinceEpoch,
    'price': price,
    'volume': volume,
  };

  factory PriceHistoryPoint.fromJson(Map<String, dynamic> json) =>
      PriceHistoryPoint(
        date: DateTime.fromMillisecondsSinceEpoch(json['date'] as int),
        price: (json['price'] as num).toDouble(),
        volume: json['volume'] as int,
      );
}

/// Fetches price history from the Steam Community Market.
///
/// The endpoint returns all historical median sale prices as an array
/// of [date_string, price, volume] entries. The date string format is
/// "Mar 20 2026 01: +0" (hour-level granularity).
///
/// Steam returns prices in the account's local currency (INR for Indian
/// accounts) regardless of the currency parameter. We convert to USD
/// using a live exchange rate.
class PriceHistoryService {
  static const _baseUrl =
      'https://steamcommunity.com/market/pricehistory/';
  static const _cacheDir = 'price_history';
  static const _cacheMaxAge = Duration(hours: 6);
  static const _cacheVersion = 5; // bump to invalidate old caches (now stores hourly)
  static const _exchangeRateCacheFile = 'exchange_rate.json';
  static const _exchangeRateCacheMaxAge = Duration(hours: 24);

  /// Steam login cookie — required for price history endpoint.
  final String? steamLoginCookie;

  /// Cached exchange rate (INR per 1 USD).
  static double? _cachedInrToUsdRate;

  PriceHistoryService({this.steamLoginCookie});

  /// Validates the Steam login cookie by making a test request.
  /// Returns true if the cookie is accepted, false if expired/invalid.
  Future<bool> validateCookie() async {
    if (steamLoginCookie == null || steamLoginCookie!.isEmpty) return false;

    try {
      // Use a common item for the test request
      final uri = Uri.parse(_baseUrl).replace(queryParameters: {
        'appid': '730',
        'currency': '1',
        'market_hash_name': 'AK-47 | Redline (Field-Tested)',
      });

      final response = await http.get(uri, headers: {
        'Cookie': 'steamLoginSecure=$steamLoginCookie',
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['success'] == true;
    } catch (e) {
      debugPrint('Cookie validation error: $e');
      return false;
    }
  }

  /// Fetches the INR→USD exchange rate.
  /// Returns how many INR = 1 USD (e.g. ~83.5).
  /// Caches to disk for 24 hours.
  Future<double?> _getInrPerUsd() async {
    // In-memory cache
    if (_cachedInrToUsdRate != null) return _cachedInrToUsdRate;

    // Disk cache
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_exchangeRateCacheFile');
      if (file.existsSync()) {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final timestamp = data['timestamp'] as int? ?? 0;
        final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
        if (DateTime.now().difference(cacheTime) < _exchangeRateCacheMaxAge) {
          _cachedInrToUsdRate = (data['rate'] as num).toDouble();
          debugPrint('Exchange rate from cache: ${_cachedInrToUsdRate} INR/USD');
          return _cachedInrToUsdRate;
        }
      }
    } catch (_) {}

    // Fetch from API
    try {
      final response = await http.get(
        Uri.parse('https://open.er-api.com/v6/latest/USD'),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rates = data['rates'] as Map<String, dynamic>?;
        if (rates != null && rates.containsKey('INR')) {
          _cachedInrToUsdRate = (rates['INR'] as num).toDouble();
          debugPrint('Exchange rate fetched: ${_cachedInrToUsdRate} INR/USD');

          // Save to disk
          try {
            final dir = await getApplicationDocumentsDirectory();
            final file = File('${dir.path}/$_exchangeRateCacheFile');
            await file.writeAsString(jsonEncode({
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'rate': _cachedInrToUsdRate,
            }));
          } catch (_) {}

          return _cachedInrToUsdRate;
        }
      }
    } catch (e) {
      debugPrint('Exchange rate fetch error: $e');
    }

    // Fallback rate if API fails
    debugPrint('Using fallback exchange rate: 85.0 INR/USD');
    return 85.0;
  }

  /// Fetches price history for an item.
  ///
  /// Returns a list of hourly price points in USD. The chart widget
  /// handles aggregation to daily when appropriate.
  Future<List<PriceHistoryPoint>?> fetchHistory(String marketHashName) async {
    debugPrint('FETCH_HISTORY called for: $marketHashName');
    // Check cache first
    final cached = await _loadFromCache(marketHashName);
    if (cached != null) {
      debugPrint('FETCH_HISTORY using cache for: $marketHashName (${cached.length} points, last price=${cached.last.price})');
      return cached;
    }
    debugPrint('FETCH_HISTORY cache miss, fetching from Steam...');

    if (steamLoginCookie == null || steamLoginCookie!.isEmpty) {
      debugPrint('FETCH_HISTORY FAILED: No Steam login cookie');
      return null;
    }

    debugPrint('FETCH_HISTORY cookie: present');

    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'appid': '730',
      'currency': '1',
      'market_hash_name': marketHashName,
    });

    try {
      final response = await http.get(uri, headers: {
        'Cookie': 'steamLoginSecure=$steamLoginCookie',
      });

      if (response.statusCode != 200) {
        debugPrint('FETCH_HISTORY HTTP ${response.statusCode} for: $marketHashName');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] != true) {
        debugPrint('FETCH_HISTORY success=false for: $marketHashName');
        return null;
      }

      final prices = data['prices'] as List<dynamic>?;
      if (prices == null || prices.isEmpty) {
        debugPrint('FETCH_HISTORY no data for: $marketHashName');
        return null;
      }

      // Get exchange rate for INR → USD conversion
      final inrPerUsd = await _getInrPerUsd();
      final conversionRate = inrPerUsd ?? 85.0;

      // Parse raw data: each entry is ["Mar 20 2026 01: +0", 3.50, "150"]
      // Steam returns prices in account currency (INR), convert to USD
      final points = <PriceHistoryPoint>[];
      for (final entry in prices) {
        final list = entry as List<dynamic>;
        if (list.length < 3) continue;

        final dateStr = list[0] as String;
        final rawPrice = (list[1] as num).toDouble();
        final priceUsd = rawPrice / conversionRate;
        final volume = int.tryParse(list[2].toString()) ?? 0;

        final date = _parseSteamDate(dateStr);
        if (date != null) {
          points.add(PriceHistoryPoint(
            date: date,
            price: priceUsd,
            volume: volume,
          ));
        }
      }

      // Debug: log first and last raw prices to verify values
      if (points.isNotEmpty) {
        debugPrint('PRICES (USD) $marketHashName: '
            'first=${points.first.price.toStringAsFixed(2)}, '
            'last=${points.last.price.toStringAsFixed(2)}, '
            'count=${points.length} hourly points');
      }

      // Sort chronologically
      points.sort((a, b) => a.date.compareTo(b.date));

      // Cache the hourly result (already in USD)
      await _saveToCache(marketHashName, points);

      return points;
    } catch (e) {
      debugPrint('Error fetching price history for $marketHashName: $e');
      return null;
    }
  }

  /// Parses Steam's date format: "Mar 20 2026 01: +0"
  DateTime? _parseSteamDate(String dateStr) {
    try {
      // Format: "Mon DD YYYY HH: +0"
      // Remove the ": +0" suffix and parse
      final cleaned = dateStr.replaceAll(RegExp(r':\s*\+\d+$'), '').trim();

      const months = {
        'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4,
        'May': 5, 'Jun': 6, 'Jul': 7, 'Aug': 8,
        'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
      };

      final parts = cleaned.split(' ');
      if (parts.length < 4) return null;

      final month = months[parts[0]];
      final day = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);
      final hour = int.tryParse(parts[3]);

      if (month == null || day == null || year == null || hour == null) {
        return null;
      }

      return DateTime.utc(year, month, day, hour);
    } catch (e) {
      return null;
    }
  }

  /// Aggregates hourly points into daily averages.
  ///
  /// Steam gives data at hour-level granularity which is too noisy
  /// for a chart. We group by date and take the median price and
  /// total volume for each day.
  List<PriceHistoryPoint> _aggregateDaily(List<PriceHistoryPoint> points) {
    final byDay = <String, List<PriceHistoryPoint>>{};

    for (final point in points) {
      final key = '${point.date.year}-${point.date.month}-${point.date.day}';
      byDay.putIfAbsent(key, () => []).add(point);
    }

    final daily = <PriceHistoryPoint>[];
    for (final entry in byDay.entries) {
      final dayPoints = entry.value;
      // Use median price for the day
      dayPoints.sort((a, b) => a.price.compareTo(b.price));
      final medianPrice = dayPoints[dayPoints.length ~/ 2].price;
      final totalVolume = dayPoints.fold(0, (sum, p) => sum + p.volume);

      daily.add(PriceHistoryPoint(
        date: DateTime.utc(
          dayPoints.first.date.year,
          dayPoints.first.date.month,
          dayPoints.first.date.day,
        ),
        price: medianPrice,
        volume: totalVolume,
      ));
    }

    daily.sort((a, b) => a.date.compareTo(b.date));
    return daily;
  }

  // ── Caching ──────────────────────────────────────────────────

  /// Clears all cached price history data.
  Future<void> clearCache() async {
    try {
      final dir = await _getCacheDir();
      final cacheDir = Directory(dir);
      if (cacheDir.existsSync()) {
        cacheDir.deleteSync(recursive: true);
        debugPrint('Price history cache cleared');
      }
    } catch (e) {
      debugPrint('Error clearing price history cache: $e');
    }
  }

  Future<String> _getCacheDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/$_cacheDir');
    if (!cacheDir.existsSync()) {
      cacheDir.createSync();
    }
    return cacheDir.path;
  }

  String _cacheKey(String marketHashName) {
    // Sanitize filename — replace special chars with underscores
    return marketHashName
        .replaceAll(RegExp(r'[^\w\s-]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
  }

  Future<List<PriceHistoryPoint>?> _loadFromCache(String marketHashName) async {
    try {
      final dir = await _getCacheDir();
      final file = File('$dir/${_cacheKey(marketHashName)}.json');

      if (!file.existsSync()) return null;

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      // Reject old cache versions (corrupted data from earlier bugs)
      final version = data['version'] as int? ?? 0;
      if (version < _cacheVersion) {
        debugPrint('CACHE rejected old version ($version < $_cacheVersion) for: $marketHashName');
        return null;
      }

      final timestamp = data['timestamp'] as int? ?? 0;
      final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(cacheTime) > _cacheMaxAge) {
        return null;
      }

      final points = (data['points'] as List<dynamic>)
          .map((p) => PriceHistoryPoint.fromJson(p as Map<String, dynamic>))
          .toList();

      debugPrint('Loaded ${points.length} cached history points for: $marketHashName');
      return points;
    } catch (e) {
      debugPrint('Error loading history cache for $marketHashName: $e');
      return null;
    }
  }

  Future<void> _saveToCache(
    String marketHashName,
    List<PriceHistoryPoint> points,
  ) async {
    try {
      final dir = await _getCacheDir();
      final file = File('$dir/${_cacheKey(marketHashName)}.json');

      final data = {
        'version': _cacheVersion,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'points': points.map((p) => p.toJson()).toList(),
      };

      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Error saving history cache for $marketHashName: $e');
    }
  }
}
