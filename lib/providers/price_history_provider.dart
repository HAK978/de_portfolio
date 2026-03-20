import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../services/price_history_service.dart';

/// Steam login cookie — persisted to disk, loaded on startup.
///
/// Required for the price history endpoint which needs an
/// authenticated Steam session.
final steamLoginCookieProvider =
    NotifierProvider<SteamLoginCookieNotifier, String>(
  SteamLoginCookieNotifier.new,
);

class SteamLoginCookieNotifier extends Notifier<String> {
  static const _fileName = 'steam_login_cookie.txt';

  @override
  String build() {
    _loadSaved();
    return '';
  }

  void set(String value) {
    state = value;
    _save(value);
  }

  Future<void> _loadSaved() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) {
        final cookie = await file.readAsString();
        if (cookie.trim().isNotEmpty) {
          state = cookie.trim();
          dev.log('Loaded Steam login cookie from disk');
        }
      }
    } catch (e) {
      dev.log('Error loading Steam login cookie: $e');
    }
  }

  Future<void> _save(String cookie) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(cookie);
    } catch (e) {
      dev.log('Error saving Steam login cookie: $e');
    }
  }
}

/// Service instance — recreated when the cookie changes.
final priceHistoryServiceProvider = Provider<PriceHistoryService>((ref) {
  final cookie = ref.watch(steamLoginCookieProvider);
  return PriceHistoryService(
    steamLoginCookie: cookie.isNotEmpty ? cookie : null,
  );
});

/// Fetches price history for a specific item by market hash name.
///
/// This is a family provider — it creates a separate provider for each
/// unique marketHashName. Each one is an async provider that returns
/// the list of daily price points (or null if unavailable).
final priceHistoryProvider =
    FutureProvider.family<List<PriceHistoryPoint>?, String>(
  (ref, marketHashName) async {
    final service = ref.read(priceHistoryServiceProvider);
    return service.fetchHistory(marketHashName);
  },
);
