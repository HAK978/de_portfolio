// Tests for applying Game Coordinator floats to the inventory. The VM
// only knows the floats of the Steam account it's logged in to, so they
// must never be pasted onto another account's items, and a slow float
// response must not overwrite newer state.

import 'dart:async';

import 'package:de_portfolio/models/cs2_item.dart';
import 'package:de_portfolio/providers/inventory_provider.dart';
import 'package:de_portfolio/providers/storage_provider.dart';
import 'package:de_portfolio/services/steam_api_service.dart';
import 'package:de_portfolio/services/storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const owner = '76561198000000001';
const visitor = '76561198000000002';
const redline = 'AK-47 | Redline (Field-Tested)';

CS2Item item(String name, {double price = 10}) => CS2Item(
      id: name,
      name: name,
      weaponType: 'Rifle',
      skinName: '',
      wear: 'Field-Tested',
      rarity: 'Classified',
      rarityColor: '#d32ce6',
      currentPrice: price,
      imageUrl: '',
      marketHashName: name,
    );

FloatData f(double value) => FloatData(assetId: '$value', floatValue: value);

/// Serves inventories from memory instead of the disk cache / Steam.
class FakeSteamApi extends SteamApiService {
  FakeSteamApi(this.inventories);
  final Map<String, List<CS2Item>> inventories;
  final saved = <String, List<CS2Item>>{};

  @override
  Future<List<CS2Item>?> loadInventoryCache(String steamId) async => inventories[steamId];

  @override
  Future<void> saveInventoryCache(String steamId, List<CS2Item> items) async => saved[steamId] = items;
}

/// A storage VM logged in to [vmSteamId] (null = older server).
class FakeVm extends StorageService {
  FakeVm({required this.vmSteamId, required this.floats}) : super(baseUrl: 'https://vm.test');
  final String? vmSteamId;
  final Map<String, List<FloatData>> floats;
  Completer<void>? gate;
  int floatRequests = 0;

  @override
  Future<StorageStatus> getStatus() async =>
      StorageStatus(reachable: true, steamConnected: true, steamId: vmSteamId);

  @override
  Future<Map<String, List<FloatData>>> getInventoryFloats() async {
    floatRequests++;
    await gate?.future;
    return floats;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('applyGcFloats', () {
    test('a stack gets every copy\'s float, sorted, and shows the best one', () {
      final result = applyGcFloats([item(redline)], {redline: [f(0.30), f(0.16), f(0.21)]});
      expect(result.single.individualFloats, [0.16, 0.21, 0.30]);
      expect(result.single.floatValue, 0.16);
      expect(result.single.currentPrice, 10); // everything else untouched
    });

    test('items without floats are returned unchanged', () {
      final sticker = item('Sticker | Example');
      final result = applyGcFloats([sticker], {redline: [f(0.2)]});
      expect(identical(result.single, sticker), isTrue);
    });
  });

  group('InventoryNotifier.fetchInventoryFloats', () {
    late FakeSteamApi steam;

    ProviderContainer containerFor(FakeVm vm, String viewing) {
      final container = ProviderContainer(overrides: [
        steamApiServiceProvider.overrideWithValue(steam),
        storageServiceProvider.overrideWithValue(vm),
      ]);
      addTearDown(container.dispose);
      container.read(steamIdProvider.notifier).set(viewing);
      return container;
    }

    List<CS2Item> itemsOf(ProviderContainer c) => c.read(inventoryProvider).value!;

    setUp(() {
      steam = FakeSteamApi({
        owner: [item(redline)],
        visitor: [item(redline, price: 12)],
      });
    });

    test('applies floats when the VM serves the account being viewed', () async {
      final vm = FakeVm(vmSteamId: owner, floats: {redline: [f(0.2)]});
      final c = containerFor(vm, owner);
      await c.read(inventoryProvider.future);

      await c.read(inventoryProvider.notifier).fetchInventoryFloats();

      expect(itemsOf(c).single.floatValue, 0.2);
      expect(steam.saved[owner]!.single.floatValue, 0.2); // persisted
    });

    test('never applies the VM account\'s floats to another inventory', () async {
      final vm = FakeVm(vmSteamId: owner, floats: {redline: [f(0.2)]});
      final c = containerFor(vm, visitor);
      await c.read(inventoryProvider.future);

      await c.read(inventoryProvider.notifier).fetchInventoryFloats();

      expect(itemsOf(c).single.floatValue, isNull);
      expect(vm.floatRequests, 0);
    });

    test('skips floats when the server doesn\'t say whose they are', () async {
      final vm = FakeVm(vmSteamId: null, floats: {redline: [f(0.2)]});
      final c = containerFor(vm, owner);
      await c.read(inventoryProvider.future);

      await c.read(inventoryProvider.notifier).fetchInventoryFloats();

      expect(itemsOf(c).single.floatValue, isNull);
    });

    test('a price update during the float fetch is not overwritten', () async {
      final vm = FakeVm(vmSteamId: owner, floats: {redline: [f(0.2)]})..gate = Completer<void>();
      final c = containerFor(vm, owner);
      await c.read(inventoryProvider.future);
      final notifier = c.read(inventoryProvider.notifier);

      final fetching = notifier.fetchInventoryFloats();
      await pumpEventQueue();
      notifier.updatePrices({redline: 15}, persist: false);
      vm.gate!.complete();
      await fetching;

      expect(itemsOf(c).single.currentPrice, 15);
      expect(itemsOf(c).single.floatValue, 0.2);
    });

    test('switching accounts mid-fetch drops the stale result', () async {
      final vm = FakeVm(vmSteamId: owner, floats: {redline: [f(0.2)]})..gate = Completer<void>();
      final c = containerFor(vm, owner);
      await c.read(inventoryProvider.future);

      final fetching = c.read(inventoryProvider.notifier).fetchInventoryFloats();
      await pumpEventQueue();
      c.read(steamIdProvider.notifier).set(visitor);
      await c.read(inventoryProvider.future);
      vm.gate!.complete();
      await fetching;

      expect(itemsOf(c).single.currentPrice, 12); // the visitor's inventory
      expect(itemsOf(c).single.floatValue, isNull);
    });
  });
}
