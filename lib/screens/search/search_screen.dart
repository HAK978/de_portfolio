import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/cs2_item.dart';
import '../../providers/cs2_database_provider.dart';
import '../../providers/search_history_provider.dart';
import '../../providers/search_prices_provider.dart';
import '../../theme/app_theme.dart';

/// Holds the current search query for the Search tab.
final searchCatalogQueryProvider =
    NotifierProvider<SearchCatalogQueryNotifier, String>(
  SearchCatalogQueryNotifier.new,
);

class SearchCatalogQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

// ── Filter state providers ───────────────────────────────────────
//
// Intentionally separate from the inventory's filter providers so
// filters set on one tab don't bleed into the other.

final searchRarityFilterProvider =
    NotifierProvider<SearchRarityFilterNotifier, Set<String>>(
  SearchRarityFilterNotifier.new,
);

class SearchRarityFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String v) =>
      state = state.contains(v) ? ({...state}..remove(v)) : {...state, v};
  void clear() => state = {};
}

final searchWeaponTypeFilterProvider =
    NotifierProvider<SearchWeaponTypeFilterNotifier, Set<String>>(
  SearchWeaponTypeFilterNotifier.new,
);

class SearchWeaponTypeFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String v) =>
      state = state.contains(v) ? ({...state}..remove(v)) : {...state, v};
  void clear() => state = {};
}

final searchWearFilterProvider =
    NotifierProvider<SearchWearFilterNotifier, Set<String>>(
  SearchWearFilterNotifier.new,
);

class SearchWearFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String v) =>
      state = state.contains(v) ? ({...state}..remove(v)) : {...state, v};
  void clear() => state = {};
}

final searchCollectionFilterProvider =
    NotifierProvider<SearchCollectionFilterNotifier, Set<String>>(
  SearchCollectionFilterNotifier.new,
);

class SearchCollectionFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String v) =>
      state = state.contains(v) ? ({...state}..remove(v)) : {...state, v};
  void clear() => state = {};
}

/// Quality filter: any subset of {'Normal', 'StatTrak', 'Souvenir'}.
/// An empty set means "any quality". 'Normal' = not StatTrak and not
/// Souvenir — non-skin items (stickers, cases, agents, etc.) fall into
/// this bucket since they carry neither flag.
final searchQualityFilterProvider =
    NotifierProvider<SearchQualityFilterNotifier, Set<String>>(
  SearchQualityFilterNotifier.new,
);

class SearchQualityFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String v) =>
      state = state.contains(v) ? ({...state}..remove(v)) : {...state, v};
  void clear() => state = {};
}

/// Sort options applicable to the Search catalog. 24h change and
/// quantity don't apply (search items have no owned quantity, and
/// catalog entries have no historical price state).
enum SearchSortOption {
  relevance('Catalog Order'),
  priceDesc('Price: High to Low'),
  priceAsc('Price: Low to High'),
  csfloatDesc('CSFloat: High to Low'),
  csfloatAsc('CSFloat: Low to High'),
  savingsDesc('Best Deal (Steam vs CF)'),
  savingsRevDesc('Best Deal (CF vs Steam)'),
  nameAsc('Name: A-Z'),
  nameDesc('Name: Z-A');

  final String label;
  const SearchSortOption(this.label);
}

final searchSortProvider =
    NotifierProvider<SearchSortNotifier, SearchSortOption>(
  SearchSortNotifier.new,
);

class SearchSortNotifier extends Notifier<SearchSortOption> {
  @override
  SearchSortOption build() => SearchSortOption.relevance;
  void set(SearchSortOption v) => state = v;
}

// ── Derived option lists ─────────────────────────────────────────
//
// Options for each filter are computed from the loaded catalog so
// new item types (e.g. ByMykel adds a new rarity or category) show up
// automatically. Recomputes only when the catalog changes.

final availableSearchRaritiesProvider = Provider<List<String>>((ref) {
  final items = _currentCatalogItems(ref);
  final set = <String>{for (final i in items) i.rarity};
  return set.toList()..sort();
});

