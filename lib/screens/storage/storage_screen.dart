import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/storage_unit.dart';
import '../../providers/inventory_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/item_card.dart';

class StorageScreen extends ConsumerWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storageUnits = ref.watch(storageUnitsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Storage Units',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: storageUnits.isEmpty
          ? const Center(
              child: Text(
                'No storage units found',
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: storageUnits.length,
              itemBuilder: (context, index) {
                return _StorageUnitCard(unit: storageUnits[index]);
              },
            ),
    );
  }
}

/// An expandable card for a storage unit.
///
/// Uses ExpansionTile — a Material widget that shows a header
/// and expands to reveal children when tapped. Perfect for
/// drill-down lists like storage unit contents.
class _StorageUnitCard extends StatelessWidget {
  final StorageUnit unit;
  const _StorageUnitCard({required this.unit});

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
          '${unit.itemCount} items \u2022 ${currencyFormat.format(unit.totalValue)}',
          style: TextStyle(color: Colors.grey[400], fontSize: 13),
        ),
        children: [
          if (unit.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Contents will be available after syncing (Phase 6)',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            )
          else
            ...unit.items.map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ItemCard(item: item),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
