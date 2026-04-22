import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/cs2_item.dart';
import '../../providers/inventory_provider.dart';
import '../../providers/price_history_provider.dart';
import '../../providers/price_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/price_change_badge.dart';
import '../../widgets/price_chart.dart';

class ItemDetailScreen extends ConsumerStatefulWidget {
  final String itemId;
  final CS2Item? passedItem;
  const ItemDetailScreen({super.key, required this.itemId, this.passedItem});

  @override
  ConsumerState<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends ConsumerState<ItemDetailScreen> {
  CS2Item? _enriched;
  bool _fetchingPrices = false;
  String? _fetchError;

  @override
  void initState() {
    super.initState();
    // Catalog-search items arrive with price 0 — fetch Steam + CSFloat now.
    final p = widget.passedItem;
    if (p != null && p.location == 'search') {
      _fetchingPrices = true;
      // Can't call ref.read in initState before first build completes;
      // defer to the next frame so the providers are ready.
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetchPrices(p));
    }
  }

  Future<void> _fetchPrices(CS2Item item) async {
    try {
      final priceService = ref.read(priceServiceProvider);
      final csfloatService = ref.read(csfloatServiceProvider);

      // Use search/render instead of priceoverview — priceoverview
      // routinely returns "not listed" for items that have live
      // listings (it only reflects items with *recent sales*).
      final steamFuture = priceService.fetchPriceViaSearch(item.marketHashName);
      final csfloatFuture = csfloatService.fetchPrice(item.marketHashName);

      final steamMatch = await steamFuture;
      final csfloatPrice = await csfloatFuture;

      if (!mounted) return;

      setState(() {
        _enriched = item.copyWith(
          currentPrice: steamMatch?.price ?? 0.0,
          csfloatPrice: csfloatPrice,
        );
        _fetchingPrices = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetchingPrices = false;
        _fetchError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Priority: freshly-fetched enriched item > passed item > inventory lookup
    CS2Item? item = _enriched ?? widget.passedItem;
    if (item == null) {
      final itemsAsync = ref.watch(inventoryProvider);
      final items = itemsAsync.when(
        data: (data) => data,
        loading: () => <CS2Item>[],
        error: (_, _) => <CS2Item>[],
      );
      item = items.where((i) => i.id == widget.itemId).firstOrNull;
    }

    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Item not found')),
      );
    }

    final rarityColor = CS2Colors.fromRarity(item.rarity);
    final isSearchItem = item.location == 'search';

    return Scaffold(
      appBar: AppBar(
        title: Text(item.name),
        actions: [
          if (isSearchItem)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh prices',
              onPressed: _fetchingPrices
                  ? null
                  : () {
                      // Capture into a non-nullable local — Dart demotes
                      // the promoted type inside a closure.
                      final target = item!;
                      setState(() {
                        _fetchingPrices = true;
                        _fetchError = null;
                      });
                      _fetchPrices(target);
                    },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Item image
          Container(
            height: 200,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: rarityColor.withAlpha(80)),
            ),
            child: CachedNetworkImage(
              imageUrl: item.imageUrl,
              fit: BoxFit.contain,
              placeholder: (context, url) => const Center(
                child: CircularProgressIndicator(),
              ),
              errorWidget: (context, url, error) => const Icon(
                Icons.broken_image,
                size: 64,
                color: Colors.white24,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Name + rarity badge
          Row(
            children: [
              Expanded(
                child: Text(
                  item.displayName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: rarityColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: rarityColor.withAlpha(100)),
                ),
                child: Text(
                  item.rarity,
                  style: TextStyle(
                    color: rarityColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (item.isStatTrak)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withAlpha(30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'StatTrak™',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),

          // Price section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _fetchingPrices
                  ? _priceLoadingBlock()
                  : _priceBlock(item, showNotListed: isSearchItem),
            ),
          ),
          const SizedBox(height: 12),

          // Details section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _DetailRow(label: 'Weapon Type', value: item.weaponType),
                  _DetailRow(label: 'Skin', value: item.skinName.isEmpty ? 'N/A' : item.skinName),
                  if (item.wear != null) _DetailRow(label: 'Wear', value: item.wear!),
                  if (item.floatValue != null)
                    _DetailRow(label: 'Float', value: item.floatValue!.toStringAsFixed(6)),
                  if (item.collection != null && item.collection!.isNotEmpty)
                    _DetailRow(label: 'Collection', value: item.collection!),
                  // Hide quantity / location / total-value rows for search items —
                  // they represent the catalog entry, not something the user owns.
                  if (!isSearchItem) ...[
                    _DetailRow(label: 'Quantity', value: '${item.quantity}'),
                    _DetailRow(label: 'Location', value: item.location),
                    if (item.quantity > 1)
                      _DetailRow(
                        label: 'Total Value',
                        value: '\$${(item.currentPrice * item.quantity).toStringAsFixed(2)}',
                      ),
                  ],
                ],
              ),
            ),
          ),
          // Individual floats for grouped items (inventory/storage only)
          if (!isSearchItem && item.individualFloats.length > 1) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Individual Floats (${item.individualFloats.length})',
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                    const SizedBox(height: 8),
                    ...item.individualFloats.asMap().entries.map((e) =>
                      _DetailRow(
                        label: 'Copy ${e.key + 1}',
                        value: e.value.toStringAsFixed(6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),

          // Price history chart
          _PriceHistorySection(marketHashName: item.marketHashName),
        ],
      ),
    );
  }

  Widget _priceLoadingBlock() {
    return Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Text(
          'Fetching Steam + CSFloat prices...',
          style: TextStyle(color: Colors.grey[300]),
        ),
      ],
    );
  }

