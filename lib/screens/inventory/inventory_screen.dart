import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

final rarityFilterProvider = NotifierProvider<RarityFilterNotifier, String?>(
  RarityFilterNotifier.new,
);

class RarityFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? value) => state = value;
}

final weaponTypeFilterProvider =
    NotifierProvider<WeaponTypeFilterNotifier, String?>(
  WeaponTypeFilterNotifier.new,
);

class WeaponTypeFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? value) => state = value;
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
  final priceRange = ref.watch(priceRangeFilterProvider);

  var filtered = items.where((item) {
    if (query.isNotEmpty && !item.name.toLowerCase().contains(query)) {
      return false;
    }
    if (rarityFilter != null && item.rarity != rarityFilter) {
      return false;
    }
    if (weaponTypeFilter != null && item.weaponType != weaponTypeFilter) {
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

  bool _hasActiveFilters(
    String? rarity,
    String? weaponType,
    ({double min, double max})? priceRange,
  ) {
    return rarity != null || weaponType != null || priceRange != null;
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
    final currentRarity = ref.watch(rarityFilterProvider);
    final currentWeaponType = ref.watch(weaponTypeFilterProvider);
    final currentPriceRange = ref.watch(priceRangeFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Inventory (${allItems.length})',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          // Filter button — opens bottom sheet
          IconButton(
            icon: Badge(
              isLabelVisible: _hasActiveFilters(
                currentRarity,
                currentWeaponType,
                currentPriceRange,
              ),
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
    final currentPriceRange = ref.watch(priceRangeFilterProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
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

          // Header with clear button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Filters',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              TextButton(
                onPressed: () {
                  ref.read(rarityFilterProvider.notifier).set(null);
                  ref.read(weaponTypeFilterProvider.notifier).set(null);
                  ref.read(priceRangeFilterProvider.notifier).set(null);
                },
                child: const Text('Clear All'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Rarity dropdown
          _FilterDropdown<String?>(
            label: 'Rarity',
            value: currentRarity,
            items: [
              const DropdownMenuItem(value: null, child: Text('All Rarities')),
              ...['Extraordinary', 'Covert', 'Classified', 'Restricted', 'Mil-Spec',
                  'Industrial Grade', 'Consumer Grade']
                  .map((r) => DropdownMenuItem(
                        value: r,
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: CS2Colors.fromRarity(r),
                                shape: BoxShape.circle,
                              ),
                            ),
                            Text(r),
                          ],
                        ),
                      )),
            ],
            onChanged: (value) {
              ref.read(rarityFilterProvider.notifier).set(value);
            },
          ),
          const SizedBox(height: 12),

          // Weapon type dropdown
          _FilterDropdown<String?>(
            label: 'Weapon Type',
            value: currentWeaponType,
            items: [
              const DropdownMenuItem(value: null, child: Text('All Types')),
              ...['Rifle', 'Pistol', 'SMG', 'Shotgun', 'Machine Gun',
                  'Knife', 'Gloves', 'Container', 'Sticker', 'Agent', 'Patch']
                  .map((t) => DropdownMenuItem(value: t, child: Text(t))),
            ],
            onChanged: (value) {
              ref.read(weaponTypeFilterProvider.notifier).set(value);
            },
          ),
          const SizedBox(height: 12),

          // Price range dropdown
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