final availableSearchWeaponTypesProvider = Provider<List<String>>((ref) {
  final items = _currentCatalogItems(ref);
  final set = <String>{for (final i in items) i.weaponType};
  return set.toList()..sort();
});

final availableSearchWearsProvider = Provider<List<String>>((ref) {
  final items = _currentCatalogItems(ref);
  final set = <String>{};
  for (final i in items) {
    final w = i.wear;
    if (w != null) set.add(w);
  }
  // Present in CS2's natural wear order (FN → BS).
  const order = [
    'Factory New',
    'Minimal Wear',
    'Field-Tested',
    'Well-Worn',
    'Battle-Scarred',
  ];
  final ordered = [for (final w in order) if (set.remove(w)) w];
  ordered.addAll(set.toList()..sort());
  return ordered;
});

final availableSearchCollectionsProvider = Provider<List<String>>((ref) {
  final items = _currentCatalogItems(ref);
  final set = <String>{};
  for (final i in items) {
    final c = i.collection;
    if (c != null && c.isNotEmpty) set.add(c);
  }
  return set.toList()..sort();
});

List<CS2Item> _currentCatalogItems(Ref ref) {
  final async = ref.watch(cs2DatabaseProvider);
  return async.when(
    data: (d) => d,
    loading: () => <CS2Item>[],
    error: (_, _) => <CS2Item>[],
  );
}

/// Filtered + sorted + capped result list. Returns an empty list when
/// there's no query and no active filter — the UI falls back to
/// "Recent" in that case.
///
/// Filter pass is uncapped so that sort operates on the full matching
/// pool (otherwise a price-based sort could miss items). The cap is
/// applied last, after sorting.
final filteredSearchResultsProvider = Provider<List<CS2Item>>((ref) {
  final items = _currentCatalogItems(ref);
  final query = ref.watch(searchCatalogQueryProvider).trim().toLowerCase();
  final rarity = ref.watch(searchRarityFilterProvider);
  final weapon = ref.watch(searchWeaponTypeFilterProvider);
  final wear = ref.watch(searchWearFilterProvider);
  final collection = ref.watch(searchCollectionFilterProvider);
  final quality = ref.watch(searchQualityFilterProvider);
  final sort = ref.watch(searchSortProvider);
  final prices = ref.watch(searchPricesProvider);

  final tokens =
      query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

  final noInput = tokens.isEmpty &&
      rarity.isEmpty &&
      weapon.isEmpty &&
      wear.isEmpty &&
      collection.isEmpty &&
      quality.isEmpty;
  if (noInput) return const [];

  final out = <CS2Item>[];
  for (final item in items) {
    if (tokens.isNotEmpty) {
      final hay = item.marketHashName.toLowerCase();
      if (!tokens.every(hay.contains)) continue;
    }
    if (rarity.isNotEmpty && !rarity.contains(item.rarity)) continue;
    if (weapon.isNotEmpty && !weapon.contains(item.weaponType)) continue;
    if (wear.isNotEmpty) {
      final w = item.wear;
      if (w == null || !wear.contains(w)) continue;
    }
    if (collection.isNotEmpty) {
      final c = item.collection;
      if (c == null || !collection.contains(c)) continue;
    }
    if (quality.isNotEmpty) {
      final q = item.isStatTrak
          ? 'StatTrak'
          : item.isSouvenir
              ? 'Souvenir'
              : 'Normal';
      if (!quality.contains(q)) continue;
    }
    out.add(item);
  }

  _applySort(out, sort, prices);

  if (out.length > _maxResults) return out.sublist(0, _maxResults);
  return out;
});

