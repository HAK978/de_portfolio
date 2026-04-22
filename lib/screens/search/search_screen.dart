import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/cs2_item.dart';
import '../../providers/cs2_database_provider.dart';
import '../../providers/search_history_provider.dart';
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

/// Filtered + capped result list. Returns an empty list when there's
/// no query and no active filter — the UI falls back to "Recent" in
/// that case.
final filteredSearchResultsProvider = Provider<List<CS2Item>>((ref) {
  final items = _currentCatalogItems(ref);
  final query = ref.watch(searchCatalogQueryProvider).trim().toLowerCase();
  final rarity = ref.watch(searchRarityFilterProvider);
  final weapon = ref.watch(searchWeaponTypeFilterProvider);
  final wear = ref.watch(searchWearFilterProvider);
  final collection = ref.watch(searchCollectionFilterProvider);

  final tokens =
      query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

  final noInput = tokens.isEmpty &&
      rarity.isEmpty &&
      weapon.isEmpty &&
      wear.isEmpty &&
      collection.isEmpty;
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
    out.add(item);
    if (out.length >= _maxResults) break;
  }
  return out;
});

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
        ref.read(searchCollectionFilterProvider).isNotEmpty;
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
                  ref
                      .read(searchHistoryProvider.notifier)
                      .record(item.marketHashName);
                  context.push('/search/item', extra: item);
                },
              ),
            ),
          ),
        ],
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

    final chips = <Widget>[];
    void addChips(Set<String> values, void Function(String) onDelete) {
      for (final v in values) {
        chips.add(Padding(
          padding: const EdgeInsets.only(right: 6),
          child: InputChip(
            label: Text(v, style: const TextStyle(fontSize: 12)),
            onDeleted: () => onDelete(v),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ));
      }
    }

    addChips(rarity,
        (v) => ref.read(searchRarityFilterProvider.notifier).toggle(v));
    addChips(weapon,
        (v) => ref.read(searchWeaponTypeFilterProvider.notifier).toggle(v));
    addChips(
        wear, (v) => ref.read(searchWearFilterProvider.notifier).toggle(v));
    addChips(collection,
        (v) => ref.read(searchCollectionFilterProvider.notifier).toggle(v));

    if (chips.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
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

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: filtered.length,
      cacheExtent: 500,
      itemBuilder: (context, i) => _SearchResultCard(
        item: filtered[i],
        onTap: () => onTap(filtered[i]),
      ),
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

/// Slim card for search results — no price column since catalog items
/// have no price until tapped. [onDismiss] is only set for Recent entries
/// and renders a small close button so the user can prune individual
/// history items.
class _SearchResultCard extends StatelessWidget {
  final CS2Item item;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  const _SearchResultCard({
    required this.item,
    required this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final rarityColor = CS2Colors.fromRarity(item.rarity);
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
                          [
                            item.weaponType,
                            item.rarity,
                          ].join(' • '),
                          style: TextStyle(color: Colors.grey[400], fontSize: 12),
                        ),
                      ],
                    ),
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
                    },
                    child: const Text('Clear All'),
                  ),
                ],
              ),
              const SizedBox(height: 8),

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
