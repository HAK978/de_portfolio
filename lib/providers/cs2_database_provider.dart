import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/cs2_item.dart';
import '../services/cs2_database_service.dart';

/// Service instance for fetching the full CS2 item catalog.
final cs2DatabaseServiceProvider = Provider<Cs2DatabaseService>((ref) {
  return Cs2DatabaseService();
});

/// Full catalog of tradeable CS2 items from ByMykel/CSGO-API.
///
/// First build loads from disk cache; if no cache exists it fetches
/// all endpoints (skins, stickers, crates, agents, patches, etc.).
/// Expanded variants (wear × StatTrak × Souvenir) are generated
/// client-side so a substring match on market_hash_name covers every
/// priceable item.
final cs2DatabaseProvider =
    AsyncNotifierProvider<Cs2DatabaseNotifier, List<CS2Item>>(
  Cs2DatabaseNotifier.new,
);

class Cs2DatabaseNotifier extends AsyncNotifier<List<CS2Item>> {
  @override
  Future<List<CS2Item>> build() async {
    ref.keepAlive();
    final service = ref.read(cs2DatabaseServiceProvider);
    return service.loadCatalog();
  }

  /// Re-download the catalog, bypassing the disk cache.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final service = ref.read(cs2DatabaseServiceProvider);
      final items = await service.loadCatalog(forceRefresh: true);
      state = AsyncValue.data(items);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}
