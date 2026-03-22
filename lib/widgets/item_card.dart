import 'package:flutter/material.dart';

import '../models/cs2_item.dart';
import '../theme/app_theme.dart';
import 'price_change_badge.dart';

/// A card displaying an inventory item in a list.
///
/// Shows the item image, name, quantity (if > 1), price, and 24h change.
/// The left border is colored by the item's rarity.
///
/// Performance notes:
/// - Uses Image.network instead of CachedNetworkImage (much lighter widget)
/// - Clip.hardEdge instead of antiAlias (cheaper GPU operation)
/// - RepaintBoundary isolates each card's paint layer
/// - Fixed-size SizedBox for image prevents layout shifts
class ItemCard extends StatelessWidget {
  final CS2Item item;
  final VoidCallback? onTap;

  const ItemCard({super.key, required this.item, this.onTap});

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
                  // Item image
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
                      // Show nothing while loading — avoids placeholder rebuilds
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Name + quantity
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (item.isStatTrak) 'StatTrak\u2122',
                            if (item.wear != null) item.wear!,
                            if (item.quantity > 1) '\u00d7${item.quantity}',
                          ].join(' \u2022 '),
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Price + change
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '\$${item.currentPrice.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (item.csfloatPrice != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '\$${item.csfloatPrice!.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: Colors.blueAccent[100],
                                fontSize: 11,
                              ),
                            ),
                            if (item.currentPrice > 0) ...[
                              const SizedBox(width: 4),
                              Text(
                                item.csfloatPrice! < item.currentPrice
                                    ? '-${((1 - item.csfloatPrice! / item.currentPrice) * 100).toStringAsFixed(0)}%'
                                    : '+${((item.csfloatPrice! / item.currentPrice - 1) * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: item.csfloatPrice! < item.currentPrice
                                      ? Colors.greenAccent
                                      : Colors.redAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      PriceChangeBadge(percentage: item.priceChange24h),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
