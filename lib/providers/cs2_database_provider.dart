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
///
/// Also side-loads each container's `contains` list; access via
/// [caseContentsProvider] (exposed below).
final cs2DatabaseProvider =
    AsyncNotifierProvider<Cs2DatabaseNotifier, List<CS2Item>>(
  Cs2DatabaseNotifier.new,
);

class Cs2DatabaseNotifier extends AsyncNotifier<List<CS2Item>> {
  Map<String, CaseContents> _caseContents = const {};

  /// Contents of each container (case / capsule / package), keyed by
  /// market_hash_name. Populated as a side-effect of [build].
  Map<String, CaseContents> get caseContents => _caseContents;

  @override
  Future<List<CS2Item>> build() async {
    ref.keepAlive();
    final service = ref.read(cs2DatabaseServiceProvider);
    final catalog = await service.loadCatalog();
    _caseContents = catalog.caseContents;
    return catalog.items;
  }

  /// Re-download the catalog, bypassing the disk cache.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final service = ref.read(cs2DatabaseServiceProvider);
      final catalog = await service.loadCatalog(forceRefresh: true);
      _caseContents = catalog.caseContents;
      state = AsyncValue.data(catalog.items);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

/// Map of container market_hash_name → [CaseContents].
/// Empty until the catalog finishes loading; populated as part of the
/// same [cs2DatabaseProvider] load so there's no extra network hit.
final caseContentsProvider = Provider<Map<String, CaseContents>>((ref) {
  // Watching the catalog ensures we rebuild whenever it finishes
  // loading or refreshes. The actual data lives on the notifier.
  ref.watch(cs2DatabaseProvider);
  return ref.read(cs2DatabaseProvider.notifier).caseContents;
});
