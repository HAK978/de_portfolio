import 'cs2_item.dart';

/// Represents a CS2 storage unit container.
///
/// Each storage unit can hold up to 1,000 items.
/// Users can have unlimited storage units.
class StorageUnit {
  final String id;
  final String name; // user-assigned label like "Cases & Keys"
  final int itemCount;
  final double totalValue;
  final double totalCsfloatValue;
  final List<CS2Item> items;

  const StorageUnit({
    required this.id,
    required this.name,
    required this.itemCount,
    required this.totalValue,
    this.totalCsfloatValue = 0.0,
    required this.items,
  });
}
