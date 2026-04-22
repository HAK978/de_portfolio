import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'models/cs2_item.dart';
import 'screens/home/home_screen.dart';
import 'screens/inventory/inventory_screen.dart';
import 'screens/inventory/item_detail_screen.dart';
import 'screens/search/search_screen.dart';
import 'screens/storage/storage_screen.dart';
import 'screens/settings/settings_screen.dart';

/// Root shell with bottom navigation.
///
/// GoRouter's ShellRoute lets us keep the bottom nav bar persistent
/// across screens while swapping the body content. This is the
/// standard pattern for tab-based Flutter apps.
class AppShell extends StatelessWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _calculateSelectedIndex(context),
        onDestinationSelected: (index) => _onItemTapped(index, context),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.inventory_2), label: 'Inventory'),
          NavigationDestination(icon: Icon(Icons.storage), label: 'Storage'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        ],
      ),
    );
  }

  /// Settings is reached via the gear icon in each screen's app bar,
  /// so it maps back to whichever tab the user was last on when active.
  int _calculateSelectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    if (location.startsWith('/inventory')) return 1;
    if (location.startsWith('/storage')) return 2;
    if (location.startsWith('/search')) return 3;
    return 0;
  }

  void _onItemTapped(int index, BuildContext context) {
    switch (index) {
      case 0:
        context.go('/');
      case 1:
        context.go('/inventory');
      case 2:
        context.go('/storage');
      case 3:
        context.go('/search');
    }
  }
}

/// App router configuration.
///
/// GoRouter uses declarative, URL-based routing (similar to web frameworks).
/// ShellRoute wraps child routes with the bottom nav bar.
/// Regular routes under the shell swap the body content.
final goRouter = GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/inventory',
          builder: (context, state) => const InventoryScreen(),
          routes: [
            GoRoute(
              path: ':itemId',
              builder: (context, state) {
                final itemId = state.pathParameters['itemId']!;
                return ItemDetailScreen(itemId: itemId);
              },
            ),
          ],
        ),
        GoRoute(
          path: '/storage',
          builder: (context, state) => const StorageScreen(),
          routes: [
            GoRoute(
              path: 'item',
              builder: (context, state) {
                final item = state.extra as CS2Item;
                return ItemDetailScreen(
                  itemId: item.marketHashName,
                  passedItem: item,
                );
              },
            ),
          ],
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) => const SearchScreen(),
          routes: [
            GoRoute(
              path: 'item',
              builder: (context, state) {
                final item = state.extra as CS2Item;
                return ItemDetailScreen(
                  itemId: item.marketHashName,
                  passedItem: item,
                );
              },
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
  ],
);
