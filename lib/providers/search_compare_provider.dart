import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Items the user has explicitly pinned for cross-search comparison.
/// Persists across restarts so a list assembled over a long browse
/// session isn't lost. Stored as a flat list of market_hash_names —
/// the catalog provider resolves them to CS2Item when rendering.
final searchCompareProvider =
    NotifierProvider<SearchCompareNotifier, List<String>>(
  SearchCompareNotifier.new,
);

class SearchCompareNotifier extends Notifier<List<String>> {
  static const _fileName = 'search_compare_list.json';

  @override
  List<String> build() {
    ref.keepAlive();
    _load();
    return const [];
  }

  bool contains(String marketHashName) => state.contains(marketHashName);

  /// Toggle: add if missing, remove if present. Returns the new state.
  void toggle(String marketHashName) {
    final name = marketHashName.trim();
    if (name.isEmpty) return;
    if (state.contains(name)) {
      state = state.where((h) => h != name).toList();
    } else {
      state = [...state, name];
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
      final list = (data['items'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      state = list;
    } catch (e) {
      debugPrint('Error loading compare list: $e');
    }
  }

  Future<void> _save() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(jsonEncode({'items': state}));
    } catch (e) {
      debugPrint('Error saving compare list: $e');
    }
  }
}
