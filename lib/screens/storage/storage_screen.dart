import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/cs2_item.dart';
import '../../models/storage_unit.dart';
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

final _storageRarityProvider = NotifierProvider<_StorageRarityNotifier, String?>(
  _StorageRarityNotifier.new,
);

class _StorageRarityNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? value) => state = value;
}

final _storageWeaponTypeProvider = NotifierProvider<_StorageWeaponTypeNotifier, String?>(
  _StorageWeaponTypeNotifier.new,
);

class _StorageWeaponTypeNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? value) => state = value;
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

final _storageWearProvider = NotifierProvider<_StorageWearNotifier, String?>(
  _StorageWearNotifier.new,
);

class _StorageWearNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? value) => state = value;
}

final _storageCollectionProvider = NotifierProvider<_StorageCollectionNotifier, String?>(
  _StorageCollectionNotifier.new,
);

class _StorageCollectionNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? value) => state = value;
}

/// Dynamically computed list of collections present in all storage items.
final _storageAvailableCollectionsProvider = Provider<List<String>>((ref) {
  final storage = ref.watch(storageProvider);
  final collections = <String>{};
  for (final unit in storage.units) {
    for (final item in unit.items) {
      if (item.collection != null) collections.add(item.collection!);
    }
  }
  final sorted = collections.toList()..sort();
  return sorted;
});

