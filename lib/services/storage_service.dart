import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/cs2_item.dart';

/// Talks to the local Node.js storage service that connects to
/// Steam's Game Coordinator to fetch storage unit contents.
///
/// The service runs at localhost:3456 on the same machine.
/// For mobile, the phone must be on the same network and use
/// the PC's local IP instead of localhost.
class StorageService {
  final String baseUrl;
  final String? apiKey;

  StorageService({required this.baseUrl, this.apiKey});

  Map<String, String> get _headers => {
    if (apiKey != null && apiKey!.isNotEmpty) 'X-Api-Key': apiKey!,
  };

  /// Check if the service is running and connected to GC.
  Future<StorageStatus> getStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/status'), headers: _headers)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        return const StorageStatus(reachable: false);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return StorageStatus(
        reachable: true,
        steamConnected: data['steam'] as bool? ?? false,
        gcConnected: data['gc'] as bool? ?? false,
        displayName: data['displayName'] as String? ?? '',
      );
    } catch (e) {
      debugPrint('StorageService: status check failed — $e');
      return const StorageStatus(reachable: false);
    }
  }

  /// Fetch the list of storage units (caskets) from inventory.
  Future<List<CasketInfo>> getCaskets() async {
    final response = await http
        .get(Uri.parse('$baseUrl/caskets'), headers: _headers)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch caskets (${response.statusCode})');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final caskets = data['caskets'] as List<dynamic>;

    return caskets.map((c) {
      final map = c as Map<String, dynamic>;
      return CasketInfo(
        casketId: map['casketId'] as String,
        name: map['name'] as String? ?? 'Storage Unit',
        itemCount: map['itemCount'] as int? ?? 0,
      );
    }).toList();
  }

  /// Fetch the contents of a specific storage unit.
  /// Returns resolved items with names, images, rarity, etc.
  Future<List<CS2Item>> getCasketContents(String casketId) async {
    final response = await http
        .get(Uri.parse('$baseUrl/storage/$casketId'), headers: _headers)
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch casket contents (${response.statusCode})');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>;

    return items.map((item) {
      final map = item as Map<String, dynamic>;
      return _parseStorageItem(map);
    }).toList();
  }

  /// Converts a storage item from the Node.js service into a CS2Item.
  CS2Item _parseStorageItem(Map<String, dynamic> map) {
    return CS2Item(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? 'Unknown',
      weaponType: _extractWeaponType(map['name'] as String? ?? ''),
      skinName: _extractSkinName(map['name'] as String? ?? ''),
      wear: map['wear'] as String?,
      rarity: map['rarity'] as String? ?? 'Consumer Grade',
      rarityColor: map['rarityColor'] as String? ?? '#b0c3d9',
      isStatTrak: map['isStatTrak'] as bool? ?? false,
      isSouvenir: map['isSouvenir'] as bool? ?? false,
      currentPrice: 0,
      quantity: 1,
      location: 'storage',
      imageUrl: map['imageUrl'] as String? ?? '',
      marketHashName: map['marketHashName'] as String? ?? map['name'] as String? ?? '',
      collection: map['collection'] as String?,
      floatValue: (map['paintWear'] as num?)?.toDouble(),
    );
  }

  String _extractWeaponType(String name) {
    final pipeIdx = name.indexOf(' | ');
    if (pipeIdx > 0) {
      var prefix = name.substring(0, pipeIdx);
      // Strip ★ and StatTrak™ prefixes
      prefix = prefix.replaceAll('★ ', '').replaceAll('StatTrak™ ', '');
      return prefix;
    }
    if (name.startsWith('Sticker')) return 'Sticker';
    if (name.startsWith('Music Kit')) return 'Music Kit';
    if (name.contains('Case')) return 'Container';
    return 'Other';
  }

  String _extractSkinName(String name) {
    final pipeIdx = name.indexOf(' | ');
    if (pipeIdx > 0) return name.substring(pipeIdx + 3);
    return '';
  }
}

/// Connection status of the storage service.
class StorageStatus {
  final bool reachable;
  final bool steamConnected;
  final bool gcConnected;
  final String displayName;

  const StorageStatus({
    required this.reachable,
    this.steamConnected = false,
    this.gcConnected = false,
    this.displayName = '',
  });

  bool get isReady => reachable && steamConnected && gcConnected;
}

/// Metadata about a storage unit before fetching its contents.
class CasketInfo {
  final String casketId;
  final String name;
  final int itemCount;

  const CasketInfo({
    required this.casketId,
    required this.name,
    required this.itemCount,
  });
}