  Widget _priceBlock(CS2Item item, {required bool showNotListed}) {
    // For search items where both prices failed to come back, say so
    // explicitly instead of rendering "$0.00".
    final steamMissing = showNotListed && item.currentPrice <= 0;
    final showCsfloat = item.csfloatPrice != null || showNotListed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Steam Market',
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text(
          steamMissing ? 'Not listed' : '\$${item.currentPrice.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: steamMissing ? 16 : 28,
            fontWeight: FontWeight.w800,
            color: steamMissing ? Colors.grey[500] : null,
          ),
        ),
        if (showCsfloat) ...[
          const SizedBox(height: 12),
          Text(
            'CSFloat',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                item.csfloatPrice != null
                    ? '\$${item.csfloatPrice!.toStringAsFixed(2)}'
                    : 'No listings',
                style: TextStyle(
                  fontSize: item.csfloatPrice != null ? 22 : 16,
                  fontWeight: FontWeight.w700,
                  color: item.csfloatPrice != null
                      ? Colors.blueAccent[100]
                      : Colors.grey[500],
                ),
              ),
              if (item.csfloatPrice != null && item.currentPrice > 0) ...[
                const SizedBox(width: 10),
                Builder(builder: (_) {
                  final cf = item.csfloatPrice!;
                  final cheaper = cf < item.currentPrice;
                  final pct = cheaper
                      ? (1 - cf / item.currentPrice) * 100
                      : (cf / item.currentPrice - 1) * 100;
                  return Text(
                    '${cheaper ? '-' : '+'}${pct.toStringAsFixed(1)}% vs Steam',
                    style: TextStyle(
                      color: cheaper ? Colors.greenAccent : Colors.redAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                }),
              ],
            ],
          ),
        ],
        if (_fetchError != null) ...[
          const SizedBox(height: 8),
          Text(
            'Fetch error: $_fetchError',
            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
          ),
        ],
        if (!showNotListed) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              _PriceChangeColumn(label: '24h', percentage: item.priceChange24h),
              const SizedBox(width: 24),
              _PriceChangeColumn(label: '7d', percentage: item.priceChange7d),
              const SizedBox(width: 24),
              _PriceChangeColumn(label: '30d', percentage: item.priceChange30d),
            ],
          ),
        ],
      ],
    );
  }
}

class _PriceChangeColumn extends StatelessWidget {
  final String label;
  final double percentage;

  const _PriceChangeColumn({required this.label, required this.percentage});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
        const SizedBox(height: 4),
        PriceChangeBadge(percentage: percentage),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.grey[400])),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Loads and displays the price history chart for an item.
///
/// Uses a FutureProvider.family to fetch data — shows a loading
/// spinner while fetching, an error state if it fails, and the
/// interactive chart when data is available.
class _PriceHistorySection extends ConsumerWidget {
  final String marketHashName;

  const _PriceHistorySection({required this.marketHashName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(priceHistoryProvider(marketHashName));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Price History',
              style: TextStyle(color: Colors.grey[400], fontSize: 14),
            ),
            const SizedBox(height: 12),
            historyAsync.when(
              loading: () => const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => SizedBox(
                height: 200,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.show_chart, size: 48, color: Colors.grey[600]),
                      const SizedBox(height: 8),
                      Text(
                        'Could not load price history',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Steam login may be required',
                        style: TextStyle(color: Colors.grey[700], fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              data: (data) {
                if (data == null || data.isEmpty) {
                  return SizedBox(
                    height: 200,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.show_chart, size: 48, color: Colors.grey[600]),
                          const SizedBox(height: 8),
                          Text(
                            'No price history available',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return PriceChart(data: data);
              },
            ),
          ],
        ),
      ),
    );
  }
}
