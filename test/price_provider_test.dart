// Unit tests for the marketable-item filtering used during price
// fetching. A regression here means we either spam Steam Market for
// items it doesn't price (service medals and coins, the Valve music
// kit) — wasting API budget — or silently drop items that should be
// priced (gloves share the medals' "Extraordinary" rarity).

import 'package:flutter_test/flutter_test.dart';
import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/providers/price_provider.dart';

/// Same builder helper as cs2_item_test, duplicated to keep each test
/// file self-contained and runnable in isolation.
CS2Item makeItem({
  String id = 'asset-1',
  String name = 'AK-47 | Redline',
  String weaponType = 'Rifle',
  String skinName = 'Redline',
  String? wear = 'Field-Tested',
  String rarity = 'Classified',
  String rarityColor = '#D32CE6',
  String marketHashName = 'AK-47 | Redline (Field-Tested)',
  bool isStatTrak = false,
  double currentPrice = 12.50,
}) => CS2Item(
  id: id,
  name: name,
  weaponType: weaponType,
  skinName: skinName,
  wear: wear,
  rarity: rarity,
  rarityColor: rarityColor,
  isStatTrak: isStatTrak,
  currentPrice: currentPrice,
  imageUrl: 'https://example.com/img.png',
  marketHashName: marketHashName,
);

void main() {
  group('isMarketable', () {
    test('returns true for an ordinary skin', () {
      expect(isMarketable(makeItem(rarity: 'Classified')), isTrue);
    });

    test('returns false for service medals and coins (Extraordinary, no ★)', () {
      // Coins, medals and badges use the Extraordinary rarity tier and
      // are never on the Steam Market.
      for (final name in ['5 Year Veteran Coin', 'Paris 2023 Gold Coin', '2025 Service Medal']) {
        final medal = makeItem(
          name: name,
          weaponType: 'Collectible',
          rarity: 'Extraordinary',
          marketHashName: name,
          wear: null,
        );
        expect(isMarketable(medal), isFalse, reason: name);
      }
    });

    test('returns true for gloves, which share the Extraordinary rarity', () {
      // Regression: every glove was skipped because only the rarity was
      // checked. Gloves are marketable and carry the ★ prefix.
      final gloves = makeItem(
        name: '★ Sport Gloves | Vice',
        weaponType: 'Gloves',
        rarity: 'Extraordinary',
        marketHashName: '★ Sport Gloves | Vice (Field-Tested)',
      );
      expect(isMarketable(gloves), isTrue);
    });

    test('returns true for knives (★ Covert)', () {
      final knife = makeItem(
        name: '★ Karambit | Doppler',
        weaponType: 'Knife',
        rarity: 'Covert',
        marketHashName: '★ StatTrak™ Karambit | Doppler (Factory New)',
      );
      expect(isMarketable(knife), isTrue);
    });

    test('returns false for the Valve-issued music kit', () {
      // Music Kit | Valve, CS:GO is the default music kit that ships
      // with every account — Steam Market refuses to list it.
      final kit = makeItem(
        name: 'Music Kit | Valve, CS:GO',
        rarity: 'High Grade',
        marketHashName: 'Music Kit | Valve, CS:GO',
        wear: null,
      );
      expect(isMarketable(kit), isFalse);
    });

    test('returns true for a different music kit (non-Valve)', () {
      // Make sure the exact-match exclusion above doesn't accidentally
      // exclude every music kit.
      final kit = makeItem(
        name: 'Music Kit | Daniel Sadowski, Crimson Assault',
        rarity: 'High Grade',
        marketHashName: 'Music Kit | Daniel Sadowski, Crimson Assault',
        wear: null,
      );
      expect(isMarketable(kit), isTrue);
    });

  });

  group('getMarketableNames', () {
    test('dedupes identical marketHashName values', () {
      final items = [
        makeItem(id: '1', marketHashName: 'AK-47 | Redline (Field-Tested)'),
        makeItem(id: '2', marketHashName: 'AK-47 | Redline (Field-Tested)'),
        makeItem(id: '3', marketHashName: 'M4A4 | Asiimov (Minimal Wear)'),
      ];

      final names = getMarketableNames(items);

      expect(names.length, 2);
      expect(names, contains('AK-47 | Redline (Field-Tested)'));
      expect(names, contains('M4A4 | Asiimov (Minimal Wear)'));
    });

    test('filters out non-marketable items before deduping', () {
      final items = [
        makeItem(id: '1', marketHashName: 'AK-47 | Redline (Field-Tested)'),
        makeItem(
          id: '2',
          rarity: 'Extraordinary',
          marketHashName: '5 Year Veteran Coin',
          wear: null,
        ),
      ];

      final names = getMarketableNames(items);

      expect(names, ['AK-47 | Redline (Field-Tested)']);
    });

    test('returns empty list when all items are non-marketable', () {
      final items = [
        makeItem(
          id: '1',
          rarity: 'Extraordinary',
          marketHashName: '5 Year Veteran Coin',
          wear: null,
        ),
        makeItem(
          id: '2',
          marketHashName: 'Music Kit | Valve, CS:GO',
          wear: null,
        ),
      ];

      expect(getMarketableNames(items), isEmpty);
    });
  });
}