/// Sort helper. Items with missing prices sink to the bottom for
/// price-based sorts so the user can still see prioritized results as
/// prices stream in.
void _applySort(
  List<CS2Item> items,
  SearchSortOption sort,
  SearchPrices prices,
) {
  int cmpNullable(double? a, double? b, {required bool desc}) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return desc ? b.compareTo(a) : a.compareTo(b);
  }

  double? savings(CS2Item i, {required bool reverse}) {
    final s = prices.steam[i.marketHashName];
    final c = prices.csfloat[i.marketHashName];
    if (s == null || c == null) return null;
    if (reverse) {
      if (c <= 0) return null;
      return (c - s) / c;
    }
    if (s <= 0) return null;
    return (s - c) / s;
  }

  switch (sort) {
    case SearchSortOption.relevance:
      break;
    case SearchSortOption.priceDesc:
      items.sort((a, b) => cmpNullable(
            prices.steam[a.marketHashName],
            prices.steam[b.marketHashName],
            desc: true,
          ));
    case SearchSortOption.priceAsc:
      items.sort((a, b) => cmpNullable(
            prices.steam[a.marketHashName],
            prices.steam[b.marketHashName],
            desc: false,
          ));
    case SearchSortOption.csfloatDesc:
      items.sort((a, b) => cmpNullable(
            prices.csfloat[a.marketHashName],
            prices.csfloat[b.marketHashName],
            desc: true,
          ));
    case SearchSortOption.csfloatAsc:
      items.sort((a, b) => cmpNullable(
            prices.csfloat[a.marketHashName],
            prices.csfloat[b.marketHashName],
            desc: false,
          ));
    case SearchSortOption.savingsDesc:
      items.sort((a, b) => cmpNullable(
            savings(a, reverse: false),
            savings(b, reverse: false),
            desc: true,
          ));
    case SearchSortOption.savingsRevDesc:
      items.sort((a, b) => cmpNullable(
            savings(a, reverse: true),
            savings(b, reverse: true),
            desc: true,
          ));
    case SearchSortOption.nameAsc:
      items.sort((a, b) => a.marketHashName.compareTo(b.marketHashName));
    case SearchSortOption.nameDesc:
      items.sort((a, b) => b.marketHashName.compareTo(a.marketHashName));
  }
}

