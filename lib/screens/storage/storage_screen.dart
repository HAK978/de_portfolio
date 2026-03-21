import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../models/storage_unit.dart';
import '../../providers/storage_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/item_card.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  final _urlController = TextEditingController();
  bool _showUrlInput = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = ref.read(storageServiceUrlProvider);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(storageProvider);
    final serviceUrl = ref.watch(storageServiceUrlProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Storage Units',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          // Settings button to change service URL
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Service URL',
            onPressed: () {
              setState(() => _showUrlInput = !_showUrlInput);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // URL input (collapsible)
          if (_showUrlInput)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      decoration: InputDecoration(
                        labelText: 'Service URL',
                        hintText: 'http://192.168.1.100:3456',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      ref.read(storageServiceUrlProvider.notifier).set(
                            _urlController.text.trim(),
                          );
                      setState(() => _showUrlInput = false);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),

          // Connection + fetch controls
          _ConnectionBar(
            serviceUrl: serviceUrl,
            isLoading: storage.isLoading,
            hasUnits: storage.units.isNotEmpty,
            onConnect: () {
              ref.invalidate(storageStatusProvider);
              ref.read(storageProvider.notifier).fetchCaskets();
            },
          ),

          // Error message
          if (storage.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                storage.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ),

          // Storage unit list
          Expanded(
            child: storage.units.isEmpty && !storage.isLoading
                ? const Center(
                    child: Text(
                      'Tap Connect to fetch storage units\nfrom the local service',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: storage.units.length,
                    itemBuilder: (context, index) {
                      final unit = storage.units[index];
                      final isLoading =
                          storage.loadingCaskets.contains(unit.id);
                      final pricingProgress =
                          storage.pricingProgress[unit.id];
                      return _StorageUnitCard(
                        unit: unit,
                        isLoading: isLoading,
                        pricingProgress: pricingProgress,
                        onExpand: () {
                          // Lazy-load contents on first expand
                          if (unit.items.isEmpty) {
                            ref
                                .read(storageProvider.notifier)
                                .fetchContents(unit.id);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shows connection status and a connect/refresh button.
class _ConnectionBar extends ConsumerWidget {
  final String serviceUrl;
  final bool isLoading;
  final bool hasUnits;
  final VoidCallback onConnect;

  const _ConnectionBar({
    required this.serviceUrl,
    required this.isLoading,
    required this.hasUnits,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(storageStatusProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Status indicator
          statusAsync.when(
            data: (status) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  status.isReady ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: status.isReady
                      ? Colors.green
                      : status.reachable
                          ? Colors.orange
                          : Colors.red,
                ),
                const SizedBox(width: 8),
                Text(
                  status.isReady
                      ? 'GC Connected'
                      : status.reachable
                          ? 'Service up, GC disconnected'
                          : 'Service unreachable',
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            loading: () => const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            error: (_, _) => const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 12, color: Colors.red),
                SizedBox(width: 8),
                Text('Error', style: TextStyle(color: Colors.red, fontSize: 13)),
              ],
            ),
          ),

          const Spacer(),

          // Connect / Refresh button
          FilledButton.icon(
            onPressed: isLoading ? null : onConnect,
            icon: isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(hasUnits ? Icons.refresh : Icons.power_settings_new),
            label: Text(hasUnits ? 'Refresh' : 'Connect'),
          ),
        ],
      ),
    );
  }
}

/// An expandable card for a storage unit.
/// Lazy-loads contents when expanded for the first time.
class _StorageUnitCard extends StatelessWidget {
  final StorageUnit unit;
  final bool isLoading;
  final PricingProgress? pricingProgress;
  final VoidCallback onExpand;

  const _StorageUnitCard({
    required this.unit,
    required this.isLoading,
    this.pricingProgress,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat.currency(symbol: '\$');

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: const Icon(Icons.storage, color: CS2Colors.milSpec),
        title: Text(
          unit.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${unit.itemCount} items'
          '${unit.totalValue > 0 ? ' \u2022 ${currencyFormat.format(unit.totalValue)}' : ''}',
          style: TextStyle(color: Colors.grey[400], fontSize: 13),
        ),
        onExpansionChanged: (expanded) {
          if (expanded) onExpand();
        },
        children: [
          if (isLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (unit.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Expand to load contents',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            )
          else ...[
            // Pricing progress bar
            if (pricingProgress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fetching prices: ${pricingProgress!.fetched}/${pricingProgress!.total}',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pricingProgress!.percent,
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                '${unit.items.length} unique items',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ),
            // Show items in a constrained list to avoid building all at once
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 500),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: unit.items.length,
                itemBuilder: (context, index) {
                  return ItemCard(item: unit.items[index]);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
