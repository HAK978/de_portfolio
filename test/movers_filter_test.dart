// Reactivity test for the Top Movers filter chain: changing
// moversFilterProvider must change what topGainersProvider returns.
// Proves whether the filter logic + provider wiring actually react.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/providers/inventory_provider.dart';

CS2Item mk({
  required String id,
  required String type,
  required double price,
  required double change,
}) => CS2Item(
  id: id,
  name: id,
  weaponType: type,
  skinName: id,
  wear: 'Field-Tested',
  rarity: 'Classified',
  rarityColor: '#D32CE6',
  currentPrice: price,
  priceChange24h: change,
  imageUrl: '',
  marketHashName: id,
);

void main() {
  final items = [
    mk(id: 'rifle5', type: 'Rifle', price: 5, change: 10),
    mk(id: 'knife50', type: 'Knife', price: 50, change: 5),
    mk(id: 'graffiti', type: 'Graffiti', price: 0.03, change: 33),
    mk(id: 'pistol20', type: 'Pistol', price: 20, change: -8),
    mk(id: 'rifle050', type: 'Rifle', price: 0.50, change: -20),
  ];

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        mainInventoryProvider.overrideWithValue(items),
      ]);

  test('default floor (\$1) excludes the \$0.03 graffiti from gainers', () {
    final c = makeContainer();
    addTearDown(c.dispose);
    final gainers = c.read(topGainersProvider).map((i) => i.id).toList();
    expect(gainers, contains('rifle5'));
    expect(gainers, contains('knife50'));
    expect(gainers, isNot(contains('graffiti'))); // filtered by $1 floor
  });

  test('raising the price floor reactively shrinks the list', () {
    final c = makeContainer();
    addTearDown(c.dispose);

    expect(c.read(topGainersProvider).map((i) => i.id), contains('rifle5'));

    c.read(moversFilterProvider.notifier).setMinPrice(10);
    final gainers = c.read(topGainersProvider).map((i) => i.id).toList();
    expect(gainers, ['knife50']); // only the $50 knife clears a $10 floor
  });

  test('category filter reactively narrows to one type', () {
    final c = makeContainer();
    addTearDown(c.dispose);

    c.read(moversFilterProvider.notifier).setCategory('Knife');
    final gainers = c.read(topGainersProvider).map((i) => i.id).toList();
    expect(gainers, ['knife50']);
  });

  test('rank-by-dollar toggle reorders gainers', () {
    final c = makeContainer();
    addTearDown(c.dispose);

    // By %: rifle5 (+10%) ranks above knife50 (+5%).
    expect(c.read(topGainersProvider).first.id, 'rifle5');

    // By $: knife50 (+5% of $50 = $2.38) beats rifle5 (+10% of $5 = $0.45).
    c.read(moversFilterProvider.notifier).setRankByDollar(true);
    expect(c.read(topGainersProvider).first.id, 'knife50');
  });
}
