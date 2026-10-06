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
/// Prices come back in the Steam account's wallet currency, whatever
/// `currency` the request asks for. The response's price_prefix /
/// price_suffix say which currency that is, and prices are converted to
/// USD with a live exchange rate.
class PriceHistoryService {
  static const _baseUrl =
      'https://steamcommunity.com/market/pricehistory/';
  static const _ratesUrl = 'https://open.er-api.com/v6/latest/USD';
  static const _cacheDir = 'price_history';
  static const _cacheMaxAge = Duration(hours: 6);
  // Bump to invalidate old caches. v6: v5 entries assumed an INR wallet
  // and divided USD prices by ~85 for everyone else.
  static const _cacheVersion = 6;
  static const _exchangeRateCacheFile = 'exchange_rates.json';
  static const _exchangeRateCacheMaxAge = Duration(hours: 24);
  static const _requestTimeout = Duration(seconds: 15);

  /// Used only if the rates API is unreachable, so the owner's INR
  /// wallet still gets an approximate chart.
  static const _fallbackInrPerUsd = 85.0;

  /// Steam login cookie — required for price history endpoint.
  final String? steamLoginCookie;
  final http.Client? _client;

  /// Units of each currency per 1 USD, shared across instances.
  static Map<String, double>? _cachedRates;

  PriceHistoryService({this.steamLoginCookie, http.Client? client})
      : _client = client;

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) =>
      (_client?.get(uri, headers: headers) ?? http.get(uri, headers: headers))
          .timeout(_requestTimeout);

  @visibleForTesting
  static void clearRateCache() => _cachedRates = null;

  /// ISO code for Steam's currency symbols, or null if unknown or
  /// ambiguous (e.g. "¥" is both CNY and JPY).
  @visibleForTesting
  static String? currencyFromSymbols(String? prefix, String? suffix) {
    const byPrefix = {
      r'$': 'USD', 'USD': 'USD', '₹': 'INR', '£': 'GBP', r'CDN$': 'CAD',
      r'A$': 'AUD', r'NZ$': 'NZD', r'R$': 'BRL', r'Mex$': 'MXN',
      r'S$': 'SGD', r'HK$': 'HKD', '₩': 'KRW', '₺': 'TRY', '₴': 'UAH',
    };
    const bySuffix = {'€': 'EUR', 'pуб.': 'RUB', 'zł': 'PLN', '₸': 'KZT'};
    final p = (prefix ?? '').trim();
    final s = (suffix ?? '').trim();
    if (p.isNotEmpty) return byPrefix[p];
    if (s.isNotEmpty) return bySuffix[s];
    return null;
  }

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

      final response = await _get(uri, headers: {
        'Cookie': 'steamLoginSecure=$steamLoginCookie',
      });

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['success'] == true;
    } catch (e) {
      debugPrint('Cookie validation error: $e');
      return false;
    }
  }

  /// How many units of [currency] make 1 USD, or null if unknown.
  Future<double?> _unitsPerUsd(String currency) async {
    if (currency == 'USD') return 1.0;
    final rates = await _rates();
    return rates?[currency] ??
        (currency == 'INR' ? _fallbackInrPerUsd : null);
  }

  /// USD-based exchange rates, cached in memory and on disk for 24 hours.
  Future<Map<String, double>?> _rates() async {
    if (_cachedRates != null) return _cachedRates;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_exchangeRateCacheFile');
      if (file.existsSync()) {
        final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final saved = DateTime.fromMillisecondsSinceEpoch(data['timestamp'] as int? ?? 0);
        if (DateTime.now().difference(saved) < _exchangeRateCacheMaxAge) {
          return _cachedRates = _parseRates(data['rates']);
        }
      }
    } catch (_) {}

    try {
      final response = await _get(Uri.parse(_ratesUrl));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rates = _parseRates(data['rates']);
        if (rates.isNotEmpty) {
          _cachedRates = rates;
          try {
            final dir = await getApplicationDocumentsDirectory();
            await File('${dir.path}/$_exchangeRateCacheFile').writeAsString(jsonEncode({
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'rates': rates,
            }));
          } catch (_) {}
          return rates;
        }
      }
    } catch (e) {
      debugPrint('Exchange rate fetch error: $e');
    }
    return null;
  }

  static Map<String, double> _parseRates(Object? raw) => {
        if (raw is Map)
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is num && (entry.value as num) > 0)
              entry.key as String: (entry.value as num).toDouble(),
      };

  /// Fetches price history for an item.
  ///
  /// Returns hourly price points in USD (the chart widget aggregates to
  /// daily when appropriate), or null if unavailable — including when
  /// the wallet currency can't be converted.
  Future<List<PriceHistoryPoint>?> fetchHistory(String marketHashName) async {
    final cached = await _loadFromCache(marketHashName);
    if (cached != null) return cached;

    if (steamLoginCookie == null || steamLoginCookie!.isEmpty) {
      debugPrint('Price history needs a Steam login cookie');
      return null;
    }

    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'appid': '730',
      'currency': '1',
      'market_hash_name': marketHashName,
    });

    try {
      final response = await _get(uri, headers: {
        'Cookie': 'steamLoginSecure=$steamLoginCookie',
      });

      if (response.statusCode != 200) {
        debugPrint('Price history HTTP ${response.statusCode} for: $marketHashName');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['success'] != true) return null;

      final prices = data['prices'] as List<dynamic>?;
      if (prices == null || prices.isEmpty) return null;

      final prefix = data['price_prefix'] as String?;
      final suffix = data['price_suffix'] as String?;
      final currency = currencyFromSymbols(prefix, suffix);
      final unitsPerUsd = currency == null ? null : await _unitsPerUsd(currency);
      if (unitsPerUsd == null) {
        // Showing unconverted prices as dollars would be wrong; show nothing.
        debugPrint('Price history: unsupported wallet currency ("$prefix", "$suffix")');
        return null;
      }

      // Each entry is ["Mar 20 2026 01: +0", 3.50, "150"].
      final points = <PriceHistoryPoint>[];
      for (final entry in prices) {
        if (entry is! List || entry.length < 3 || entry[1] is! num) continue;
        final rawDate = entry[0];
        final date = rawDate is String ? _parseSteamDate(rawDate) : null;
        if (date == null) continue;
        points.add(PriceHistoryPoint(
          date: date,
          price: (entry[1] as num).toDouble() / unitsPerUsd,
          volume: int.tryParse(entry[2].toString()) ?? 0,
        ));
      }
      if (points.isEmpty) return null;

      points.sort((a, b) => a.date.compareTo(b.date));
      await _saveToCache(marketHashName, points);
      return points;
    } catch (e) {
      debugPrint('Error fetching price history for $marketHashName: $e');
      return null;
    }
  }

  /// Parses Steam's date format: "Mar 20 2026 01: +0" (UTC).
  static DateTime? _parseSteamDate(String dateStr) {
    // Remove the ": +0" suffix, leaving "Mon DD YYYY HH".
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
      if (version < _cacheVersion) return null;

      final timestamp = data['timestamp'] as int? ?? 0;
      final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(cacheTime) > _cacheMaxAge) {
        return null;
      }

      return (data['points'] as List<dynamic>)
          .map((p) => PriceHistoryPoint.fromJson(p as Map<String, dynamic>))
          .toList();
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
