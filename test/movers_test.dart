// Tests for the Top Movers dollar-change math. dollarChange24h
// reconstructs the per-unit dollar move from currentPrice and the
// percent change (baseline = current / (1 + pct/100)), which is the
// one non-obvious piece behind the %/$ ranking toggle.

import 'package:flutter_test/flutter_test.dart';
import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/providers/inventory_provider.dart';

CS2Item item({required double currentPrice, required double change}) => CS2Item(
  id: 'x',
  name: 'Test',
  weaponType: 'Rifle',
  skinName: 'Test',
  wear: 'Field-Tested',
  rarity: 'Classified',
  rarityColor: '#D32CE6',
  currentPrice: currentPrice,
  priceChange24h: change,
  imageUrl: '',
  marketHashName: 'Test',
);

void main() {
  group('dollarChange24h', () {
    test('zero percent change yields zero dollars', () {
      expect(dollarChange24h(item(currentPrice: 50, change: 0)), 0);
    });

    test('positive change: \$110 at +10% means a \$10 move from \$100', () {
      final d = dollarChange24h(item(currentPrice: 110, change: 10));
      expect(d, closeTo(10.0, 1e-9));
    });

    test('negative change: \$90 at -10% means a -\$10 move from \$100', () {
      final d = dollarChange24h(item(currentPrice: 90, change: -10));
      expect(d, closeTo(-10.0, 1e-9));
    });

    test('penny item with big percent is a tiny dollar move', () {
      // $0.04 at +33.3% — the noise case the price floor filters out.
      // The dollar move should be ~1 cent, not meaningful.
      final d = dollarChange24h(item(currentPrice: 0.04, change: 33.3));
      expect(d, lessThan(0.02));
    });
  });
}
