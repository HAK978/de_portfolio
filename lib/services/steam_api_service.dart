import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';

/// Progress update emitted during inventory fetch.
class InventoryFetchProgress {
  final int itemsFetched;
  final int pagesFetched;
  final bool hasMore;

  const InventoryFetchProgress({
    required this.itemsFetched,
    required this.pagesFetched,
    required this.hasMore,
  });
}

/// Fetches CS2 inventory data from Steam's public API.
///
/// The Steam inventory endpoint returns two arrays:
/// - `assets`: what you own (assetid, classid, instanceid, amount)
/// - `descriptions`: item metadata (name, icon, tags, etc.)
///
/// We join them on classid + instanceid to build complete items.
/// The API returns max ~75 items per request, so we paginate using
/// the `last_assetid` cursor.
class SteamApiService {
  static const _baseUrl = 'https://steamcommunity.com/inventory';
  static const _imageBase =
      'https://community.cloudflare.steamstatic.com/economy/image/';
  static const _cacheFileName = 'inventory_cache.json';

  /// Callback for reporting fetch progress to the UI.
  /// Set by the provider before calling fetchInventory.
  void Function(InventoryFetchProgress)? onProgress;

  /// Fetches the full CS2 inventory for the given Steam ID.
  ///
  /// Returns a list of [CS2Item] with quantities grouped by
  /// market_hash_name. Throws on network errors or private inventory.
  Future<List<CS2Item>> fetchInventory(String steamId) async {
    final allAssets = <Map<String, dynamic>>[];
    final allDescriptions = <String, Map<String, dynamic>>{};

    String? cursor;
    bool hasMore = true;
    int pagesFetched = 0;

    while (hasMore) {
      final uri = Uri.parse(
        '$_baseUrl/$steamId/730/2?l=english&count=75'
        '${cursor != null ? '&start_assetid=$cursor' : ''}',
      );

      final response = await http.get(uri);

      if (response.statusCode == 429) {
        // Rate limited — wait and retry
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      if (response.statusCode == 403) {
        throw Exception('Inventory is private. Set it to public in Steam privacy settings.');
      }

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch inventory (HTTP ${response.statusCode})');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (data['success'] != 1) {
        throw Exception('Steam API returned an error');
      }

      // Collect assets
      final assets = data['assets'] as List<dynamic>? ?? [];
      allAssets.addAll(assets.cast<Map<String, dynamic>>());

      // Collect descriptions, keyed by classid_instanceid
      final descriptions = data['descriptions'] as List<dynamic>? ?? [];
      for (final desc in descriptions) {
        final d = desc as Map<String, dynamic>;
        final key = '${d['classid']}_${d['instanceid']}';
        allDescriptions[key] = d;
      }

      // Check for more pages
      hasMore = data['more_items'] == 1;
      pagesFetched++;

      // Report progress
      onProgress?.call(InventoryFetchProgress(
        itemsFetched: allAssets.length,
        pagesFetched: pagesFetched,
        hasMore: hasMore,
      ));

      if (hasMore) {
        cursor = data['last_assetid'] as String?;
        // Rate limit: wait between requests
        await Future.delayed(const Duration(milliseconds: 1100));
      }
    }

    final items = _buildItems(allAssets, allDescriptions);

    // Cache to disk
    await saveInventoryCache(steamId, items);

    return items;
  }

  /// Joins assets with descriptions and groups by market_hash_name.
  List<CS2Item> _buildItems(
    List<Map<String, dynamic>> assets,
    Map<String, Map<String, dynamic>> descriptions,
  ) {
    // Count how many of each item we have (by market_hash_name)
    final quantityMap = <String, int>{};
    final descriptionForHash = <String, Map<String, dynamic>>{};

    for (final asset in assets) {
      final key = '${asset['classid']}_${asset['instanceid']}';
      final desc = descriptions[key];
      if (desc == null) continue;

      final hashName = desc['market_hash_name'] as String? ?? desc['name'] as String;
      final amount = int.tryParse(asset['amount']?.toString() ?? '1') ?? 1;
      quantityMap[hashName] = (quantityMap[hashName] ?? 0) + amount;
      descriptionForHash[hashName] = desc;
    }

    // Build CS2Item for each unique item
    final items = <CS2Item>[];
    var idCounter = 0;

    for (final entry in descriptionForHash.entries) {
      final hashName = entry.key;
      final desc = entry.value;
      final quantity = quantityMap[hashName] ?? 1;

      items.add(_parseItem(
        id: (idCounter++).toString(),
        desc: desc,
        quantity: quantity,
      ));
    }

    return items;
  }

