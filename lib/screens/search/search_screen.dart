import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/cs2_item.dart';
import '../../providers/cs2_database_provider.dart';
import '../../theme/app_theme.dart';

/// Holds the current search query for the Search tab.
final searchCatalogQueryProvider =
    NotifierProvider<SearchCatalogQueryNotifier, String>(
  SearchCatalogQueryNotifier.new,
);

class SearchCatalogQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  void set(String value) => state = value;
}

/// Max number of rows to render at once — prevents the ListView
/// from trying to build 30k+ widgets when the query is empty or very
/// short. Substring filter is cheap but widget creation is not.
const _maxResults = 200;

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(searchCatalogQueryProvider),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(cs2DatabaseProvider);
    final query = ref.watch(searchCatalogQueryProvider).trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh catalog',
            onPressed: catalogAsync.isLoading
                ? null
                : () => ref.read(cs2DatabaseProvider.notifier).refresh(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _controller,
              autofocus: false,
              onChanged: (v) =>
                  ref.read(searchCatalogQueryProvider.notifier).set(v),
              decoration: InputDecoration(
                hintText: 'Search any CS2 item...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _controller.clear();
                          ref.read(searchCatalogQueryProvider.notifier).set('');
                        },
                      )
                    : null,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: catalogAsync.when(
              loading: () => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Downloading CS2 item catalog...'),
                    SizedBox(height: 4),
                    Text(
                      'First load only — cached afterwards',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                      const SizedBox(height: 12),
                      Text(
                        'Could not load catalog: $e',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                        onPressed: () =>
                            ref.read(cs2DatabaseProvider.notifier).refresh(),
                      ),
                    ],
                  ),
                ),
              ),
              data: (items) => _ResultList(items: items, query: query),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultList extends StatelessWidget {
  final List<CS2Item> items;
  final String query;

  const _ResultList({required this.items, required this.query});

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: Colors.grey[600]),
            const SizedBox(height: 8),
            Text(
              '${items.length} items indexed',
              style: TextStyle(color: Colors.grey[500]),
            ),
            const SizedBox(height: 4),
            Text(
              'Type to filter — e.g. "redline" or "dragon lore factory new"',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // Split on whitespace so order-independent queries work:
    // "redline factory new" matches "AK-47 | Redline (Factory New)".
    final tokens = query.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    final matches = <CS2Item>[];
    for (final item in items) {
      final hay = item.marketHashName.toLowerCase();
      if (tokens.every(hay.contains)) {
        matches.add(item);
        if (matches.length >= _maxResults) break;
      }
    }

    if (matches.isEmpty) {
      return const Center(
        child: Text(
          'No items match your search',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: matches.length,
      cacheExtent: 500,
      itemBuilder: (context, i) => _SearchResultCard(
        item: matches[i],
        onTap: () => context.push('/search/item', extra: matches[i]),
      ),
    );
  }
}

/// Slim card for search results — no price column since catalog items
/// have no price until tapped.
class _SearchResultCard extends StatelessWidget {
  final CS2Item item;
  final VoidCallback onTap;

  const _SearchResultCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final rarityColor = CS2Colors.fromRarity(item.rarity);
    return RepaintBoundary(
      child: Card(
        clipBehavior: Clip.hardEdge,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: rarityColor, width: 3)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 48,
                    child: Image.network(
                      item.imageUrl,
                      fit: BoxFit.contain,
                      cacheWidth: 128,
                      cacheHeight: 96,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.broken_image,
                        color: Colors.white24,
                        size: 20,
                      ),
                      loadingBuilder: (context, child, progress) =>
                          progress == null ? child : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.marketHashName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            item.weaponType,
                            item.rarity,
                          ].join(' • '),
                          style: TextStyle(color: Colors.grey[400], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
