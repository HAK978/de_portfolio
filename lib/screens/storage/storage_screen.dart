import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../models/cs2_collections.dart';
import '../../models/cs2_item.dart';
import '../../models/storage_unit.dart';
import '../../providers/price_provider.dart';
import '../../providers/storage_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/item_card.dart';
import '../inventory/inventory_screen.dart' show SortOption, PriceRange;

// ── Storage-specific filter providers ──

final _storageSearchProvider = NotifierProvider<_StorageSearchNotifier, String>(
  _StorageSearchNotifier.new,
);

class _StorageSearchNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

final _storageSortProvider = NotifierProvider<_StorageSortNotifier, SortOption>(
  _StorageSortNotifier.new,
);

class _StorageSortNotifier extends Notifier<SortOption> {
  @override
  SortOption build() => SortOption.priceDesc;
  void set(SortOption value) => state = value;
}

final _storageRarityProvider = NotifierProvider<_StorageRarityNotifier, Set<String>>(
  _StorageRarityNotifier.new,
);

class _StorageRarityNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String value) {
    if (state.contains(value)) {
      state = {...state}..remove(value);
    } else {
      state = {...state, value};
    }
  }
  void clear() => state = {};
}

final _storageWeaponTypeProvider = NotifierProvider<_StorageWeaponTypeNotifier, Set<String>>(
  _StorageWeaponTypeNotifier.new,
);

class _StorageWeaponTypeNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String value) {
    if (state.contains(value)) {
      state = {...state}..remove(value);
    } else {
      state = {...state, value};
    }
  }
  void clear() => state = {};
}

final _storagePriceRangeProvider =
    NotifierProvider<_StoragePriceRangeNotifier, ({double min, double max})?>(
  _StoragePriceRangeNotifier.new,
);

class _StoragePriceRangeNotifier extends Notifier<({double min, double max})?> {
  @override
  ({double min, double max})? build() => null;
  void set(({double min, double max})? value) => state = value;
}

final _storageWearProvider = NotifierProvider<_StorageWearNotifier, Set<String>>(
  _StorageWearNotifier.new,
);

class _StorageWearNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String value) {
    if (state.contains(value)) {
      state = {...state}..remove(value);
    } else {
      state = {...state, value};
    }
  }
  void clear() => state = {};
}

final _storageCollectionProvider = NotifierProvider<_StorageCollectionNotifier, Set<String>>(
  _StorageCollectionNotifier.new,
);

class _StorageCollectionNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void toggle(String value) {
    if (state.contains(value)) {
      state = {...state}..remove(value);
    } else {
      state = {...state, value};
    }
  }
  void clear() => state = {};
}