  /// Parses a Steam description object into a CS2Item.
  CS2Item _parseItem({
    required String id,
    required Map<String, dynamic> desc,
    required int quantity,
  }) {
    final tags = (desc['tags'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];

    // Extract fields from tags
    final weaponType = _getTagValue(tags, 'Type') ?? 'Other';
    final rarity = _getTagValue(tags, 'Rarity') ?? 'Consumer Grade';
    final rarityColor = _getTagColor(tags, 'Rarity') ?? 'b0c3d9';
    final wear = _getTagValue(tags, 'Exterior');
    final quality = _getTagValue(tags, 'Quality') ?? 'Normal';
    final collection = _getTagValue(tags, 'ItemSet');

    final name = desc['name'] as String? ?? 'Unknown';
    final marketHashName = desc['market_hash_name'] as String? ?? name;
    final iconUrl = desc['icon_url'] as String? ?? '';

    // Determine skin name (part after " | ")
    final skinName = name.contains(' | ') ? name.split(' | ').last : '';

    return CS2Item(
      id: id,
      name: name,
      weaponType: weaponType,
      skinName: skinName,
      wear: wear,
      rarity: rarity,
      rarityColor: '#$rarityColor',
      isStatTrak: quality == 'StatTrak\u2122' || quality == 'Strange',
      isSouvenir: quality == 'Souvenir' || quality == 'Tournament',
      currentPrice: 0, // Phase 4 will add pricing
      quantity: quantity,
      location: 'inventory',
      imageUrl: '$_imageBase$iconUrl',
      marketHashName: marketHashName,
      collection: collection,
    );
  }

  /// Finds a tag by category and returns its localized_tag_name.
  String? _getTagValue(List<Map<String, dynamic>> tags, String category) {
    for (final tag in tags) {
      if (tag['category'] == category) {
        return tag['localized_tag_name'] as String?;
      }
    }
    return null;
  }

  /// Finds a tag by category and returns its color.
  String? _getTagColor(List<Map<String, dynamic>> tags, String category) {
    for (final tag in tags) {
      if (tag['category'] == category) {
        return tag['color'] as String?;
      }
    }
    return null;
  }

  // ── Inventory caching ───────────────────────────────────────

  /// Saves inventory items + prices to a JSON file on disk.
  Future<void> saveInventoryCache(String steamId, List<CS2Item> items) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFileName');

      final data = {
        'steamId': steamId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'items': items.map((item) => item.toJson()).toList(),
      };

      await file.writeAsString(jsonEncode(data));
      debugPrint('Cached ${items.length} inventory items to disk');
    } catch (e) {
      debugPrint('Error saving inventory cache: $e');
    }
  }

  /// Loads cached inventory from disk.
  ///
  /// Returns null if no cache exists or it's for a different Steam ID.
  /// Does NOT expire — inventory cache is valid until the user
  /// explicitly refreshes (unlike price cache which expires hourly).
  Future<List<CS2Item>?> loadInventoryCache(String steamId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFileName');

      if (!file.existsSync()) return null;

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      // Check it's the same Steam ID
      if (data['steamId'] != steamId) return null;

      final itemsList = data['items'] as List<dynamic>;
      final items = itemsList
          .map((json) => CS2Item.fromJson(json as Map<String, dynamic>))
          .toList();

      debugPrint('Loaded ${items.length} items from inventory cache');
      return items;
    } catch (e) {
      debugPrint('Error loading inventory cache: $e');
      return null;
    }
  }
}
