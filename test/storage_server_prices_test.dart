// Storage-unit items get server prices too: the app shares their names so
// the scheduled job prices them, then applies the results like it does for
// the inventory.

import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/models/storage_unit.dart';
import 'package:de_portfolio/providers/storage_provider.dart';
import 'package:de_portfolio/services/firestore_service.dart';
import 'package:flutter_test/flutter_test.dart';

CS2Item item(String name, {double price = 0, int quantity = 1, double? csfloat}) => CS2Item(
      id: name,
      name: name,
      weaponType: 'Other',
      skinName: '',
      wear: null,
      rarity: 'Base Grade',
      rarityColor: '#b0c3d9',
      currentPrice: price,
      csfloatPrice: csfloat,
      quantity: quantity,
      location: 'storage',
      imageUrl: '',
      marketHashName: name,
    );

StorageUnit unit(String id, List<CS2Item> items) =>
    StorageUnit(id: id, name: id, itemCount: items.length, totalValue: 0, items: items);

void main() {
  group('storageItemNamesForPricing', () {
    test('lists each item name once, sorted, across all units', () {
      final names = storageItemNamesForPricing([
        unit('a', [item('Revolution Case'), item('AK-47 | Redline (Field-Tested)')]),
        unit('b', [item('Revolution Case'), item('')]), // duplicate and blank
        unit('c', []), // not loaded yet
      ]);
      expect(names, ['AK-47 | Redline (Field-Tested)', 'Revolution Case']);
    });

    test('is capped at the limit the security rules allow', () {
      final many = [for (var i = 0; i < maxStorageItemNamesForPricing + 50; i++) item('Item ${i.toString().padLeft(5, '0')}')];
      final names = storageItemNamesForPricing([unit('a', many)]);
      expect(names, hasLength(maxStorageItemNamesForPricing));
    });
  });

  group('applyServerPricesToUnits', () {
    const prices = {
      'Revolution Case': ServerPriceData(currentPrice: 0.5, csfloatPrice: 0.45, priceChange24h: 4.2),
      'Kilowatt Case': ServerPriceData(currentPrice: 1.2, priceChange24h: null),
    };

    test('prices storage items and recomputes unit totals', () {
      final updated = applyServerPricesToUnits([
        unit('cases', [item('Revolution Case', quantity: 100), item('Unlisted Thing', price: 2)]),
      ], prices)!;

      final cases = updated.single;
      final revolution = cases.items.first;
      expect(revolution.currentPrice, 0.5);
      expect(revolution.csfloatPrice, 0.45);
      expect(revolution.priceChange24h, 4.2);
      expect(cases.items.last.currentPrice, 2); // no server price: untouched
      expect(cases.totalValue, closeTo(100 * 0.5 + 2, 1e-9));
      expect(cases.totalCsfloatValue, closeTo(100 * 0.45, 1e-9));
    });

    test('keeps an existing CSFloat price when the server has none', () {
      final updated = applyServerPricesToUnits([
        unit('u', [item('Kilowatt Case', price: 1, csfloat: 0.9)]),
      ], prices)!;
      expect(updated.single.items.single.currentPrice, 1.2);
      expect(updated.single.items.single.csfloatPrice, 0.9);
    });

    test('unchanged units stay the same objects, and nothing changed means null', () {
      final untouched = unit('other', [item('Unlisted Thing', price: 2)]);
      final updated = applyServerPricesToUnits([
        unit('cases', [item('Revolution Case')]),
        untouched,
      ], prices)!;
      expect(identical(updated[1], untouched), isTrue);

      // Applying the same prices again changes nothing.
      expect(applyServerPricesToUnits(updated, prices), isNull);
      expect(applyServerPricesToUnits([untouched], prices), isNull);
    });
  });
}
