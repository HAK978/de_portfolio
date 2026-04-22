import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Persists the most recently opened items from the Search tab so the
/// user can jump back to them without re-typing. Stored as a plain
/// list of market_hash_name strings — the search catalog resolves
/// them back to CS2Item when rendering.
final searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<String>>(
  SearchHistoryNotifier.new,
);

class SearchHistoryNotifier extends Notifier<List<String>> {
  static const _fileName = 'search_history.json';
  static const _maxEntries = 20;

  @override
  List<String> build() {
    ref.keepAlive();
    _load();
    return const [];
  }

  /// Push an item to the front of the history. Dedupes and caps.
  void record(String marketHashName) {
    final name = marketHashName.trim();
    if (name.isEmpty) return;
    final updated = [name, ...state.where((h) => h != name)];
    if (updated.length > _maxEntries) {
      state = updated.sublist(0, _maxEntries);
    } else {
      state = updated;
    }
    _save();
  }

  void remove(String marketHashName) {
    state = state.where((h) => h != marketHashName).toList();
    _save();
  }

  void clear() {
    state = const [];
    _save();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final history = (data['history'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      state = history;
    } catch (e) {
      debugPrint('Error loading search history: $e');
    }
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode({'history': state}));
    } catch (e) {
      debugPrint('Error saving search history: $e');
    }
  }
}
