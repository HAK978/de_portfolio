import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/cs2_collections.dart';
import '../../models/cs2_item.dart';
import '../../providers/inventory_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/item_card.dart';
import '../../widgets/inventory_loading.dart';

/// Controls the current search query and active filters.
///
/// In Riverpod 3, simple mutable state uses NotifierProvider.
/// A Notifier holds a single value and exposes `state` to read/write it.
/// Widgets call `ref.read(provider.notifier).state = newValue` to update.
final searchQueryProvider = NotifierProvider<SearchQueryNotifier, String>(
  SearchQueryNotifier.new,
);

class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

final sortOptionProvider = NotifierProvider<SortOptionNotifier, SortOption>(
  SortOptionNotifier.new,
);

class SortOptionNotifier extends Notifier<SortOption> {
  @override
  SortOption build() => SortOption.priceDesc;
  void set(SortOption value) => state = value;
}

final rarityFilterProvider = NotifierProvider<RarityFilterNotifier, Set<String>>(
  RarityFilterNotifier.new,
);

class RarityFilterNotifier extends Notifier<Set<String>> {
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

final weaponTypeFilterProvider =
    NotifierProvider<WeaponTypeFilterNotifier, Set<String>>(
  WeaponTypeFilterNotifier.new,
);

class WeaponTypeFilterNotifier extends Notifier<Set<String>> {
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

final wearFilterProvider = NotifierProvider<WearFilterNotifier, Set<String>>(
  WearFilterNotifier.new,
);

class WearFilterNotifier extends Notifier<Set<String>> {
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

final collectionFilterProvider = NotifierProvider<CollectionFilterNotifier, Set<String>>(
  CollectionFilterNotifier.new,
);

class CollectionFilterNotifier extends Notifier<Set<String>> {
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

/// Price range filter — stores (min, max) as a record.
/// null means no price filter is active.
final priceRangeFilterProvider =
    NotifierProvider<PriceRangeFilterNotifier, ({double min, double max})?>(
  PriceRangeFilterNotifier.new,
);

class PriceRangeFilterNotifier
    extends Notifier<({double min, double max})?> {
  @override
  ({double min, double max})? build() => null;
  void set(({double min, double max})? value) => state = value;
}

/// Predefined price ranges for the filter chips.
enum PriceRange {
  under1('Under \$1', 0, 1),
  under10('\$1 - \$10', 1, 10),
  under50('\$10 - \$50', 10, 50),
  under200('\$50 - \$200', 50, 200),
  over200('\$200+', 200, double.infinity);

  final String label;
  final double min;
  final double max;
  const PriceRange(this.label, this.min, this.max);
}

enum SortOption {
  priceDesc('Price: High to Low'),
  priceAsc('Price: Low to High'),
  csfloatDesc('CSFloat: High to Low'),
  csfloatAsc('CSFloat: Low to High'),
  savingsDesc('Best Deal (Steam vs CF)'),
  nameAsc('Name: A-Z'),
  quantityDesc('Quantity: Most'),
  changeDesc('24h Change: Best');

