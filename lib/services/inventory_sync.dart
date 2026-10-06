import 'dart:convert';

import '../models/cs2_item.dart';

abstract interface class InventorySyncStore {
  Future<Map<String, CS2Item>> load(String steamId);
  Future<void> writeBatch(
    String steamId,
    Map<String, CS2Item> updates,
    List<String> deletions,
  );
  Future<void> writeMetadata(String steamId, int itemCount);
}

/// Serializes snapshots so an older sync cannot finish after a newer one.
/// Only complete Steam fetches may remove missing documents.
class InventorySynchronizer {
  InventorySynchronizer(this.store);
  final InventorySyncStore store;
  Future<void> _pending = Future.value();

  Future<void> save(
    String steamId,
    List<CS2Item> items, {
    bool removeMissing = false,
  }) {
    final snapshot = {
      for (final item in items) item.id: CS2Item.fromJson(item.toJson()),
    };
    final task = _pending.then((_) => _save(steamId, snapshot, removeMissing));
    _pending = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> _save(
    String steamId,
    Map<String, CS2Item> items,
    bool removeMissing,
  ) async {
    final existing = await store.load(steamId);
    final updates = items.entries.where((entry) =>
        jsonEncode(existing[entry.key]?.toJson()) !=
        jsonEncode(entry.value.toJson())).toList();
    final deletions = removeMissing
        ? existing.keys.where((id) => !items.containsKey(id)).toList()
        : <String>[];

    // Abort on any failed batch. Retrying reloads the committed data and writes
    // only what is still missing. Never retry a previously committed WriteBatch.
    for (var offset = 0; offset < updates.length; offset += 50) {
      await store.writeBatch(
        steamId,
        Map.fromEntries(updates.skip(offset).take(50)),
        const [],
      );
    }
    for (var offset = 0; offset < deletions.length; offset += 50) {
      await store.writeBatch(steamId, const {}, deletions.skip(offset).take(50).toList());
    }
    final count = removeMissing ? items.length : {...existing.keys, ...items.keys}.length;
    await store.writeMetadata(steamId, count);
  }
}
