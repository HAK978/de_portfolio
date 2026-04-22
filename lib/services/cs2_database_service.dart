import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';

/// Fetches and caches the full CS2 item catalog from ByMykel/CSGO-API.
///
/// Pulls skins, stickers, cases (crates), agents, patches, keychains,
/// collectibles, music kits, and graffiti — expands each skin into one
/// entry per (wear × StatTrak × Souvenir) so a substring match on
/// market_hash_name works for every tradeable variant.
///
/// The cache is versioned and persists across restarts. It refreshes
/// only when the user explicitly taps refresh or when the cache is
/// older than [_cacheMaxAge] (default 30 days — CS2 item catalog
/// rarely changes).
class Cs2DatabaseService {
  static const _base = 'https://raw.githubusercontent.com/ByMykel/CSGO-API/main/public/api/en';
  static const _cacheFile = 'cs2_database_cache.json';
  static const _cacheVersion = 1;
  static const _cacheMaxAge = Duration(days: 30);

  static const _endpoints = {
    'skins': '$_base/skins.json',
    'stickers': '$_base/stickers.json',
    'crates': '$_base/crates.json',
    'agents': '$_base/agents.json',
    'patches': '$_base/patches.json',
    'keychains': '$_base/keychains.json',
    'collectibles': '$_base/collectibles.json',
    'music_kits': '$_base/music_kits.json',
    'graffiti': '$_base/graffiti.json',
  };

  /// Loads the catalog. Uses cache if fresh, otherwise downloads.
  /// Pass [forceRefresh] to bypass the cache.
  Future<List<CS2Item>> loadCatalog({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _loadCache();
      if (cached != null) return cached;
    }
    final items = await _fetchAll();
    await _saveCache(items);
    return items;
  }

