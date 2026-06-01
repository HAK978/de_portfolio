// Unit tests for the CS2Item data model.
//
// CS2Item is the core domain object — every inventory and storage-unit
// item flows through it. Its JSON contract is also what disk caching
// and Firestore sync depend on, so regressions here break persistence
// silently. These tests pin both the JSON parsing/serialization
// contract and the displayName formatting rules.

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

void main() {
  group('CS2Item.fromJson', () {
    test('parses all required fields', () {
      final item = CS2Item.fromJson({
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
      });

      expect(item.id, 'asset-1');
      expect(item.name, 'AK-47 | Redline');
      expect(item.weaponType, 'Rifle');
      expect(item.rarity, 'Classified');
      expect(item.currentPrice, 12.5);
      expect(item.marketHashName, 'AK-47 | Redline (Field-Tested)');
    });

    test('defaults isStatTrak and isSouvenir to false when omitted', () {
      final item = CS2Item.fromJson({
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
      });

      expect(item.isStatTrak, isFalse);
      expect(item.isSouvenir, isFalse);
    });

    test('defaults quantity to 1 and location to "inventory"', () {
      final item = CS2Item.fromJson({
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
      });

      expect(item.quantity, 1);
      expect(item.location, 'inventory');
    });

    test('accepts int currentPrice (num.toDouble coercion)', () {
      // Steam sometimes returns price as integer cents → app converts to
      // dollars as int. Make sure the num->double cast in fromJson works
      // for both ints and doubles.
      final item = CS2Item.fromJson({
        'id': 'asset-1',
        'name': 'AK-47 | Redline',
        'weaponType': 'Rifle',
        'skinName': 'Redline',
        'wear': 'Field-Tested',
        'rarity': 'Classified',
        'rarityColor': '#D32CE6',
        'currentPrice': 12, // integer literal, not 12.0
        'imageUrl': 'https://example.com/ak.png',
        'marketHashName': 'AK-47 | Redline (Field-Tested)',
      });

      expect(item.currentPrice, 12.0);
    });

    test('parses nullable optional fields (csfloatPrice, floatValue, collection)', () {
      final item = CS2Item.fromJson({
        'id': 'asset-1',
        'name': 'AK-47 | Redline',
        'weaponType': 'Rifle',
        'skinName': 'Redline',
        'wear': 'Field-Tested',
        'rarity': 'Classified',
        'rarityColor': '#D32CE6',
        'currentPrice': 12.5,
        'csfloatPrice': 11.20,
        'floatValue': 0.18,
        'collection': 'The Phoenix Collection',
        'imageUrl': 'https://example.com/ak.png',
        'marketHashName': 'AK-47 | Redline (Field-Tested)',
      });

      expect(item.csfloatPrice, 11.20);
      expect(item.floatValue, 0.18);
      expect(item.collection, 'The Phoenix Collection');
    });
  });

  group('CS2Item JSON round-trip', () {
    test('toJson + fromJson preserves every field', () {
      final original = makeItem(
        isStatTrak: true,
        csfloatPrice: 11.20,
        floatValue: 0.07,
        collection: 'The Bravo Collection',
        individualFloats: [0.06, 0.08, 0.09],
        quantity: 3,
      );

      final json = original.toJson();
      final restored = CS2Item.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.marketHashName, original.marketHashName);
      expect(restored.isStatTrak, original.isStatTrak);
      expect(restored.currentPrice, original.currentPrice);
      expect(restored.csfloatPrice, original.csfloatPrice);
      expect(restored.floatValue, original.floatValue);
      expect(restored.collection, original.collection);
      expect(restored.individualFloats, original.individualFloats);
      expect(restored.quantity, original.quantity);
    });
  });

  group('CS2Item.displayName', () {
    test('plain item returns "<name> (<wear>)"', () {
      final item = makeItem();
      expect(item.displayName, 'AK-47 | Redline (Field-Tested)');
    });

    test('StatTrak item prefixes with "StatTrak™ "', () {
      final item = makeItem(isStatTrak: true);
      expect(item.displayName, 'StatTrak™ AK-47 | Redline (Field-Tested)');
    });

    test('Souvenir item prefixes with "Souvenir "', () {
      final item = makeItem(isSouvenir: true);
      expect(item.displayName, 'Souvenir AK-47 | Redline (Field-Tested)');
    });

    test('item with no wear omits the wear suffix entirely', () {
      // Music kits, stickers, agents, etc. have no wear value.
      final item = makeItem(
        name: 'Music Kit | Daniel Sadowski, Crimson Assault',
        wear: null,
      );
      expect(item.displayName, 'Music Kit | Daniel Sadowski, Crimson Assault');
    });

    test('StatTrak prefix wins over Souvenir if both somehow true', () {
      // Real items can't be both, but the formatter shouldn't double-prefix.
      final item = makeItem(isStatTrak: true, isSouvenir: true);
      expect(item.displayName.startsWith('StatTrak™ '), isTrue);
      expect(item.displayName.contains('Souvenir'), isFalse);
    });
  });

  group('CS2Item.copyWith', () {
    test('preserves fields that are not overridden', () {
      final original = makeItem(currentPrice: 50.0, quantity: 1);
      final copy = original.copyWith(currentPrice: 75.0);

      expect(copy.currentPrice, 75.0);
      expect(copy.quantity, original.quantity);
      expect(copy.marketHashName, original.marketHashName);
      expect(copy.rarity, original.rarity);
    });

    test('does not mutate the original', () {
      final original = makeItem(currentPrice: 50.0);
      original.copyWith(currentPrice: 999.0);

      expect(original.currentPrice, 50.0);
    });
  });
}
