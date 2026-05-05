import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/cs2_item.dart';
import '../../providers/auth_provider.dart';
import '../../providers/inventory_provider.dart';
import '../../providers/price_history_provider.dart';
import '../../providers/price_provider.dart';
import '../../providers/storage_provider.dart';
import '../../services/firestore_service.dart';
import '../../widgets/item_card.dart';
import '../../widgets/portfolio_summary_v2.dart';
import '../auth/steam_login_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-refresh prices on app open if last fetch was >24h ago
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(priceFetchProvider.notifier).autoRefreshIfStale();
    });
  }

  Future<void> _openSteamLogin(BuildContext context, WidgetRef ref) async {
    final result = await Navigator.of(context).push<SteamLoginResult>(
      MaterialPageRoute(builder: (_) => const SteamLoginScreen()),
    );

    if (result == null) return;

    if (result.steamId.isNotEmpty) {
      ref.read(steamIdProvider.notifier).set(result.steamId);
      // Sign in to Firebase so Firestore writes are authenticated
      ref.read(authProvider.notifier).signInWithSteamId(result.steamId);
    }

    if (result.steamLoginCookie != null &&
        result.steamLoginCookie!.isNotEmpty) {
      ref.read(steamLoginCookieProvider.notifier).set(result.steamLoginCookie!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inventoryAsync = ref.watch(inventoryProvider);
    final steamId = ref.watch(steamIdProvider);

    if (steamId.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            'CS2 Portfolio',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onPressed: () => context.push('/settings'),
            ),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_search, size: 64, color: Colors.grey[600]),
                const SizedBox(height: 16),
                const Text(
                  'Sign in to get started',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Log in with your Steam account to load your inventory',
                  style: TextStyle(color: Colors.grey[400]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => _openSteamLogin(context, ref),
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in with Steam'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => context.push('/settings'),
                  child: const Text('Or enter Steam ID manually'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final fetchProgress = ref.watch(inventoryFetchProgressProvider);

    return inventoryAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(
          title: const Text(
            'CS2 Portfolio',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onPressed: () => context.push('/settings'),
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                fetchProgress.itemsFetched > 0
                    ? 'Fetching inventory... ${fetchProgress.itemsFetched} items'
                    : 'Fetching inventory from Steam...',
                style: const TextStyle(fontSize: 16),
              ),
              if (fetchProgress.itemsFetched > 0) ...[
                const SizedBox(height: 8),
                Builder(builder: (_) {
                  final total = fetchProgress.totalPages;
                  return Text(
                    total != null
                        ? 'Page ${fetchProgress.pagesFetched}/$total (~75 items per page)'
                        : 'Page ${fetchProgress.pagesFetched} (~75 items per page)',
                    style: TextStyle(color: Colors.grey[400], fontSize: 13),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(
          title: const Text(
            'CS2 Portfolio',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
              onPressed: () => context.push('/settings'),
            ),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 64, color: Colors.redAccent[100]),
                const SizedBox(height: 16),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => ref.read(inventoryProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (items) => _buildDashboard(context, ref, items),
    );
  }

  Widget _buildDashboard(BuildContext context, WidgetRef ref, List<CS2Item> items) {
    final totalSteam = ref.watch(portfolioValueProvider);
    final totalCsfloat = ref.watch(csfloatPortfolioValueProvider);
    final totalItems = ref.watch(totalItemCountProvider);
    final invSteam = ref.watch(inventorySteamValueProvider);
    final invCsfloat = ref.watch(inventoryCsfloatValueProvider);
    final invCount = ref.watch(inventoryItemCountProvider);
    final storageUnits = ref.watch(storageUnitsProvider);
    final topGainers = ref.watch(topGainersProvider);
    final topLosers = ref.watch(topLosersProvider);
    final priceFetch = ref.watch(priceFetchProvider);
    final csfloatFetch = ref.watch(csfloatFetchProvider);
    final steamFetching = ref.watch(steamFetchInProgressProvider);
    final csfloatFetching = ref.watch(csfloatFetchInProgressProvider);
    final storage = ref.watch(storageProvider);

    final sources = <PortfolioSource>[
      PortfolioSource(
        label: 'Inventory',
        icon: Icons.inventory_2_outlined,
        steamValue: invSteam,
        csfloatValue: invCsfloat,
        itemCount: invCount,
      ),
      ...storageUnits.map((unit) {
        final unitSteam = unit.items.fold(
            0.0, (sum, i) => sum + (i.currentPrice * i.quantity));
        final unitCsfloat = unit.items.fold(0.0, (sum, i) {
          final price = i.csfloatPrice ?? i.currentPrice;
          return sum + (price * i.quantity);
        });
        // Fall back to the unit's GC-reported itemCount when contents
        // haven't been fetched yet (items list is empty until a
        // /storage/:id roundtrip), so the home total reflects reality.
        final unitCount = unit.items.isNotEmpty
            ? unit.items.fold<int>(0, (sum, i) => sum + i.quantity)
            : unit.itemCount;
        return PortfolioSource(
          label: unit.name,
          icon: Icons.storage_outlined,
          steamValue: unitSteam,
          csfloatValue: unitCsfloat,
          itemCount: unitCount,
        );
      }),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'CS2 Portfolio',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PortfolioSummaryV2(
            totalSteamValue: totalSteam,
            totalCsfloatValue: totalCsfloat,
            totalItems: totalItems,
            sources: sources,
          ),
          const SizedBox(height: 8),
          const _SyncStatusRow(),
          const SizedBox(height: 12),

          // Price fetch cards — Steam Market + CSFloat. Each card's
          // unified progress = inventory fetch + all storage units.
          _PriceFetchCard(
            priceFetch: priceFetch,
            itemCount: items.length,
            label: 'Steam Market',
            icon: Icons.attach_money,
            disabled: steamFetching,
            extraFetched: storage.steamBatchFetched,
            extraTotal: storage.steamBatchTotal,
            onFetch: () => ref.read(priceFetchProvider.notifier).fetchPrices(),
            onCancel: () {
              ref.read(priceFetchProvider.notifier).cancel();
              // Also break the storage tail (each unit's stream loop
              // checks the cancel flag at the next yield).
              ref.read(storageProvider.notifier).cancelAllPrices();
            },
          ),
          const SizedBox(height: 8),
          _PriceFetchCard(
            priceFetch: csfloatFetch,
            itemCount: items.length,
            label: 'CSFloat',
            icon: Icons.storefront,
            iconColor: Colors.blueAccent,
            disabled: csfloatFetching,
            extraFetched: storage.csfloatBatchFetched,
            extraTotal: storage.csfloatBatchTotal,
            onFetch: () => ref.read(csfloatFetchProvider.notifier).fetchPrices(),
            onCancel: () {
              ref.read(csfloatFetchProvider.notifier).cancel();
              ref.read(storageProvider.notifier).cancelAllPrices();
            },
          ),
          const SizedBox(height: 4),
          const _LastUpdatedLabel(),
          const SizedBox(height: 20),

          if (topGainers.isNotEmpty) ...[
            _SectionHeader(
              title: 'Top Gainers (24h)',
              icon: Icons.trending_up,
              iconColor: Colors.greenAccent,
            ),
            const SizedBox(height: 8),
            ...topGainers.map(
              (item) => ItemCard(
                item: item,
                onTap: () => context.go('/inventory/${item.id}'),
              ),
            ),
            const SizedBox(height: 24),
          ],

          if (topLosers.isNotEmpty) ...[
            _SectionHeader(
              title: 'Top Losers (24h)',
              icon: Icons.trending_down,
              iconColor: Colors.redAccent,
            ),
            const SizedBox(height: 8),
            ...topLosers.map(
              (item) => ItemCard(
                item: item,
                onTap: () => context.go('/inventory/${item.id}'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PriceFetchCard extends StatelessWidget {
  final PriceFetchState priceFetch;
  final int itemCount;
  final String label;
  final IconData icon;
  final Color? iconColor;
  final bool disabled;
  final int extraFetched;
  final int extraTotal;
  final VoidCallback onFetch;
  final VoidCallback onCancel;

  const _PriceFetchCard({
    required this.priceFetch,
    required this.itemCount,
    required this.label,
    required this.icon,
    this.iconColor,
    required this.disabled,
    required this.extraFetched,
    required this.extraTotal,
    required this.onFetch,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final unifiedFetched = priceFetch.fetched + extraFetched;
    final unifiedTotal = priceFetch.total + extraTotal;
    final unifiedPercent =
        unifiedTotal > 0 ? unifiedFetched / unifiedTotal : 0.0;
    final inventoryFetching = priceFetch.isFetching;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (disabled) ...[
              // Single unified progress bar covering inventory + all
              // loaded storage units. Stays busy until both layers are
              // actually finished, so the home total can't tick up
              // mysteriously after the card says "Updated".
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$label: $unifiedFetched/$unifiedTotal',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: unifiedPercent,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                inventoryFetching
                    ? priceFetch.currentItem
                    : 'Refreshing storage units...',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ] else if (priceFetch.isDone) ...[
              Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.greenAccent[400], size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$label: ${priceFetch.fetched} items priced',
                      style: TextStyle(color: Colors.greenAccent[100], fontSize: 13),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: disabled ? null : onFetch,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Icon(icon, color: iconColor ?? Colors.grey[500]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Fetch $label Prices',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '$itemCount items ~ ${(itemCount * 1.5 / 60).ceil()} min',
                          style: TextStyle(color: Colors.grey[500], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: disabled ? null : onFetch,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Fetch'),
                  ),
                ],
              ),
              if (priceFetch.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  priceFetch.error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SyncStatusRow extends ConsumerWidget {
  const _SyncStatusRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(firestoreSyncProvider);
    final auth = ref.watch(authProvider);

    final IconData icon;
    final Color color;
    final String text;

    if (!auth.isLoggedIn) {
      icon = Icons.cloud_off;
      color = Colors.grey;
      text = 'Cloud sync off — sign in with Steam';
    } else {
      switch (sync.status) {
        case SyncStatus.idle:
          icon = Icons.cloud_done;
          color = Colors.grey;
          text = 'Cloud sync ready';
        case SyncStatus.syncing:
          icon = Icons.cloud_upload;
          color = Colors.blueAccent;
          text = 'Syncing ${sync.message ?? ''}...';
        case SyncStatus.success:
          icon = Icons.cloud_done;
          color = Colors.greenAccent[400]!;
          text = sync.message ?? 'Synced';
        case SyncStatus.error:
          icon = Icons.cloud_off;
          color = Colors.redAccent;
          text = sync.message ?? 'Sync failed';
      }
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;

  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: iconColor),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _LastUpdatedLabel extends ConsumerStatefulWidget {
  const _LastUpdatedLabel();

  @override
  ConsumerState<_LastUpdatedLabel> createState() => _LastUpdatedLabelState();
}

class _LastUpdatedLabelState extends ConsumerState<_LastUpdatedLabel> {
  String _label = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/last_price_fetch.txt');
      if (!file.existsSync()) return;
      final ts = int.tryParse(await file.readAsString());
      if (ts == null) return;

      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      final dtDay = DateTime(dt.year, dt.month, dt.day);

      final hour = dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      final ampm = hour >= 12 ? 'PM' : 'AM';
      final h = hour % 12 == 0 ? 12 : hour % 12;
      final timeStr = '$h:$minute $ampm';

      final String text;
      if (dtDay == today) {
        text = 'Prices updated today at $timeStr';
      } else if (dtDay == yesterday) {
        text = 'Prices updated yesterday at $timeStr';
      } else {
        final months = ['Jan','Feb','Mar','Apr','May','Jun',
                        'Jul','Aug','Sep','Oct','Nov','Dec'];
        text = 'Prices updated ${months[dt.month - 1]} ${dt.day} at $timeStr';
      }
      if (mounted) setState(() => _label = text);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(priceFetchProvider, (prev, next) {
      if (next.isDone && prev?.isDone != true) _load();
    });
    ref.listen(csfloatFetchProvider, (prev, next) {
      if (next.isDone && prev?.isDone != true) _load();
    });

    if (_label.isEmpty) return const SizedBox.shrink();
    return Text(
      _label,
      style: TextStyle(color: Colors.grey[600], fontSize: 11),
    );
  }
}
