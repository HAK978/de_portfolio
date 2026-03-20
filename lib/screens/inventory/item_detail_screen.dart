import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/cs2_item.dart';
import '../../providers/inventory_provider.dart';
import '../../providers/price_history_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/price_change_badge.dart';
import '../../widgets/price_chart.dart';

class ItemDetailScreen extends ConsumerWidget {
  final String itemId;
  const ItemDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(inventoryProvider);
    final items = itemsAsync.when(
      data: (data) => data,
      loading: () => <CS2Item>[],
      error: (_, _) => <CS2Item>[],
    );
    final item = items.where((i) => i.id == itemId).firstOrNull;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Item not found')),
      );
    }

    final rarityColor = CS2Colors.fromRarity(item.rarity);

    return Scaffold(
      appBar: AppBar(title: Text(item.name)),
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
                    'StatTrak\u2122',
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Steam Market',
                    style: TextStyle(color: Colors.grey[400], fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '\$${item.currentPrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (item.csfloatPrice != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'CSFloat',
                      style: TextStyle(color: Colors.grey[400], fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '\$${item.csfloatPrice!.toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Colors.blueAccent[100],
                      ),
                    ),
                  ],
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
              ),
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
                  _DetailRow(label: 'Quantity', value: '${item.quantity}'),
                  _DetailRow(label: 'Location', value: item.location),
                  if (item.quantity > 1)
                    _DetailRow(
                      label: 'Total Value',
                      value: '\$${(item.currentPrice * item.quantity).toStringAsFixed(2)}',
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Price history chart
          _PriceHistorySection(marketHashName: item.marketHashName),
        ],
      ),
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
