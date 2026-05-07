import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/cs2_item.dart';

/// A single possible drop inside a container (case / capsule / package).
/// Slimmed-down shape — just what we need to render the preview row.
/// Market hash name is nullable because some ByMykel entries (rare
/// items like knife vanillas) don't have one.
class CaseDrop {
  final String name;
  final String? marketHashName;
  final String imageUrl;
  final String rarity;
  final String rarityColor;

  const CaseDrop({
    required this.name,
    required this.marketHashName,
    required this.imageUrl,
    required this.rarity,
    required this.rarityColor,
  });

  factory CaseDrop.fromByMykel(Map<String, dynamic> j) {
    final rarity = j['rarity'] as Map<String, dynamic>?;
    return CaseDrop(
      name: j['name'] as String? ?? '',
      marketHashName: j['market_hash_name'] as String?,
      imageUrl: j['image'] as String? ?? '',
      rarity: rarity?['name'] as String? ?? 'Consumer Grade',
      rarityColor: rarity?['color'] as String? ?? '#b0c3d9',
    );
  }

  factory CaseDrop.fromJson(Map<String, dynamic> j) => CaseDrop(
        name: j['name'] as String,
        marketHashName: j['marketHashName'] as String?,
        imageUrl: j['imageUrl'] as String,
        rarity: j['rarity'] as String,
        rarityColor: j['rarityColor'] as String,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'marketHashName': marketHashName,
        'imageUrl': imageUrl,
        'rarity': rarity,
        'rarityColor': rarityColor,
      };
}

/// Drops for one container (case, capsule, package, etc.). `contains`
/// is the common pool; `containsRare` holds the special tier (knives,
/// gloves, or "gold" stickers) that unbox at ~0.26% rate.
class CaseContents {
  final List<CaseDrop> contains;
  final List<CaseDrop> containsRare;

  const CaseContents({
    this.contains = const [],
    this.containsRare = const [],
  });

  bool get isEmpty => contains.isEmpty && containsRare.isEmpty;

  Map<String, dynamic> toJson() => {
        'contains': contains.map((d) => d.toJson()).toList(),
        'containsRare': containsRare.map((d) => d.toJson()).toList(),
      };

  factory CaseContents.fromJson(Map<String, dynamic> j) {
    List<CaseDrop> list(String key) => (j[key] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CaseDrop.fromJson)
        .toList();
    return CaseContents(
      contains: list('contains'),
      containsRare: list('containsRare'),
    );
  }
}

/// Bundle returned by [Cs2DatabaseService.loadCatalog].
class Cs2Catalog {
  final List<CS2Item> items;
  final Map<String, CaseContents> caseContents;

  const Cs2Catalog({
    required this.items,
    this.caseContents = const {},
  });
}

/// Fetches and caches the full CS2 item catalog from ByMykel/CSGO-API.
///
/// Pulls skins, stickers, cases (crates), agents, patches, keychains,
/// collectibles, music kits, and graffiti — expands each skin into one
/// entry per (wear × StatTrak × Souvenir) so a substring match on
/// market_hash_name works for every tradeable variant. Also extracts
/// each container's `contains` + `contains_rare` list so the detail
/// screen can show "this case drops …".
///
/// The cache is versioned and persists across restarts. It refreshes
/// only when the user explicitly taps refresh or when the cache is
/// older than [_cacheMaxAge] (default 30 days — CS2 item catalog
/// rarely changes).
class Cs2DatabaseService {
  static const _base = 'https://raw.githubusercontent.com/ByMykel/CSGO-API/main/public/api/en';
  static const _cacheFile = 'cs2_database_cache.json';
  static const _cacheVersion = 2;
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
  Future<Cs2Catalog> loadCatalog({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _loadCache();
      if (cached != null) return cached;
    }
    final catalog = await _fetchAll();
    await _saveCache(catalog);
    return catalog;
  }

  Future<Cs2Catalog> _fetchAll() async {
    final all = <CS2Item>[];
    final caseMap = <String, CaseContents>{};

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
        if (kind == 'crates') {
          // Side-effect: extract contents into caseMap while we iterate.
          for (final entry in data) {
            if (entry is! Map<String, dynamic>) continue;
            final hash = entry['market_hash_name'] as String?;
            if (hash == null || hash.isEmpty) continue;
            final contents = CaseContents(
              contains: (entry['contains'] as List<dynamic>? ?? [])
                  .whereType<Map<String, dynamic>>()
                  .map(CaseDrop.fromByMykel)
                  .toList(),
              containsRare: (entry['contains_rare'] as List<dynamic>? ?? [])
                  .whereType<Map<String, dynamic>>()
                  .map(CaseDrop.fromByMykel)
                  .toList(),
            );
            if (!contents.isEmpty) caseMap[hash] = contents;
          }
        }
        return _parseEntries(kind, data);
      } catch (e) {
        debugPrint('Catalog fetch error for $kind: $e');
        return <CS2Item>[];
      }
    }));

    for (final list in results) {
      all.addAll(list);
    }

    debugPrint('Catalog loaded: ${all.length} items, ${caseMap.length} cases with drops');
    return Cs2Catalog(items: all, caseContents: caseMap);
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

  Future<Cs2Catalog?> _loadCache() async {
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

      final contentsJson =
          data['caseContents'] as Map<String, dynamic>? ?? const {};
      final caseContents = <String, CaseContents>{
        for (final entry in contentsJson.entries)
          entry.key:
              CaseContents.fromJson(entry.value as Map<String, dynamic>),
      };

      debugPrint(
          'Loaded ${items.length} catalog items + ${caseContents.length} cases from cache');
      return Cs2Catalog(items: items, caseContents: caseContents);
    } catch (e) {
      debugPrint('Catalog cache load error: $e');
      return null;
    }
  }

  Future<void> _saveCache(Cs2Catalog catalog) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_cacheFile');
      final data = {
        'version': _cacheVersion,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'items': catalog.items.map((i) => i.toJson()).toList(),
        'caseContents': {
          for (final e in catalog.caseContents.entries) e.key: e.value.toJson(),
        },
      };
      await file.writeAsString(jsonEncode(data));
      debugPrint('Saved ${catalog.items.length} catalog items + '
          '${catalog.caseContents.length} cases to cache');
    } catch (e) {
      debugPrint('Catalog cache save error: $e');
    }
  }
}
