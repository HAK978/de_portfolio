import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../services/csfloat_service.dart';
import '../services/price_service.dart';

const _kInventoryCacheFile = 'inventory_cache.json';
const _kStorageCachePrefix = 'storage_cache_';
const _kCsfloatApiKeyFile = 'csfloat_api_key.txt';
const _kLastFetchFile = 'last_price_fetch.txt';

/// Entry point for the WorkManager background price refresh task.
/// Refreshes Steam + CSFloat prices for inventory and all storage units.
Future<bool> runPriceRefreshBackground() async {
  try {
    debugPrint('[BG] Starting background price refresh');
    final dir = await getApplicationDocumentsDirectory();

    await _refreshInventoryPrices(dir.path);
    await _refreshStoragePrices(dir.path);

    // Record when the refresh ran so the foreground app doesn't re-fetch
    await File('${dir.path}/$_kLastFetchFile')
        .writeAsString(DateTime.now().millisecondsSinceEpoch.toString());

    debugPrint('[BG] Background price refresh complete');
    return true;
  } catch (e) {
    debugPrint('[BG] Background price refresh failed: $e');
    return false;
  }
}

Future<void> _refreshInventoryPrices(String dirPath) async {
  final file = File('$dirPath/$_kInventoryCacheFile');
  if (!file.existsSync()) return;

  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final itemsList = data['items'] as List<dynamic>;
  if (itemsList.isEmpty) return;

  final names = itemsList
      .map((i) => (i as Map<String, dynamic>)['marketHashName'] as String)
      .toSet()
      .toList();

  debugPrint('[BG] Fetching Steam prices for ${names.length} inventory items');
  final prices = <String, double>{};
  await for (final progress in PriceService().fetchPrices(names)) {
    prices.addAll(progress.prices);
  }
  if (prices.isEmpty) return;

  final updatedItems = itemsList.map((item) {
    final i = Map<String, dynamic>.from(item as Map<String, dynamic>);
    final price = prices[i['marketHashName'] as String];
    if (price != null) i['currentPrice'] = price;
    return i;
  }).toList();

  await file.writeAsString(jsonEncode({...data, 'items': updatedItems}));
}

Future<void> _refreshStoragePrices(String dirPath) async {
  final cacheFiles = Directory(dirPath)
      .listSync()
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.startsWith(_kStorageCachePrefix))
      .toList();

  if (cacheFiles.isEmpty) return;

  // Read CSFloat API key once
  String? csfloatKey;
  final keyFile = File('$dirPath/$_kCsfloatApiKeyFile');
  if (keyFile.existsSync()) {
    csfloatKey = (await keyFile.readAsString()).trim();
    if (csfloatKey.isEmpty) csfloatKey = null;
  }

  final priceService = PriceService();
  final csfloatService =
      csfloatKey != null ? CsfloatService(apiKey: csfloatKey) : null;

  for (final f in cacheFiles) {
    try {
      await _refreshStorageCache(f, priceService, csfloatService);
    } catch (e) {
      debugPrint('[BG] Error refreshing ${f.uri.pathSegments.last}: $e');
    }
  }
}

Future<void> _refreshStorageCache(
  File cacheFile,
  PriceService priceService,
  CsfloatService? csfloatService,
) async {
  final data =
      jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
  final itemsList = data['items'] as List<dynamic>;
  if (itemsList.isEmpty) return;

  final names = itemsList
      .map((i) => (i as Map<String, dynamic>)['marketHashName'] as String)
      .toSet()
      .toList();

  debugPrint('[BG] Fetching prices for ${names.length} items in ${cacheFile.uri.pathSegments.last}');

  final steamPrices = <String, double>{};
  await for (final p in priceService.fetchPrices(names)) {
    steamPrices.addAll(p.prices);
  }

  final csfloatPrices = <String, double>{};
  if (csfloatService != null) {
    await for (final p in csfloatService.fetchPrices(names)) {
      csfloatPrices.addAll(p.prices);
    }
  }

  final updatedItems = itemsList.map((item) {
    final i = Map<String, dynamic>.from(item as Map<String, dynamic>);
    final name = i['marketHashName'] as String;
    if (steamPrices.containsKey(name)) i['currentPrice'] = steamPrices[name];
    if (csfloatPrices.containsKey(name)) i['csfloatPrice'] = csfloatPrices[name];
    return i;
  }).toList();

  await cacheFile.writeAsString(jsonEncode({
    ...data,
    'items': updatedItems,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  }));
}
