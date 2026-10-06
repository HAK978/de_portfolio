import 'dart:async';

import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/services/inventory_sync.dart';
import 'package:flutter_test/flutter_test.dart';

CS2Item item(String id, {int quantity = 1, double? wear}) => CS2Item(
  id: id, name: id, weaponType: 'Rifle', skinName: '', wear: null,
  rarity: 'Classified', rarityColor: '#ffffff', currentPrice: 10,
  quantity: quantity, floatValue: wear, imageUrl: '', marketHashName: id,
);

class MemoryStore implements InventorySyncStore {
  final accounts = <String, Map<String, CS2Item>>{};
  final metadata = <String, int>{};
  int writes = 0;
  int? failAt;
  Completer<void>? gate;

  @override
  Future<Map<String, CS2Item>> load(String steamId) async {
    if (gate != null) await gate!.future;
    return {...accounts[steamId] ?? {}};
  }

  @override
  Future<void> writeBatch(String steamId, Map<String, CS2Item> updates, List<String> deletions) async {
    writes++;
    if (writes == failAt) throw StateError('network failure');
    final account = accounts.putIfAbsent(steamId, () => {});
    account.addAll(updates);
    for (final id in deletions) { account.remove(id); }
  }

  @override
  Future<void> writeMetadata(String steamId, int itemCount) async {
    metadata[steamId] = itemCount;
  }
}

void main() {
  test('syncs quantity and float changes with unchanged prices', () async {
    final store = MemoryStore()..accounts['a'] = {'x': item('x')};
    await InventorySynchronizer(store).save('a', [item('x', quantity: 3, wear: 0.12)]);
    expect(store.accounts['a']!['x']!.quantity, 3);
    expect(store.accounts['a']!['x']!.floatValue, 0.12);
  });

  test('complete snapshot removes sold items and supports an empty inventory', () async {
    final store = MemoryStore()..accounts['a'] = {'x': item('x'), 'y': item('y')};
    final sync = InventorySynchronizer(store);
    await sync.save('a', [item('x')], removeMissing: true);
    expect(store.accounts['a']!.keys, ['x']);
    await sync.save('a', [], removeMissing: true);
    expect(store.accounts['a'], isEmpty);
    expect(store.metadata['a'], 0);
  });

  test('cached price updates cannot delete missing cloud items', () async {
    final store = MemoryStore()..accounts['a'] = {'x': item('x'), 'y': item('y')};
    await InventorySynchronizer(store).save('a', [item('x')]);
    expect(store.accounts['a']!.keys, containsAll(['x', 'y']));
    expect(store.writes, 0);
  });

  test('failed batch does not mark complete and next sync retries remaining changes', () async {
    final store = MemoryStore()..failAt = 2;
    final sync = InventorySynchronizer(store);
    final items = List.generate(51, (i) => item('$i'));
    await expectLater(sync.save('a', items, removeMissing: true), throwsStateError);
    expect(store.accounts['a']!.length, 50);
    expect(store.metadata, isEmpty);
    store.failAt = null;
    await sync.save('a', items, removeMissing: true);
    expect(store.writes, 3);
    expect(store.metadata['a'], 51);
  });

  test('queued snapshots preserve order and do not share state between accounts', () async {
    final store = MemoryStore()..gate = Completer<void>();
    final sync = InventorySynchronizer(store);
    final first = sync.save('a', [item('x')], removeMissing: true);
    final second = sync.save('a', [item('x', quantity: 2)], removeMissing: true);
    final other = sync.save('b', [item('x', quantity: 7)], removeMissing: true);
    store.gate!.complete();
    await Future.wait([first, second, other]);
    expect(store.accounts['a']!['x']!.quantity, 2);
    expect(store.accounts['b']!['x']!.quantity, 7);
  });
}
