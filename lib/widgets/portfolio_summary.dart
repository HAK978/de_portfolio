import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Displays the total portfolio value as a large, prominent card.
class PortfolioSummary extends StatelessWidget {
  final double totalValue;
  final double? csfloatValue;
  final int totalItems;
  final int storageUnitCount;

  const PortfolioSummary({
    super.key,
    required this.totalValue,
    this.csfloatValue,
    required this.totalItems,
    required this.storageUnitCount,
  });

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat.currency(symbol: '\$');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Steam Market Value',
              style: TextStyle(color: Colors.grey[400], fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              currencyFormat.format(totalValue),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (csfloatValue != null && csfloatValue! > 0) ...[
              const SizedBox(height: 12),
              Text(
                'CSFloat Value',
                style: TextStyle(color: Colors.grey[400], fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                currencyFormat.format(csfloatValue),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: Colors.blueAccent[100],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                _StatChip(
                  icon: Icons.inventory_2_outlined,
                  label: '$totalItems items',
                ),
                const SizedBox(width: 16),
                _StatChip(
                  icon: Icons.storage_outlined,
                  label: '$storageUnitCount storage units',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.grey[400]),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
      ],
    );
  }
}