/// Max number of rows to render at once — prevents the ListView
/// from trying to build 30k+ widgets when the query is very short.
const _maxResults = 200;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(searchCatalogQueryProvider),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _hasActiveFilters() {
    return ref.read(searchRarityFilterProvider).isNotEmpty ||
        ref.read(searchWeaponTypeFilterProvider).isNotEmpty ||
        ref.read(searchWearFilterProvider).isNotEmpty ||
        ref.read(searchCollectionFilterProvider).isNotEmpty ||
        ref.read(searchQualityFilterProvider).isNotEmpty;
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _SearchFilterSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(cs2DatabaseProvider);
    final query = ref.watch(searchCatalogQueryProvider).trim().toLowerCase();

    // Watch filters so the app bar badge rebuilds when they change.
    ref.watch(searchRarityFilterProvider);
    ref.watch(searchWeaponTypeFilterProvider);
    ref.watch(searchWearFilterProvider);
    ref.watch(searchCollectionFilterProvider);
    ref.watch(searchQualityFilterProvider);
    final currentSort = ref.watch(searchSortProvider);

    // Prices are fetched only when the user taps the "Load prices"
    // button below — never automatically — so they can compose their
    // query + filters without burning API budget on partial matches.

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _hasActiveFilters(),
              smallSize: 8,
              child: const Icon(Icons.filter_list),
            ),
            tooltip: 'Filters',
            onPressed: catalogAsync.isLoading ? null : _showFilterSheet,
          ),
          PopupMenuButton<SearchSortOption>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            onSelected: (o) =>
                ref.read(searchSortProvider.notifier).set(o),
            itemBuilder: (_) => SearchSortOption.values.map((o) {
              return PopupMenuItem(
                value: o,
                child: Row(
                  children: [
                    if (o == currentSort)
                      const Icon(Icons.check, size: 18)
                    else
                      const SizedBox(width: 18),
                    const SizedBox(width: 8),
                    Text(o.label),
                  ],
                ),
              );
            }).toList(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh catalog',
            onPressed: catalogAsync.isLoading
                ? null
                : () => ref.read(cs2DatabaseProvider.notifier).refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _controller,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: (v) =>
                  ref.read(searchCatalogQueryProvider.notifier).set(v),
              decoration: InputDecoration(
                hintText: 'Search any CS2 item...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _controller.clear();
                          ref.read(searchCatalogQueryProvider.notifier).set('');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const _ActiveFilterChipsRow(),
          const _LoadPricesButton(),
          Expanded(
            child: catalogAsync.when(
              loading: () => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Downloading CS2 item catalog...'),
                    SizedBox(height: 4),
                    Text(
                      'First load only — cached afterwards',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                      const SizedBox(height: 12),
                      Text(
                        'Could not load catalog: $e',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                        onPressed: () =>
                            ref.read(cs2DatabaseProvider.notifier).refresh(),
                      ),
                    ],
                  ),
                ),
              ),
              data: (items) => _ResultList(
                allItems: items,
                hasQuery: query.isNotEmpty,
                onTap: (item) {
                  // Carry already-fetched prices into the detail screen
                  // so it doesn't re-hit the APIs.
                  final prices = ref.read(searchPricesProvider);
                  final enriched = item.copyWith(
                    currentPrice:
                        prices.steam[item.marketHashName] ?? item.currentPrice,
                    csfloatPrice:
                        prices.csfloat[item.marketHashName] ?? item.csfloatPrice,
                  );
                  ref
                      .read(searchHistoryProvider.notifier)
                      .record(item.marketHashName);
                  context.push('/search/item', extra: enriched);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explicit "Load prices for N items" button. Hidden when there are
/// no results, when the list is over the cap, or when every visible
/// item already has both Steam and CSFloat resolved. Lets the user
/// compose query + filters fully before spending API budget.
class _LoadPricesButton extends ConsumerWidget {
  const _LoadPricesButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(filteredSearchResultsProvider);
    final prices = ref.watch(searchPricesProvider);

    if (results.isEmpty) return const SizedBox.shrink();
    if (results.length > searchPriceAutoFetchCap) return const SizedBox.shrink();

    var unpriced = 0;
    var anyLoading = false;
    for (final item in results) {
      final hash = item.marketHashName;
      if (!prices.steam.containsKey(hash) || !prices.csfloat.containsKey(hash)) {
        unpriced++;
      }
      if (prices.loading.contains(hash)) anyLoading = true;
    }

    // Nothing to do — every row is already priced.
    if (unpriced == 0 && !anyLoading) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          icon: anyLoading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.attach_money, size: 18),
          label: Text(
            anyLoading
                ? 'Loading prices...'
                : 'Load prices for $unpriced item${unpriced == 1 ? '' : 's'}',
          ),
          onPressed: anyLoading
              ? null
              : () => ref
                  .read(searchPricesProvider.notifier)
                  .fetchForItems(results),
        ),
      ),
    );
  }
}

/// Horizontal strip of chips summarizing active filters — gives a
/// glance at what's applied and lets the user tap-to-remove without
/// opening the filter sheet.
class _ActiveFilterChipsRow extends ConsumerWidget {
  const _ActiveFilterChipsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rarity = ref.watch(searchRarityFilterProvider);
    final weapon = ref.watch(searchWeaponTypeFilterProvider);
    final wear = ref.watch(searchWearFilterProvider);
    final collection = ref.watch(searchCollectionFilterProvider);
    final quality = ref.watch(searchQualityFilterProvider);

    final chips = <Widget>[];
    void addChips(Set<String> values, void Function(String) onDelete) {
      for (final v in values) {
        chips.add(InputChip(
          label: Text(v, style: const TextStyle(fontSize: 12)),
          onDeleted: () => onDelete(v),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ));
      }
    }