/// Applies search/sort/filter to a list of storage items.
List<CS2Item> _applyFilters(
  List<CS2Item> items, {
  required String query,
  required SortOption sort,
  required Set<String> rarity,
  required Set<String> weaponType,
  required Set<String> wear,
  required Set<String> collection,
  required ({double min, double max})? priceRange,
}) {
  var filtered = items.where((item) {
    if (query.isNotEmpty && !item.name.toLowerCase().contains(query)) {
      return false;
    }
    if (rarity.isNotEmpty && !rarity.contains(item.rarity)) return false;
    if (weaponType.isNotEmpty && !weaponType.contains(item.weaponType)) return false;
    if (wear.isNotEmpty && !wear.contains(item.wear)) return false;
    if (collection.isNotEmpty && !collection.contains(item.collection)) return false;
    if (priceRange != null &&
        (item.currentPrice < priceRange.min ||
            item.currentPrice >= priceRange.max)) {
      return false;
    }
    return true;
  }).toList();

  switch (sort) {
    case SortOption.priceDesc:
      filtered.sort((a, b) => b.currentPrice.compareTo(a.currentPrice));
    case SortOption.priceAsc:
      filtered.sort((a, b) => a.currentPrice.compareTo(b.currentPrice));
    case SortOption.csfloatDesc:
      filtered.sort((a, b) => (b.csfloatPrice ?? 0).compareTo(a.csfloatPrice ?? 0));
    case SortOption.csfloatAsc:
      filtered.sort((a, b) =>
          (a.csfloatPrice ?? double.infinity).compareTo(b.csfloatPrice ?? double.infinity));
    case SortOption.savingsDesc:
      filtered.sort((a, b) {
        final savA = (a.csfloatPrice != null && a.currentPrice > 0)
            ? (a.currentPrice - a.csfloatPrice!) / a.currentPrice
            : -1.0;
        final savB = (b.csfloatPrice != null && b.currentPrice > 0)
            ? (b.currentPrice - b.csfloatPrice!) / b.currentPrice
            : -1.0;
        return savB.compareTo(savA);
      });
    case SortOption.savingsRevDesc:
      filtered.sort((a, b) {
        final savA = (a.csfloatPrice != null && a.csfloatPrice! > 0)
            ? (a.csfloatPrice! - a.currentPrice) / a.csfloatPrice!
            : -1.0;
        final savB = (b.csfloatPrice != null && b.csfloatPrice! > 0)
            ? (b.csfloatPrice! - b.currentPrice) / b.csfloatPrice!
            : -1.0;
        return savB.compareTo(savA);
      });
    case SortOption.nameAsc:
      filtered.sort((a, b) => a.name.compareTo(b.name));
    case SortOption.quantityDesc:
      filtered.sort((a, b) => b.quantity.compareTo(a.quantity));
    case SortOption.changeDesc:
      filtered.sort((a, b) => b.priceChange24h.compareTo(a.priceChange24h));
  }

  return filtered;
}

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  final _searchController = TextEditingController();
  // Toggles the slide-down connection panel under the link icon. Was
  // _showUrlInput when the panel held URL/key inputs; those have moved
  // to Settings, so this is now purely a status + Refresh toggle.
  bool _showConnectionPanel = false;
  // Externalized expansion state. Keyed by unit id so multiple units
  // can be open simultaneously. Used by the SliverPersistentHeader
  // implementation so each header can pin while its content scrolls.
  final Set<String> _expandedUnitIds = {};

  @override
  void initState() {
    super.initState();
    _searchController.text = ref.read(_storageSearchProvider);
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _hasActiveFilters() {
    return ref.read(_storageRarityProvider).isNotEmpty ||
        ref.read(_storageWeaponTypeProvider).isNotEmpty ||
        ref.read(_storageWearProvider).isNotEmpty ||
        ref.read(_storageCollectionProvider).isNotEmpty ||
        ref.read(_storagePriceRangeProvider) != null;
  }

  void _toggleUnit(StorageUnit unit) {
    setState(() {
      if (_expandedUnitIds.contains(unit.id)) {
        _expandedUnitIds.remove(unit.id);
      } else {
        _expandedUnitIds.add(unit.id);
      }
    });
    // Trigger contents fetch on first expand (mirrors the previous
    // ExpansionTile.onExpansionChanged behavior).
    if (_expandedUnitIds.contains(unit.id)) {
      ref.read(storageProvider.notifier).fetchContents(unit.id);
    }
  }

  /// Builds the sliver for a single unit's expanded body — progress
  /// bars, filtered-count + Fetch Prices row, and the items list. The
  /// header (which stays pinned while these scroll) is the
  /// SliverPersistentHeader sibling above this sliver in the
  /// CustomScrollView.
  Widget _buildUnitContentSliver({
    required BuildContext context,
    required StorageUnit unit,
    required StorageState storage,
    required bool anyFetching,
    required String query,
    required SortOption currentSort,
    required Set<String> currentRarity,
    required Set<String> currentWeaponType,
    required Set<String> currentWear,
    required Set<String> currentCollection,
    required ({double min, double max})? currentPriceRange,
  }) {
    final isLoading = storage.loadingCaskets.contains(unit.id);
    final isPricing =
        storage.pricingCaskets.contains('${unit.id}_steam') ||
            storage.pricingCaskets.contains('${unit.id}_csfloat');
    final steamProgress = storage.pricingProgress['${unit.id}_steam'];
    final csfloatProgress = storage.pricingProgress['${unit.id}_csfloat'];

    final filteredItems = unit.items.isEmpty
        ? <CS2Item>[]
        : _applyFilters(
            unit.items,
            query: query,
            sort: currentSort,
            rarity: currentRarity,
            weaponType: currentWeaponType,
            wear: currentWear,
            collection: currentCollection,
            priceRange: currentPriceRange,
          );

    final totalFilteredQty =
        filteredItems.fold(0, (int sum, item) => sum + item.quantity);

    final widgets = <Widget>[];

    if (isLoading && unit.items.isEmpty) {
      widgets.add(const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (unit.items.isEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Loading contents...',
          style: TextStyle(color: Colors.grey[500], fontSize: 13),
        ),
      ));
    } else {
      if (steamProgress != null) widgets.add(_ProgressBar(progress: steamProgress));
      if (csfloatProgress != null) widgets.add(_ProgressBar(progress: csfloatProgress));

      widgets.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            Text(
              filteredItems.length == unit.items.length
                  ? '${unit.items.length} unique · ${unit.itemCount} total'
                  : '${filteredItems.length} unique · $totalFilteredQty total',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            const Spacer(),
            if (!isPricing)
              TextButton.icon(
                onPressed: anyFetching
                    ? null
                    : () => ref
                        .read(storageProvider.notifier)
                        .fetchAllPrices(unit.id),
                icon: Icon(
                  unit.totalValue > 0 ? Icons.refresh : Icons.download,
                  size: 16,
                ),
                label: Text(
                  unit.totalValue > 0 ? 'Refresh Prices' : 'Fetch Prices',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ));

      if (filteredItems.isEmpty) {
        widgets.add(Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No items match filters',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ));
      } else {
        for (final item in filteredItems) {
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ItemCard(
              item: item,
              onTap: () => context.go('/storage/item', extra: item),
            ),
          ));
        }
        widgets.add(const SizedBox(height: 8));
      }
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => widgets[i],
        childCount: widgets.length,
      ),
    );
  }

  void _showFilterSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => const _StorageFilterSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(storageProvider);
    final anyFetching = ref.watch(anyPriceFetchInProgressProvider); // disables storage fetch if Steam or CSFloat is busy
    final currentSort = ref.watch(_storageSortProvider);
    final currentRarity = ref.watch(_storageRarityProvider);
    final currentWeaponType = ref.watch(_storageWeaponTypeProvider);
    final currentWear = ref.watch(_storageWearProvider);
    final currentCollection = ref.watch(_storageCollectionProvider);
    final currentPriceRange = ref.watch(_storagePriceRangeProvider);
    final query = ref.watch(_storageSearchProvider).toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Storage Units',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: _hasActiveFilters(),
              smallSize: 8,
              child: const Icon(Icons.filter_list),
            ),
            onPressed: () => _showFilterSheet(context),
          ),
          PopupMenuButton<SortOption>(
            icon: const Icon(Icons.sort),
            onSelected: (option) {
              ref.read(_storageSortProvider.notifier).set(option);
            },
            itemBuilder: (context) {
              return SortOption.values.map((option) {
                return PopupMenuItem(
                  value: option,
                  child: Row(
                    children: [
                      if (option == currentSort)
                        const Icon(Icons.check, size: 18)
                      else
                        const SizedBox(width: 18),
                      const SizedBox(width: 8),
                      Text(option.label),
                    ],
                  ),
                );
              }).toList();
            },
          ),
          // Connection icon doubles as the entry point for the
          // service URL / API key panel AND as a live status indicator
          // (colored dot in the corner). Replaces the always-on
          // ConnectionBar row that used to sit below.
          Consumer(builder: (context, ref, _) {
            final statusAsync = ref.watch(storageStatusProvider);
            final dotColor = statusAsync.when(
              data: (s) => s.isReady
                  ? Colors.greenAccent
                  : s.unauthorized
                      ? Colors.amberAccent
                      : s.reachable
                          ? Colors.orangeAccent
                          : Colors.redAccent,
              loading: () => Colors.grey,
              error: (_, _) => Colors.redAccent,
            );
            return IconButton(
              tooltip: 'Connection',
              icon: SizedBox(
                width: 24,
                height: 24,
                child: Stack(
                  children: [
                    const Icon(Icons.link, size: 22),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.surface,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              onPressed: () => setState(
                () => _showConnectionPanel = !_showConnectionPanel,
              ),
            );
          }),
        ],
      ),
      body: Column(
        children: [
          if (_showConnectionPanel)
            _ConnectionPanel(
              isLoading: storage.isLoading,
              hasUnits: storage.units.isNotEmpty,
              onConnect: () {
                ref.invalidate(storageStatusProvider);
                ref.read(storageProvider.notifier).fetchCaskets();
              },
              onConfigure: () {
                setState(() => _showConnectionPanel = false);
                context.push('/settings');
              },
            ),

          // Search bar
          if (storage.units.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _searchController,
                onChanged: (value) {
                  ref.read(_storageSearchProvider.notifier).set(value);
                },
                decoration: InputDecoration(
                  hintText: 'Search storage items...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            ref.read(_storageSearchProvider.notifier).set('');
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

          if (storage.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                storage.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ),

          Expanded(
            child: storage.units.isEmpty && !storage.isLoading
                ? const Center(
                    child: Text(
                      'Tap Connect to fetch storage units\nfrom the local service',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : CustomScrollView(
                    slivers: [
                      const SliverPadding(
                        padding: EdgeInsets.only(top: 12),
                      ),
                      for (final unit in storage.units) ...[
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _UnitHeaderDelegate(
                            unit: unit,
                            expanded: _expandedUnitIds.contains(unit.id),
                            onTap: () => _toggleUnit(unit),
                          ),
                        ),
                        if (_expandedUnitIds.contains(unit.id))
                          _buildUnitContentSliver(
                            context: context,
                            unit: unit,
                            storage: storage,
                            anyFetching: anyFetching,
                            query: query,
                            currentSort: currentSort,
                            currentRarity: currentRarity,
                            currentWeaponType: currentWeaponType,
                            currentWear: currentWear,
                            currentCollection: currentCollection,
                            currentPriceRange: currentPriceRange,
                          ),
                      ],
                      const SliverPadding(
                        padding: EdgeInsets.only(bottom: 24),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Slide-down panel under the link icon. Shows live connection
/// status + Refresh/Connect, the active service URL, and a shortcut
/// to Settings (where URL + API key are configured). The fields
/// themselves moved to Settings — this panel is purely operational
/// state, not configuration.
class _ConnectionPanel extends ConsumerWidget {
  final bool isLoading;
  final bool hasUnits;
  final VoidCallback onConnect;
  final VoidCallback onConfigure;

  const _ConnectionPanel({
    required this.isLoading,
    required this.hasUnits,
    required this.onConnect,
    required this.onConfigure,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(storageStatusProvider);
    final url = ref.watch(storageServiceUrlProvider);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Status + Refresh/Connect
          Row(
            children: [
              Expanded(
                child: statusAsync.when(
                  data: (status) => Row(
                    children: [
                      Icon(
                        status.isReady ? Icons.circle : Icons.circle_outlined,
                        size: 12,
                        color: status.isReady
                            ? Colors.greenAccent
                            : status.unauthorized
                                ? Colors.amberAccent
                                : status.reachable
                                    ? Colors.orangeAccent
                                    : Colors.redAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          status.isReady
                              ? 'GC Connected'
                              : status.unauthorized
                                  ? 'Wrong API key — check Settings'
                                  : status.reachable
                                      ? 'Service up, GC disconnected'
                                      : 'Service unreachable',
                          style: TextStyle(
                            color: Colors.grey[300],
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                  loading: () => const Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('Checking...', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                  error: (_, _) => const Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 14, color: Colors.redAccent),
                      SizedBox(width: 8),
                      Text('Status check failed',
                          style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                    ],
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: isLoading ? null : onConnect,
                icon: isLoading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        hasUnits ? Icons.refresh : Icons.power_settings_new,
                        size: 18,
                      ),
                label: Text(hasUnits ? 'Refresh' : 'Connect'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Active URL display + Configure shortcut to Settings
          Row(
            children: [
              Expanded(
                child: Text(
                  url.isEmpty ? '(no URL configured)' : url,
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: onConfigure,
                icon: const Icon(Icons.settings, size: 14),
                label: const Text(
                  'Configure',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


/// Sticky-pinning header for one storage unit. The header rides the
/// top of the viewport while you scroll through that unit's expanded
/// items, so collapse-the-current-unit is one tap away no matter how
/// far you've scrolled. Tapping toggles expansion via [onTap].
class _UnitHeaderDelegate extends SliverPersistentHeaderDelegate {
  final StorageUnit unit;
  final bool expanded;
  final VoidCallback onTap;

  const _UnitHeaderDelegate({
    required this.unit,
    required this.expanded,
    required this.onTap,
  });

  static const double _height = 76.0;

  @override
  double get maxExtent => _height;
  @override
  double get minExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final currencyFormat = NumberFormat.currency(symbol: '\$');
    final hasValues = unit.totalValue > 0 || unit.totalCsfloatValue > 0;

    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: overlapsContent ? Colors.white12 : Colors.transparent,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.storage, color: CS2Colors.milSpec),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      unit.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '${unit.itemCount} items',
                          style: TextStyle(
                              color: Colors.grey[400], fontSize: 12),
                        ),
                        if (hasValues) ...[
                          if (unit.totalValue > 0) ...[
                            Text('  ·  ',
                                style: TextStyle(
                                    color: Colors.grey[600], fontSize: 11)),
                            Text(
                              'Steam ${currencyFormat.format(unit.totalValue)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                          if (unit.totalCsfloatValue > 0) ...[
                            Text('  ·  ',
                                style: TextStyle(
                                    color: Colors.grey[600], fontSize: 11)),
                            Text(
                              'CSF ${currencyFormat.format(unit.totalCsfloatValue)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _UnitHeaderDelegate oldDelegate) {
    return oldDelegate.expanded != expanded ||
        oldDelegate.unit.id != unit.id ||
        oldDelegate.unit.itemCount != unit.itemCount ||
        oldDelegate.unit.totalValue != unit.totalValue ||
        oldDelegate.unit.totalCsfloatValue != unit.totalCsfloatValue ||
        oldDelegate.unit.name != unit.name;
  }
}

class _StorageFilterSheet extends ConsumerWidget {
  const _StorageFilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentRarity = ref.watch(_storageRarityProvider);
    final currentWeaponType = ref.watch(_storageWeaponTypeProvider);
    final currentWear = ref.watch(_storageWearProvider);
    final currentCollection = ref.watch(_storageCollectionProvider);
    final currentPriceRange = ref.watch(_storagePriceRangeProvider);

    return SingleChildScrollView(
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
                  ref.read(_storageRarityProvider.notifier).clear();
                  ref.read(_storageWeaponTypeProvider.notifier).clear();
                  ref.read(_storageWearProvider.notifier).clear();
                  ref.read(_storageCollectionProvider.notifier).clear();
                  ref.read(_storagePriceRangeProvider.notifier).set(null);
                },
                child: const Text('Clear All'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Text('Rarity', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: ['Extraordinary', 'Covert', 'Classified', 'Restricted', 'Mil-Spec',
                'Industrial Grade', 'Consumer Grade']
                .map((r) => FilterChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: CS2Colors.fromRarity(r),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Text(r, style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                      selected: currentRarity.contains(r),
                      onSelected: (_) => ref.read(_storageRarityProvider.notifier).toggle(r),
                      visualDensity: VisualDensity.compact,
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),

          Text('Weapon Type', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: ['Rifle', 'Pistol', 'SMG', 'Shotgun', 'Machine Gun',
                'Knife', 'Gloves', 'Container', 'Sticker', 'Agent', 'Patch']
                .map((t) => FilterChip(
                      label: Text(t, style: const TextStyle(fontSize: 12)),
                      selected: currentWeaponType.contains(t),
                      onSelected: (_) => ref.read(_storageWeaponTypeProvider.notifier).toggle(t),
                      visualDensity: VisualDensity.compact,
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),

          Text('Wear', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: ['Factory New', 'Minimal Wear', 'Field-Tested', 'Well-Worn', 'Battle-Scarred']
                .map((w) => FilterChip(
                      label: Text(w, style: const TextStyle(fontSize: 12)),
                      selected: currentWear.contains(w),
                      onSelected: (_) => ref.read(_storageWearProvider.notifier).toggle(w),
                      visualDensity: VisualDensity.compact,
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),

          Text('Collection', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _showStorageCollectionPicker(context, ref),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                currentCollection.isEmpty
                    ? 'All Collections'
                    : '${currentCollection.length} selected',
                style: TextStyle(
                  color: currentCollection.isEmpty ? Colors.grey[500] : Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          _FilterDropdown<PriceRange?>(
            label: 'Price Range',
            value: _currentPriceRangeEnum(currentPriceRange),
            items: [
              const DropdownMenuItem<PriceRange?>(
                value: null,
                child: Text('Any Price'),
              ),
              ...PriceRange.values.map(
                (r) => DropdownMenuItem<PriceRange?>(
                  value: r,
                  child: Text(r.label),
                ),
              ),
            ],
            onChanged: (value) {
              if (value == null) {
                ref.read(_storagePriceRangeProvider.notifier).set(null);
              } else {
                ref.read(_storagePriceRangeProvider.notifier).set(
                  (min: value.min, max: value.max),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  void _showStorageCollectionPicker(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => const _StorageCollectionPickerDialog(),
    );
  }

  PriceRange? _currentPriceRangeEnum(({double min, double max})? range) {
    if (range == null) return null;
    for (final r in PriceRange.values) {
      if (r.min == range.min && r.max == range.max) return r;
    }
    return null;
  }
}

class _StorageCollectionPickerDialog extends ConsumerStatefulWidget {
  const _StorageCollectionPickerDialog();

  @override
  ConsumerState<_StorageCollectionPickerDialog> createState() =>
      _StorageCollectionPickerDialogState();
}

class _StorageCollectionPickerDialogState
    extends ConsumerState<_StorageCollectionPickerDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(_storageCollectionProvider);
    final filtered = allCs2Collections
        .where((c) => c.toLowerCase().contains(_search.toLowerCase()))
        .toList();

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
                onChanged: (v) => setState(() => _search = v),
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
                    onChanged: (_) {
                      ref
                          .read(_storageCollectionProvider.notifier)
                          .toggle(name);
                    },
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
                    onPressed: () =>
                        ref.read(_storageCollectionProvider.notifier).clear(),
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

class _FilterDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButton<T>(
            value: value,
            items: items,
            onChanged: onChanged,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: Theme.of(context).colorScheme.surface,
          ),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final PricingProgress progress;

  const _ProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${progress.label}: ${progress.fetched}/${progress.total}',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.percent,
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }
}
