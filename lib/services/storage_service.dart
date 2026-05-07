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

  /// Pull the VM's `error` field out of a non-200 response body so the
  /// UI can show "Real Steam client is playing CS2" instead of an
  /// opaque "(503)". Falls back to the status code if the body isn't
  /// JSON or doesn't carry an `error` key.
  Exception _errorFromResponse(http.Response response, String label) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final msg = body['error'];
        if (msg is String && msg.isNotEmpty) {
          return Exception(msg);
        }
      }
    } catch (_) {}
    return Exception('$label (${response.statusCode})');
  }

  /// Check if the service is running and connected to GC.
  Future<StorageStatus> getStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/status'), headers: _headers)
          .timeout(const Duration(seconds: 5));

      // Distinguish "wrong API key" from "no service at all" so the
      // ConnectionBar can prompt the user to fix the key instead of
      // troubleshooting an unreachable VM.
      if (response.statusCode == 401) {
        return const StorageStatus(
          reachable: true,
          unauthorized: true,
        );
      }

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
    // 30s allows for the VM's cold GC-connect path: gamesPlayed([730])
    // → waitForGC (up to ~15s) → waitForInventory (up to ~10s).
    final response = await http
        .get(Uri.parse('$baseUrl/caskets'), headers: _headers)
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw _errorFromResponse(response, 'Failed to fetch caskets');
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
      throw _errorFromResponse(response, 'Failed to fetch casket contents');
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

  /// Fetch float values for inventory items from the GC.
  /// Returns a map of marketHashName → list of float data.
  Future<Map<String, List<FloatData>>> getInventoryFloats() async {
    final response = await http
        .get(Uri.parse('$baseUrl/inventory/floats'), headers: _headers)
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw _errorFromResponse(response, 'Failed to fetch inventory floats');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final floatsMap = data['floats'] as Map<String, dynamic>;

    final result = <String, List<FloatData>>{};
    for (final entry in floatsMap.entries) {
      final items = (entry.value as List<dynamic>).map((e) {
        final map = e as Map<String, dynamic>;
        return FloatData(
          assetId: map['assetId'] as String? ?? '',
          floatValue: (map['floatValue'] as num).toDouble(),
          paintSeed: map['paintSeed'] as int?,
          paintIndex: map['paintIndex'] as int?,
        );
      }).toList();
      result[entry.key] = items;
    }
    return result;
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
  /// True when the VM responded with 401 (wrong/missing API key). Lets
  /// the UI show a distinct message instead of generic "unreachable".
  final bool unauthorized;

  const StorageStatus({
    required this.reachable,
    this.steamConnected = false,
    this.gcConnected = false,
    this.displayName = '',
    this.unauthorized = false,
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

/// Float data for a single item instance from the GC.
class FloatData {
  final String assetId;
  final double floatValue;
  final int? paintSeed;
  final int? paintIndex;

  const FloatData({
    required this.assetId,
    required this.floatValue,
    this.paintSeed,
    this.paintIndex,
  });
}