  final String label;
  const SortOption(this.label);
}

/// Filtered + sorted inventory derived from the base providers.
final filteredInventoryProvider = Provider<List<CS2Item>>((ref) {
  final items = ref.watch(mainInventoryProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase();
  final sort = ref.watch(sortOptionProvider);
  final rarityFilter = ref.watch(rarityFilterProvider);
  final weaponTypeFilter = ref.watch(weaponTypeFilterProvider);
  final wearFilter = ref.watch(wearFilterProvider);
  final collectionFilter = ref.watch(collectionFilterProvider);
  final priceRange = ref.watch(priceRangeFilterProvider);

  var filtered = items.where((item) {
    if (query.isNotEmpty && !item.name.toLowerCase().contains(query)) {
      return false;
    }
    if (rarityFilter.isNotEmpty && !rarityFilter.contains(item.rarity)) {
      return false;
    }
    if (weaponTypeFilter.isNotEmpty && !weaponTypeFilter.contains(item.weaponType)) {
      return false;
    }
    if (wearFilter.isNotEmpty && !wearFilter.contains(item.wear)) {
      return false;
    }
    if (collectionFilter.isNotEmpty && !collectionFilter.contains(item.collection)) {
      return false;
    }
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
      filtered.sort((a, b) => (a.csfloatPrice ?? double.infinity).compareTo(b.csfloatPrice ?? double.infinity));
    case SortOption.savingsDesc:
      // Sort by biggest % savings: (steam - csfloat) / steam
      filtered.sort((a, b) {
        final savA = (a.csfloatPrice != null && a.currentPrice > 0)
            ? (a.currentPrice - a.csfloatPrice!) / a.currentPrice
            : -1.0;
        final savB = (b.csfloatPrice != null && b.currentPrice > 0)
            ? (b.currentPrice - b.csfloatPrice!) / b.currentPrice
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
});

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  late TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(searchQueryProvider),
    );
    // Rebuild when text changes so the clear button shows/hides
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    // Clear search when leaving the screen so it doesn't
    // filter items when you come back
    super.dispose();
  }

  bool _hasActiveFilters() {
    return ref.read(rarityFilterProvider).isNotEmpty ||
        ref.read(weaponTypeFilterProvider).isNotEmpty ||
        ref.read(wearFilterProvider).isNotEmpty ||
        ref.read(collectionFilterProvider).isNotEmpty ||
        ref.read(priceRangeFilterProvider) != null;
  }

  void _showFilterSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => const _FilterSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inventoryAsync = ref.watch(inventoryProvider);

    // Show loading/error states
    if (inventoryAsync is AsyncLoading) {
      return const InventoryLoading(title: 'Inventory');
    }
    if (inventoryAsync is AsyncError) {
      return InventoryLoading(
        title: 'Inventory',
        error: inventoryAsync.error.toString(),
        onRetry: () => ref.read(inventoryProvider.notifier).refresh(),
      );
    }

    final items = ref.watch(filteredInventoryProvider);
    final allItems = ref.watch(mainInventoryProvider);
    final currentSort = ref.watch(sortOptionProvider);
    // Watch filters to trigger rebuild for badge
    ref.watch(rarityFilterProvider);
    ref.watch(weaponTypeFilterProvider);
    ref.watch(wearFilterProvider);
    ref.watch(collectionFilterProvider);
    ref.watch(priceRangeFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Inventory (${allItems.length})',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          // Fetch inventory from Steam
          _FetchInventoryButton(),
          // Filter button — opens bottom sheet
          IconButton(
            icon: Badge(
              isLabelVisible: _hasActiveFilters(),
              smallSize: 8,
              child: const Icon(Icons.filter_list),
            ),
            onPressed: () => _showFilterSheet(context, ref),
          ),
          // Sort dropdown
          PopupMenuButton<SortOption>(
            icon: const Icon(Icons.sort),
            onSelected: (option) {
              ref.read(sortOptionProvider.notifier).set(option);
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
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                ref.read(searchQueryProvider.notifier).set(value);
              },
              decoration: InputDecoration(
                hintText: 'Search items...',
                prefixIcon: const Icon(Icons.search),
                // Show clear button when there's text
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          ref.read(searchQueryProvider.notifier).set('');
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

          // Item list
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'No items match your search',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: items.length,
                      cacheExtent: 500,
                      addAutomaticKeepAlives: false,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return ItemCard(
                          item: item,
                          onTap: () => context.go('/inventory/${item.id}'),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

/// Button that fetches inventory from Steam, showing progress while active.
class _FetchInventoryButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fetchProgress = ref.watch(inventoryFetchProgressProvider);

    if (fetchProgress.isFetching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    return IconButton(
      icon: const Icon(Icons.refresh),
      tooltip: 'Fetch inventory from Steam',
      onPressed: () {
        ref.read(inventoryProvider.notifier).refresh();
      },
    );
  }
}

/// Bottom sheet with dropdown menus for each filter category.
///
/// This is a ConsumerWidget so it can read/write Riverpod providers.
/// Using a bottom sheet keeps the main screen clean while giving
/// plenty of room for filter options.
class _FilterSheet extends ConsumerWidget {
  const _FilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentRarity = ref.watch(rarityFilterProvider);
    final currentWeaponType = ref.watch(weaponTypeFilterProvider);
    final currentWear = ref.watch(wearFilterProvider);
    final currentCollection = ref.watch(collectionFilterProvider);
    final currentPriceRange = ref.watch(priceRangeFilterProvider);

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
                  ref.read(rarityFilterProvider.notifier).clear();
                  ref.read(weaponTypeFilterProvider.notifier).clear();
                  ref.read(wearFilterProvider.notifier).clear();
                  ref.read(collectionFilterProvider.notifier).clear();
                  ref.read(priceRangeFilterProvider.notifier).set(null);
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
                      onSelected: (_) => ref.read(rarityFilterProvider.notifier).toggle(r),
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
                      onSelected: (_) => ref.read(weaponTypeFilterProvider.notifier).toggle(t),
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
                      onSelected: (_) => ref.read(wearFilterProvider.notifier).toggle(w),
                      visualDensity: VisualDensity.compact,
                    ))
                .toList(),
          ),
          const SizedBox(height: 12),

          Text('Collection', style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _showCollectionPicker(context, ref),
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
                ref.read(priceRangeFilterProvider.notifier).set(null);
              } else {
                ref.read(priceRangeFilterProvider.notifier).set(
                  (min: value.min, max: value.max),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// Match the current price range record back to a PriceRange enum value.
  PriceRange? _currentPriceRangeEnum(({double min, double max})? range) {
    if (range == null) return null;
    for (final r in PriceRange.values) {
      if (r.min == range.min && r.max == range.max) return r;
    }
    return null;
  }
}

void _showCollectionPicker(BuildContext context, WidgetRef ref) {
  showDialog(
    context: context,
    builder: (context) => const _CollectionPickerDialog(),
  );
}

class _CollectionPickerDialog extends ConsumerStatefulWidget {
  const _CollectionPickerDialog();

  @override
  ConsumerState<_CollectionPickerDialog> createState() =>
      _CollectionPickerDialogState();
}

class _CollectionPickerDialogState
    extends ConsumerState<_CollectionPickerDialog> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(collectionFilterProvider);
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
                          .read(collectionFilterProvider.notifier)
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
                        ref.read(collectionFilterProvider.notifier).clear(),
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

/// A labeled dropdown used inside the filter bottom sheet.
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