    addChips(quality,
        (v) => ref.read(searchQualityFilterProvider.notifier).toggle(v));
    addChips(rarity,
        (v) => ref.read(searchRarityFilterProvider.notifier).toggle(v));
    addChips(weapon,
        (v) => ref.read(searchWeaponTypeFilterProvider.notifier).toggle(v));
    addChips(
        wear, (v) => ref.read(searchWearFilterProvider.notifier).toggle(v));
    addChips(collection,
        (v) => ref.read(searchCollectionFilterProvider.notifier).toggle(v));

    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: chips,
      ),
    );
  }
}

class _ResultList extends ConsumerWidget {
  final List<CS2Item> allItems;
  final bool hasQuery;
  final void Function(CS2Item) onTap;

  const _ResultList({
    required this.allItems,
    required this.hasQuery,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filtered = ref.watch(filteredSearchResultsProvider);
    final hasActiveFilters =
        ref.watch(searchRarityFilterProvider).isNotEmpty ||
            ref.watch(searchWeaponTypeFilterProvider).isNotEmpty ||
            ref.watch(searchWearFilterProvider).isNotEmpty ||
            ref.watch(searchCollectionFilterProvider).isNotEmpty;

    // No query AND no filters → show recent history / help text.
    if (!hasQuery && !hasActiveFilters) {
      return _RecentSection(items: allItems, onTap: onTap);
    }

    if (filtered.isEmpty) {
      return const Center(
        child: Text(
          'No items match your search',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    final overCap = filtered.length > searchPriceAutoFetchCap;

    return Column(
      children: [
        if (overCap)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Narrow filters to see live prices '
              '(${filtered.length} results, prices fetched for ≤$searchPriceAutoFetchCap)',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: filtered.length,
            cacheExtent: 500,
            itemBuilder: (context, i) => _SearchResultCard(
              item: filtered[i],
              onTap: () => onTap(filtered[i]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shown when the search box is empty: recently opened items + catalog size.
class _RecentSection extends ConsumerWidget {
  final List<CS2Item> items;
  final void Function(CS2Item) onTap;

  const _RecentSection({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryProvider);

    if (history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 8),
            Text(
              '${items.length} items indexed',
              style: TextStyle(color: Colors.grey[500]),
            ),
            const SizedBox(height: 4),
            Text(
              'Type to filter — e.g. "redline" or "dragon lore factory new"',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Look each history entry up in the catalog. Skip anything that
    // can't be resolved (catalog may have been refreshed and the item
    // renamed/removed).
    final byHash = {for (final i in items) i.marketHashName: i};
    final recentItems = history
        .map((h) => byHash[h])
        .whereType<CS2Item>()
        .toList();

    if (recentItems.isEmpty) {
      return Center(
        child: Text(
          '${items.length} items indexed',
          style: TextStyle(color: Colors.grey[500]),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.history, size: 18, color: Colors.grey[400]),
              const SizedBox(width: 8),
              Text(
                'Recent',
                style: TextStyle(
                  color: Colors.grey[300],
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    ref.read(searchHistoryProvider.notifier).clear(),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: recentItems.length,
            cacheExtent: 500,
            itemBuilder: (context, i) {
              final item = recentItems[i];
              return _SearchResultCard(
                item: item,
                onTap: () => onTap(item),
                onDismiss: () => ref
                    .read(searchHistoryProvider.notifier)
                    .remove(item.marketHashName),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Result card for the Search tab. Watches per-item price state via
/// `select` so only its own row rebuilds when its prices arrive.
/// [onDismiss], when set, replaces the trailing chevron with an X
/// (used for Recent history entries).
class _SearchResultCard extends ConsumerWidget {
  final CS2Item item;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  const _SearchResultCard({
    required this.item,
    required this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rarityColor = CS2Colors.fromRarity(item.rarity);
    final hash = item.marketHashName;

    final steamState = ref.watch(searchPricesProvider.select((s) {
      if (s.loading.contains(hash) && !s.steam.containsKey(hash)) {
        return const _PriceCell.loading();
      }
      if (!s.steam.containsKey(hash)) return const _PriceCell.pending();
      return _PriceCell.value(s.steam[hash]);
    }));
    final cfPrice = ref.watch(
        searchPricesProvider.select((s) => s.csfloat[hash]));
    final cfFetched = ref.watch(
        searchPricesProvider.select((s) => s.csfloat.containsKey(hash)));

    return RepaintBoundary(
      child: Card(
        clipBehavior: Clip.hardEdge,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: rarityColor, width: 3)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 48,
                    child: Image.network(
                      item.imageUrl,
                      fit: BoxFit.contain,
                      cacheWidth: 128,
                      cacheHeight: 96,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.broken_image,
                        color: Colors.white24,
                        size: 20,
                      ),
                      loadingBuilder: (context, child, progress) =>
                          progress == null ? child : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.marketHashName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [item.weaponType, item.rarity].join(' • '),
                          style: TextStyle(color: Colors.grey[400], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  _PriceColumn(
                    steam: steamState,
                    csfloat: cfPrice,
                    csfloatFetched: cfFetched,
                  ),
                  if (onDismiss != null)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.white30,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Remove from history',
                      onPressed: onDismiss,
                    )
                  else
                    const Icon(Icons.chevron_right, color: Colors.white30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Render state for the Steam side of a result row.
class _PriceCell {
  final bool isLoading;
  final bool isPending; // queued but not yet fetched
  final double? price; // null when fetched with no listing

  const _PriceCell.loading()
      : isLoading = true,
        isPending = false,
        price = null;
  const _PriceCell.pending()
      : isLoading = false,
        isPending = true,
        price = null;
  const _PriceCell.value(this.price)
      : isLoading = false,
        isPending = false;

  @override
  bool operator ==(Object other) =>
      other is _PriceCell &&
      other.isLoading == isLoading &&
      other.isPending == isPending &&
      other.price == price;

  @override
  int get hashCode => Object.hash(isLoading, isPending, price);
}

class _PriceColumn extends StatelessWidget {
  final _PriceCell steam;
  final double? csfloat;
  final bool csfloatFetched;

  const _PriceColumn({
    required this.steam,
    required this.csfloat,
    required this.csfloatFetched,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          _steamText(),
          const SizedBox(height: 2),
          _csfloatText(),
        ],
      ),
    );
  }

  Widget _steamText() {
    if (steam.isLoading) {
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5),
      );
    }
    if (steam.isPending) {
      return Text('—', style: TextStyle(color: Colors.grey[600], fontSize: 13));
    }
    final price = steam.price;
    if (price == null) {
      return Text('n/a',
          style: TextStyle(color: Colors.grey[600], fontSize: 11));
    }
    return Text(
      '\$${price.toStringAsFixed(2)}',
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
    );
  }

  Widget _csfloatText() {
    if (!csfloatFetched) {
      return Text('—', style: TextStyle(color: Colors.grey[700], fontSize: 11));
    }
    if (csfloat == null) {
      return Text('n/a',
          style: TextStyle(color: Colors.grey[700], fontSize: 10));
    }
    return Text(
      '\$${csfloat!.toStringAsFixed(2)}',
      style: TextStyle(color: Colors.blueAccent[100], fontSize: 11),
    );
  }
}

// ── Filter sheet ─────────────────────────────────────────────────

class _SearchFilterSheet extends ConsumerWidget {
  const _SearchFilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rarities = ref.watch(availableSearchRaritiesProvider);
    final weaponTypes = ref.watch(availableSearchWeaponTypesProvider);
    final wears = ref.watch(availableSearchWearsProvider);
    final collections = ref.watch(availableSearchCollectionsProvider);

    final currentRarity = ref.watch(searchRarityFilterProvider);
    final currentWeapon = ref.watch(searchWeaponTypeFilterProvider);
    final currentWear = ref.watch(searchWearFilterProvider);
    final currentCollection = ref.watch(searchCollectionFilterProvider);
    final currentQuality = ref.watch(searchQualityFilterProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (context, scrollController) {
        return SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Filters',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  TextButton(
                    onPressed: () {
                      ref.read(searchRarityFilterProvider.notifier).clear();
                      ref.read(searchWeaponTypeFilterProvider.notifier).clear();
                      ref.read(searchWearFilterProvider.notifier).clear();
                      ref.read(searchCollectionFilterProvider.notifier).clear();
                      ref.read(searchQualityFilterProvider.notifier).clear();
                    },
                    child: const Text('Clear All'),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              _sectionLabel('Quality'),
              _chipWrap(
                options: const ['Normal', 'StatTrak', 'Souvenir'],
                selected: currentQuality,
                onToggle: (v) =>
                    ref.read(searchQualityFilterProvider.notifier).toggle(v),
              ),
              const SizedBox(height: 12),

              _sectionLabel('Rarity'),
              _chipWrap(
                options: rarities,
                selected: currentRarity,
                onToggle: (v) =>
                    ref.read(searchRarityFilterProvider.notifier).toggle(v),
                showRarityDot: true,
              ),
              const SizedBox(height: 12),

              _sectionLabel('Category'),
              _chipWrap(
                options: weaponTypes,
                selected: currentWeapon,
                onToggle: (v) => ref
                    .read(searchWeaponTypeFilterProvider.notifier)
                    .toggle(v),
              ),
              const SizedBox(height: 12),

              if (wears.isNotEmpty) ...[
                _sectionLabel('Wear'),
                _chipWrap(
                  options: wears,
                  selected: currentWear,
                  onToggle: (v) =>
                      ref.read(searchWearFilterProvider.notifier).toggle(v),
                ),
                const SizedBox(height: 12),
              ],

              _sectionLabel('Collection'),
              InkWell(
                onTap: () => _showCollectionPicker(context, collections),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    currentCollection.isEmpty
                        ? 'All Collections'
                        : '${currentCollection.length} selected',
                    style: TextStyle(
                      color: currentCollection.isEmpty
                          ? Colors.grey[500]
                          : Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.grey[400],
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _chipWrap({
    required List<String> options,
    required Set<String> selected,
    required void Function(String) onToggle,
    bool showRarityDot = false,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: options.map((opt) {
        return FilterChip(
          label: showRarityDot
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: CS2Colors.fromRarity(opt),
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(opt, style: const TextStyle(fontSize: 12)),
                  ],
                )
              : Text(opt, style: const TextStyle(fontSize: 12)),
          selected: selected.contains(opt),
          onSelected: (_) => onToggle(opt),
          visualDensity: VisualDensity.compact,
        );
      }).toList(),
    );
  }

  void _showCollectionPicker(BuildContext context, List<String> options) {
    showDialog(
      context: context,
      builder: (_) => _SearchCollectionDialog(options: options),
    );
  }
}

class _SearchCollectionDialog extends ConsumerStatefulWidget {
  final List<String> options;
  const _SearchCollectionDialog({required this.options});

  @override
  ConsumerState<_SearchCollectionDialog> createState() =>
      _SearchCollectionDialogState();
}

class _SearchCollectionDialogState
    extends ConsumerState<_SearchCollectionDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(searchCollectionFilterProvider);
    final q = _query.toLowerCase();
    final filtered = q.isEmpty
        ? widget.options
        : widget.options.where((c) => c.toLowerCase().contains(q)).toList();

    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search collections...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final name = filtered[i];
                  return CheckboxListTile(
                    title: Text(name, style: const TextStyle(fontSize: 14)),
                    value: selected.contains(name),
                    dense: true,
                    onChanged: (_) => ref
                        .read(searchCollectionFilterProvider.notifier)
                        .toggle(name),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => ref
                        .read(searchCollectionFilterProvider.notifier)
                        .clear(),
                    child: const Text('Clear'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
