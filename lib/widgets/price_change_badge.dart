import 'package:flutter/material.dart';

/// A small badge showing a percentage change with color coding.
/// Green for positive, red for negative, grey for zero.
class PriceChangeBadge extends StatelessWidget {
  final double percentage;
  final bool showIcon;

  const PriceChangeBadge({
    super.key,
    required this.percentage,
    this.showIcon = true,
  });

  @override
  Widget build(BuildContext context) {
    final isPositive = percentage > 0;
    final isZero = percentage == 0;
    final color =
        isZero
            ? Colors.grey
            : isPositive
            ? Colors.greenAccent
            : Colors.redAccent;
    final icon =
        isZero
            ? Icons.remove
            : isPositive
            ? Icons.arrow_upward
            : Icons.arrow_downward;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) Icon(icon, size: 14, color: color),
          if (showIcon) const SizedBox(width: 2),
          Text(
            '${percentage >= 0 ? '+' : ''}${percentage.toStringAsFixed(1)}%',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
