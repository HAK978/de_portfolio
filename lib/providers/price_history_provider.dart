import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/price_history_service.dart';
import '../services/secure_setting.dart';

/// Steam login cookie (steamLoginSecure), needed for the price-history
/// endpoint. It's a live Steam web session, so it's kept in secure
/// storage (migrated from the plaintext file older builds used).
final steamLoginCookieProvider =
    NotifierProvider<SteamLoginCookieNotifier, String>(
  SteamLoginCookieNotifier.new,
);

class SteamLoginCookieNotifier extends SecureSettingNotifier {
  @override
  SecureSetting get setting => Secrets.steamLoginCookie;
}

/// Service instance — recreated when the cookie changes.
final priceHistoryServiceProvider = Provider<PriceHistoryService>((ref) {
  final cookie = ref.watch(steamLoginCookieProvider);
  return PriceHistoryService(
    steamLoginCookie: cookie.isNotEmpty ? cookie : null,
  );
});

/// Validates whether the Steam login cookie is still accepted by Steam.
/// Re-runs whenever the cookie changes (e.g. after login or load from disk).
/// Returns null while cookie is empty (not yet loaded), true/false once checked.
final steamSessionValidProvider = FutureProvider<bool?>((ref) async {
  final cookie = ref.watch(steamLoginCookieProvider);
  if (cookie.isEmpty) return null; // not loaded yet or not set
  final service = ref.read(priceHistoryServiceProvider);
  return service.validateCookie();
});

/// Fetches price history for a specific item by market hash name.
///
/// This is a family provider — it creates a separate provider for each
/// unique marketHashName. Each one is an async provider that returns
/// the list of daily price points (or null if unavailable).
final priceHistoryProvider =
    FutureProvider.family<List<PriceHistoryPoint>?, String>(
  (ref, marketHashName) async {
    final service = ref.watch(priceHistoryServiceProvider);
    return service.fetchHistory(marketHashName);
  },
);
