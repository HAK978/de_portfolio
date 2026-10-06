// Unit tests for the CS2Item data model.
//
// CS2Item is the core domain object — every inventory and storage-unit
// item flows through it. Its JSON contract is what the disk cache and
// Firestore sync depend on, so a regression here breaks persistence
// silently (often only after an app update, when old caches are read).

import 'package:flutter_test/flutter_test.dart';
import 'package:de_portfolio/models/cs2_item.dart';

/// Builds a CS2Item with sensible defaults so each test only states
/// the fields it actually cares about.
CS2Item makeItem({
  String id = 'asset-1',
  String name = 'AK-47 | Redline',
  String weaponType = 'Rifle',
  String skinName = 'Redline',
  String? wear = 'Field-Tested',
  String rarity = 'Classified',
  String rarityColor = '#D32CE6',
  bool isStatTrak = false,
  bool isSouvenir = false,
  double currentPrice = 12.50,
  double? csfloatPrice,
  int quantity = 1,
  String imageUrl = 'https://example.com/ak.png',
  String marketHashName = 'AK-47 | Redline (Field-Tested)',
  String? collection,
  double? floatValue,
  List<double> individualFloats = const [],
}) => CS2Item(
  id: id,
  name: name,
  weaponType: weaponType,
  skinName: skinName,
  wear: wear,
  rarity: rarity,
  rarityColor: rarityColor,
  isStatTrak: isStatTrak,
  isSouvenir: isSouvenir,
  currentPrice: currentPrice,
  csfloatPrice: csfloatPrice,
  quantity: quantity,
  imageUrl: imageUrl,
  marketHashName: marketHashName,
  collection: collection,
  floatValue: floatValue,
  individualFloats: individualFloats,
);

/// The minimal JSON an item needs — what the oldest caches contain.
Map<String, dynamic> minimalJson() => {
  'id': 'asset-1',
  'name': 'AK-47 | Redline',
  'weaponType': 'Rifle',
  'skinName': 'Redline',
  'wear': 'Field-Tested',
  'rarity': 'Classified',
  'rarityColor': '#D32CE6',
  'currentPrice': 12.5,
  'imageUrl': 'https://example.com/ak.png',
  'marketHashName': 'AK-47 | Redline (Field-Tested)',
};

void main() {
  group('CS2Item.fromJson', () {
    test('a minimal (old-version) cache entry gets sensible defaults', () {
      final item = CS2Item.fromJson(minimalJson());

      expect(item.marketHashName, 'AK-47 | Redline (Field-Tested)');
      expect(item.currentPrice, 12.5);
      expect(item.isStatTrak, isFalse);
      expect(item.isSouvenir, isFalse);
      expect(item.quantity, 1);
      expect(item.location, 'inventory');
      expect(item.csfloatPrice, isNull);
      expect(item.priceChange24h, isNull); // unknown, not "0% change"
      expect(item.individualFloats, isEmpty);
    });

    test('accepts whole-number prices stored as ints', () {
      // jsonDecode and Firestore both return 12 (int) for 12.0, so a
      // plain `as double` cast would throw on reload.
      final item = CS2Item.fromJson({...minimalJson(), 'currentPrice': 12, 'csfloatPrice': 11});
      expect(item.currentPrice, 12.0);
      expect(item.csfloatPrice, 11.0);
    });

    test('parses the optional fields', () {
      final item = CS2Item.fromJson({
        ...minimalJson(),
        'csfloatPrice': 11.20,
        'floatValue': 0.18,
        'individualFloats': [0.18, 0.2],
        'collection': 'The Phoenix Collection',
        'priceChange24h': -2.5,
      });

      expect(item.csfloatPrice, 11.20);
      expect(item.floatValue, 0.18);
      expect(item.individualFloats, [0.18, 0.2]);
      expect(item.collection, 'The Phoenix Collection');
      expect(item.priceChange24h, -2.5);
    });
  });

  test('toJson + fromJson round-trips every field', () {
    final original = makeItem(
      isStatTrak: true,
      csfloatPrice: 11.20,
      floatValue: 0.07,
      collection: 'The Bravo Collection',
      individualFloats: [0.06, 0.08, 0.09],
      quantity: 3,
    ).copyWith(priceChange24h: 1.5, priceChange7d: -3.0, priceChange30d: 12.0, location: 'Storage Unit 1');

    // Comparing the full maps catches a field added to toJson but
    // forgotten in fromJson (or vice versa).
    expect(CS2Item.fromJson(original.toJson()).toJson(), original.toJson());
  });

  group('CS2Item.displayName', () {
    test('plain item is "<name> (<wear>)"', () {
      expect(makeItem().displayName, 'AK-47 | Redline (Field-Tested)');
    });

    test('names from Steam already carry StatTrak/Souvenir: no double prefix', () {
      // Real shapes from the Steam inventory API.
      final stattrak = makeItem(name: 'StatTrak™ AUG | Chameleon', wear: 'Factory New', isStatTrak: true);
      final souvenir = makeItem(name: 'Souvenir PP-Bizon | Anolis', isSouvenir: true);
      expect(stattrak.displayName, 'StatTrak™ AUG | Chameleon (Factory New)');
      expect(souvenir.displayName, 'Souvenir PP-Bizon | Anolis (Field-Tested)');
    });

    test('adds a missing prefix, keeping the knife star first', () {
      expect(makeItem(isStatTrak: true).displayName, 'StatTrak™ AK-47 | Redline (Field-Tested)');
      expect(makeItem(isSouvenir: true).displayName, 'Souvenir AK-47 | Redline (Field-Tested)');
      expect(
        makeItem(name: '★ Karambit | Doppler', wear: 'Factory New', isStatTrak: true).displayName,
        '★ StatTrak™ Karambit | Doppler (Factory New)',
      );
    });

    test('items without wear have no suffix', () {
      // Music kits, stickers, agents, etc. have no wear value.
      final kit = makeItem(name: 'Music Kit | Daniel Sadowski, Crimson Assault', wear: null);
      expect(kit.displayName, 'Music Kit | Daniel Sadowski, Crimson Assault');
    });
  });

  group('CS2Item.copyWith', () {
    test('omitted price changes are preserved and explicit null clears them', () {
      final original = makeItem().copyWith(priceChange24h: 10, priceChange7d: 20, priceChange30d: 30);
      expect(original.copyWith(quantity: 2).priceChange7d, 20);
      final cleared = original.copyWith(priceChange24h: null, priceChange7d: null, priceChange30d: null);
      expect(cleared.priceChange24h, isNull);
      expect(cleared.priceChange7d, isNull);
      expect(cleared.priceChange30d, isNull);
      expect(CS2Item.fromJson(cleared.toJson()).priceChange24h, isNull);
    });

    test('preserves fields that are not overridden', () {
      final original = makeItem(currentPrice: 50.0, quantity: 1);
      final copy = original.copyWith(currentPrice: 75.0);

      expect(copy.currentPrice, 75.0);
      expect(copy.toJson()..remove('currentPrice'), original.toJson()..remove('currentPrice'));
    });
  });
}