/// Applies search/sort/filter to a list of storage items.
List<CS2Item> _applyFilters(
  List<CS2Item> items, {
  required String query,
  required SortOption sort,
  required String? rarity,
  required String? weaponType,
  required String? wear,
  required String? collection,
  required ({double min, double max})? priceRange,
}) {
  var filtered = items.where((item) {
    if (query.isNotEmpty && !item.name.toLowerCase().contains(query)) {
      return false;
    }
    if (rarity != null && item.rarity != rarity) return false;
    if (weaponType != null && item.weaponType != weaponType) return false;
    if (wear != null && item.wear != wear) return false;
    if (collection != null && item.collection != collection) return false;
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
  final _urlController = TextEditingController();
  final _searchController = TextEditingController();
  bool _showUrlInput = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = ref.read(storageServiceUrlProvider);
    _searchController.text = ref.read(_storageSearchProvider);
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool _hasActiveFilters() {
    return ref.read(_storageRarityProvider) != null ||
        ref.read(_storageWeaponTypeProvider) != null ||
        ref.read(_storageWearProvider) != null ||
        ref.read(_storageCollectionProvider) != null ||
        ref.read(_storagePriceRangeProvider) != null;
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
    final serviceUrl = ref.watch(storageServiceUrlProvider);
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
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Service URL',
            onPressed: () {
              setState(() => _showUrlInput = !_showUrlInput);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showUrlInput)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      decoration: InputDecoration(
                        labelText: 'Service URL',
                        hintText: 'http://192.168.1.100:3456',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      ref.read(storageServiceUrlProvider.notifier).set(
                            _urlController.text.trim(),
                          );
                      setState(() => _showUrlInput = false);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
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

          _ConnectionBar(
            serviceUrl: serviceUrl,
            isLoading: storage.isLoading,
            hasUnits: storage.units.isNotEmpty,
            onConnect: () {
              ref.invalidate(storageStatusProvider);
              ref.read(storageProvider.notifier).fetchCaskets();
            },
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
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: storage.units.length,
                    itemBuilder: (context, index) {
                      final unit = storage.units[index];
                      final isLoading =
                          storage.loadingCaskets.contains(unit.id);
                      final isPricing =
                          storage.pricingCaskets.contains('${unit.id}_steam') ||
                          storage.pricingCaskets.contains('${unit.id}_csfloat');
                      final steamProgress =
                          storage.pricingProgress['${unit.id}_steam'];
                      final csfloatProgress =
                          storage.pricingProgress['${unit.id}_csfloat'];

                      // Apply filters to this unit's items
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

                      return _StorageUnitCard(
                        unit: unit,
                        filteredItems: filteredItems,
                        isLoading: isLoading,
                        isPricing: isPricing,
                        steamProgress: steamProgress,
                        csfloatProgress: csfloatProgress,
                        onExpand: () {
                          if (unit.items.isEmpty) {
                            ref
                                .read(storageProvider.notifier)
                                .fetchContents(unit.id);
                          }
                        },
                        onFetchPrices: () {
                          ref
                              .read(storageProvider.notifier)
                              .fetchAllPrices(unit.id);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBar extends ConsumerWidget {
  final String serviceUrl;
  final bool isLoading;
  final bool hasUnits;
  final VoidCallback onConnect;

  const _ConnectionBar({
    required this.serviceUrl,
    required this.isLoading,
    required this.hasUnits,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(storageStatusProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          statusAsync.when(
            data: (status) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  status.isReady ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: status.isReady
                      ? Colors.green
                      : status.reachable
                          ? Colors.orange
                          : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  status.isReady
                      ? 'GC Connected'
                      : status.reachable
                          ? 'Service up, GC disconnected'
                          : 'Service unreachable',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            loading: () => const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            error: (_, _) => const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 12, color: Colors.red),
                SizedBox(width: 8),
                Text('Error', style: TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ),
          ),

          const Spacer(),

          FilledButton.icon(
            onPressed: isLoading ? null : onConnect,
            icon: isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(hasUnits ? Icons.refresh : Icons.power_settings_new),
            label: Text(hasUnits ? 'Refresh' : 'Connect'),
          ),
        ],
      ),
    );
  }
}

class _StorageUnitCard extends StatelessWidget {
  final StorageUnit unit;
  final List<CS2Item> filteredItems;
  final bool isLoading;
  final bool isPricing;
  final PricingProgress? steamProgress;
  final PricingProgress? csfloatProgress;
  final VoidCallback onExpand;
  final VoidCallback onFetchPrices;

  const _StorageUnitCard({
    required this.unit,
    required this.filteredItems,
    required this.isLoading,
    required this.isPricing,
    this.steamProgress,
    this.csfloatProgress,
    required this.onExpand,
    required this.onFetchPrices,
  });

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat.currency(symbol: '\$');

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: const Icon(Icons.storage, color: CS2Colors.milSpec),
        title: Text(
          unit.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${unit.itemCount} items'
          '${unit.totalValue > 0 ? ' \u2022 ${currencyFormat.format(unit.totalValue)}' : ''}',
          style: TextStyle(color: Colors.grey[400], fontSize: 13),
        ),
        onExpansionChanged: (expanded) {
          if (expanded) onExpand();
        },
        children: [
          if (isLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (unit.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Expand to load contents',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            )
          else ...[
            // Pricing progress bars
            if (steamProgress != null)
              _ProgressBar(progress: steamProgress!),
            if (csfloatProgress != null)
              _ProgressBar(progress: csfloatProgress!),

            // Fetch prices button + item count
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                children: [
                  Text(
                    filteredItems.length == unit.items.length
                        ? '${unit.items.length} unique items'
                        : '${filteredItems.length}/${unit.items.length} items',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const Spacer(),
                  if (!isPricing)
                    TextButton.icon(
                      onPressed: onFetchPrices,
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
            ),

            // Items list
            if (filteredItems.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No items match filters',
                  style: TextStyle(color: Colors.grey[500], fontSize: 13),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 500),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: filteredItems.length,
                  itemBuilder: (context, index) {
                    return ItemCard(item: filteredItems[index]);
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
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
    final collections = ref.watch(_storageAvailableCollectionsProvider);

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
                  ref.read(_storageRarityProvider.notifier).set(null);
                  ref.read(_storageWeaponTypeProvider.notifier).set(null);
                  ref.read(_storageWearProvider.notifier).set(null);
                  ref.read(_storageCollectionProvider.notifier).set(null);
                  ref.read(_storagePriceRangeProvider.notifier).set(null);
                },
                child: const Text('Clear All'),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
              ref.read(_storageRarityProvider.notifier).set(value);
            },
          ),
          const SizedBox(height: 12),
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
              ref.read(_storageWeaponTypeProvider.notifier).set(value);
            },
          ),
          const SizedBox(height: 12),
          _FilterDropdown<String?>(
            label: 'Wear',
            value: currentWear,
            items: [
              const DropdownMenuItem(value: null, child: Text('All Wears')),
              ...['Factory New', 'Minimal Wear', 'Field-Tested', 'Well-Worn', 'Battle-Scarred']
                  .map((w) => DropdownMenuItem(value: w, child: Text(w))),
            ],
            onChanged: (value) {
              ref.read(_storageWearProvider.notifier).set(value);
            },
          ),
          const SizedBox(height: 12),
          if (collections.isNotEmpty) ...[
            _FilterDropdown<String?>(
              label: 'Collection',
              value: currentCollection,
              items: [
                const DropdownMenuItem(value: null, child: Text('All Collections')),
                ...collections.map((c) => DropdownMenuItem(value: c, child: Text(c))),
              ],
              onChanged: (value) {
                ref.read(_storageCollectionProvider.notifier).set(value);
              },
            ),
            const SizedBox(height: 12),
          ],
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

  PriceRange? _currentPriceRangeEnum(({double min, double max})? range) {
    if (range == null) return null;
    for (final r in PriceRange.values) {
      if (r.min == range.min && r.max == range.max) return r;
    }
    return null;
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