  Future<List<CS2Item>> _fetchAll() async {
    final all = <CS2Item>[];

    // Fetch all endpoints in parallel — they're independent.
    final results = await Future.wait(_endpoints.entries.map((e) async {
      final kind = e.key;
      final url = e.value;
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) {
          debugPrint('Catalog fetch failed for $kind: ${response.statusCode}');
          return <CS2Item>[];
        }
        final data = jsonDecode(response.body) as List<dynamic>;
        debugPrint('Catalog: $kind returned ${data.length} raw entries');
        return _parseEntries(kind, data);
      } catch (e) {
        debugPrint('Catalog fetch error for $kind: $e');
        return <CS2Item>[];
      }
    }));

    for (final list in results) {
      all.addAll(list);
    }

    debugPrint('Catalog loaded: ${all.length} total items');
    return all;
  }

  List<CS2Item> _parseEntries(String kind, List<dynamic> raw) {
    final items = <CS2Item>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        if (kind == 'skins') {
          items.addAll(_parseSkin(entry));
        } else {
          final item = _parseSimple(kind, entry);
          if (item != null) items.add(item);
        }
      } catch (e) {
        // Skip malformed entries — log the id if available
        debugPrint('Skipped $kind entry (${entry['id']}): $e');
      }
    }
    return items;
  }

  /// Parses a non-skin entry (sticker, case, agent, patch, etc.).
  /// Returns null if the item has no market_hash_name (not tradeable).
  CS2Item? _parseSimple(String kind, Map<String, dynamic> e) {
    final hash = e['market_hash_name'] as String?;
    if (hash == null || hash.isEmpty) return null;

    final name = e['name'] as String? ?? hash;
    final rarity = e['rarity'] as Map<String, dynamic>?;
    final rarityName = rarity?['name'] as String? ?? 'Consumer Grade';
    final rarityColor = rarity?['color'] as String? ?? '#b0c3d9';
    final image = e['image'] as String? ?? '';

    final collections = e['collections'] as List<dynamic>?;
    final collection = (collections != null && collections.isNotEmpty)
        ? ((collections.first as Map<String, dynamic>)['name'] as String?)
        : null;

    return CS2Item(
      id: e['id'] as String? ?? 'search-$kind-${_itemIdCounter++}',
      name: name,
      weaponType: _categoryLabel(kind),
      skinName: '',
      wear: null,
      rarity: rarityName,
      rarityColor: rarityColor,
      currentPrice: 0,
      quantity: 1,
      location: 'search',
      imageUrl: image,
      marketHashName: hash,
      collection: collection,
    );
  }

  /// Parses a skin entry and expands it into every wear × stattrak/souvenir
  /// variant. Each variant becomes a distinct CS2Item because its
  /// market_hash_name is distinct on Steam.
  List<CS2Item> _parseSkin(Map<String, dynamic> e) {
    final baseName = e['name'] as String?;
    if (baseName == null || baseName.isEmpty) return const [];

    final pattern = e['pattern'] as Map<String, dynamic>?;
    final skinName = pattern?['name'] as String? ?? '';
    final category = e['category'] as Map<String, dynamic>?;
    final weaponType = category?['name'] as String? ?? 'Other';

    final rarity = e['rarity'] as Map<String, dynamic>?;
    final rarityName = rarity?['name'] as String? ?? 'Consumer Grade';
    final rarityColor = rarity?['color'] as String? ?? '#b0c3d9';
    final image = e['image'] as String? ?? '';

    final collections = e['collections'] as List<dynamic>?;
    final collection = (collections != null && collections.isNotEmpty)
        ? ((collections.first as Map<String, dynamic>)['name'] as String?)
        : null;

    final wears = (e['wears'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map((w) => w['name'] as String?)
            .whereType<String>()
            .toList() ??
        const <String>[];

    final hasStatTrak = e['stattrak'] == true;
    final hasSouvenir = e['souvenir'] == true;

    final variants = <CS2Item>[];

    // Some items (knives, gloves, specific skins) have no wears listed —
    // still include them without a wear suffix so they're searchable.
    final wearList = wears.isEmpty ? [null] : wears.map((w) => w).toList();

    for (final wear in wearList) {
      // Normal variant
      variants.add(_skinVariant(
        baseName: baseName,
        skinName: skinName,
        weaponType: weaponType,
        wear: wear,
        rarityName: rarityName,
        rarityColor: rarityColor,
        image: image,
        collection: collection,
        prefix: '',
        isStatTrak: false,
        isSouvenir: false,
      ));
      if (hasStatTrak) {
        variants.add(_skinVariant(
          baseName: baseName,
          skinName: skinName,
          weaponType: weaponType,
          wear: wear,
          rarityName: rarityName,
          rarityColor: rarityColor,
          image: image,
          collection: collection,
          prefix: 'StatTrak™ ',
          isStatTrak: true,
          isSouvenir: false,
        ));
      }
      if (hasSouvenir) {
        variants.add(_skinVariant(
          baseName: baseName,
          skinName: skinName,
          weaponType: weaponType,
          wear: wear,
          rarityName: rarityName,
          rarityColor: rarityColor,
          image: image,
          collection: collection,
          prefix: 'Souvenir ',
          isStatTrak: false,
          isSouvenir: true,
        ));
      }
    }

    return variants;
  }

  CS2Item _skinVariant({
    required String baseName,
    required String skinName,
    required String weaponType,
    required String? wear,
    required String rarityName,
    required String rarityColor,
    required String image,
    required String? collection,
    required String prefix,
    required bool isStatTrak,
    required bool isSouvenir,
  }) {
    final wearSuffix = wear != null ? ' ($wear)' : '';
    final hash = '$prefix$baseName$wearSuffix';
    return CS2Item(
      id: 'search-${_itemIdCounter++}',
      name: '$prefix$baseName',
      weaponType: weaponType,
      skinName: skinName,
      wear: wear,
      rarity: rarityName,
      rarityColor: rarityColor,
      isStatTrak: isStatTrak,
      isSouvenir: isSouvenir,
      currentPrice: 0,
      quantity: 1,
      location: 'search',
      imageUrl: image,
      marketHashName: hash,
      collection: collection,
    );
  }

  /// Friendly label for the non-skin weaponType field.
  String _categoryLabel(String kind) {
    switch (kind) {
      case 'stickers': return 'Sticker';
      case 'crates': return 'Container';
      case 'agents': return 'Agent';
      case 'patches': return 'Patch';
      case 'keychains': return 'Charm';
      case 'collectibles': return 'Collectible';
      case 'music_kits': return 'Music Kit';
      case 'graffiti': return 'Graffiti';
      default: return 'Other';
    }
  }

  // Monotonic counter to generate unique ids for each parsed variant.
  static int _itemIdCounter = 0;

  // ── Cache ─────────────────────────────────────────────────────

  Future<List<CS2Item>?> _loadCache() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFile');
      if (!file.existsSync()) return null;

      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      final version = data['version'] as int? ?? 0;
      if (version != _cacheVersion) {
        debugPrint('Catalog cache version mismatch — will re-fetch');
        return null;
      }

      final ts = data['timestamp'] as int? ?? 0;
      final cacheTime = DateTime.fromMillisecondsSinceEpoch(ts);
      if (DateTime.now().difference(cacheTime) > _cacheMaxAge) {
        debugPrint('Catalog cache expired — will re-fetch');
        return null;
      }

      final itemsJson = data['items'] as List<dynamic>;
      final items = itemsJson
          .map((j) => CS2Item.fromJson(j as Map<String, dynamic>))
          .toList();
      debugPrint('Loaded ${items.length} catalog items from cache');
      return items;
    } catch (e) {
      debugPrint('Catalog cache load error: $e');
      return null;
    }
  }

  Future<void> _saveCache(List<CS2Item> items) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFile');
      final data = {
        'version': _cacheVersion,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'items': items.map((i) => i.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(data));
      debugPrint('Saved ${items.length} catalog items to cache');
    } catch (e) {
      debugPrint('Catalog cache save error: $e');
    }
  }
}
