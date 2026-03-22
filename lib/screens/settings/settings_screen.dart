import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:webview_flutter/webview_flutter.dart';

import '../../providers/auth_provider.dart';
import '../../providers/inventory_provider.dart';
import '../../providers/price_history_provider.dart';
import '../../providers/price_provider.dart';
import '../auth/steam_login_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _steamIdController;
  late TextEditingController _csfloatKeyController;
  late TextEditingController _steamCookieController;

  @override
  void initState() {
    super.initState();
    _steamIdController = TextEditingController(
      text: ref.read(steamIdProvider),
    );
    _csfloatKeyController = TextEditingController(
      text: ref.read(csfloatApiKeyProvider),
    );
    _steamCookieController = TextEditingController(
      text: ref.read(steamLoginCookieProvider),
    );
  }

  @override
  void dispose() {
    _steamIdController.dispose();
    _csfloatKeyController.dispose();
    _steamCookieController.dispose();
    super.dispose();
  }

  /// Extracts a Steam ID from various input formats:
  /// - Direct ID: 76561198369694237
  /// - Profile URL: https://steamcommunity.com/profiles/76561198369694237/
  String _extractSteamId(String input) {
    input = input.trim();
    // Try to extract from URL
    final profileMatch = RegExp(r'profiles/(\d{17})').firstMatch(input);
    if (profileMatch != null) return profileMatch.group(1)!;
    // Check if it's already a raw ID
    if (RegExp(r'^\d{17}$').hasMatch(input)) return input;
    return input;
  }

  Future<void> _openSteamLogin() async {
    final result = await Navigator.of(context).push<SteamLoginResult>(
      MaterialPageRoute(builder: (_) => const SteamLoginScreen()),
    );

    if (result == null) return;

    if (result.steamId.isNotEmpty) {
      _steamIdController.text = result.steamId;
      ref.read(steamIdProvider.notifier).set(result.steamId);
      // Sign in to Firebase so Firestore writes are authenticated
      ref.read(authProvider.notifier).signInWithSteamId(result.steamId);
    }

    if (result.steamLoginCookie != null &&
        result.steamLoginCookie!.isNotEmpty) {
      _steamCookieController.text = result.steamLoginCookie!;
      ref.read(steamLoginCookieProvider.notifier).set(result.steamLoginCookie!);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Signed in${result.steamId.isNotEmpty ? " as ${result.steamId}" : ""}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _saveSteamCookie() {
    final cookie = _steamCookieController.text.trim();
    if (cookie.isEmpty) return;
    ref.read(steamLoginCookieProvider.notifier).set(cookie);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Steam cookie saved — price history charts enabled'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _saveCsfloatKey() {
    final key = _csfloatKeyController.text.trim();
    if (key.isEmpty) return;
    ref.read(csfloatApiKeyProvider.notifier).set(key);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('CSFloat API key saved'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _saveSteamId() {
    final id = _extractSteamId(_steamIdController.text);
    debugPrint('_saveSteamId called, extracted id: "$id" from "${_steamIdController.text}"');
    if (id.isEmpty) return;

    _steamIdController.text = id;
    ref.read(steamIdProvider.notifier).set(id);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Steam ID set to $id. Fetching inventory...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildSteamLoginCard(String steamId, String cookie, WidgetRef ref) {
    final isLoggedIn = steamId.isNotEmpty;
    final hasCookie = cookie.isNotEmpty;
    final sessionValid = ref.watch(steamSessionValidProvider);

    // Determine session status: null = checking, true = valid, false = expired
    final ({IconData icon, Color color, String text}) sessionStatus;
    if (!hasCookie) {
      sessionStatus = (
        icon: Icons.warning_amber,
        color: Colors.orangeAccent,
        text: 'No session cookie — charts unavailable',
      );
    } else {
      sessionStatus = sessionValid.when(
        loading: () => (
          icon: Icons.hourglass_top,
          color: Colors.grey,
          text: 'Checking Steam session...',
        ),
        error: (_, _) => (
          icon: Icons.warning_amber,
          color: Colors.orangeAccent,
          text: 'Could not verify session',
        ),
        data: (valid) {
          if (valid == null) {
            return (
              icon: Icons.hourglass_top,
              color: Colors.grey,
              text: 'Loading cookie...',
            );
          }
          if (valid) {
            return (
              icon: Icons.check_circle,
              color: Colors.greenAccent[400]!,
              text: 'Steam session active — charts enabled',
            );
          }
          return (
            icon: Icons.error_outline,
            color: Colors.redAccent,
            text: 'Steam session expired — re-sign in to fix',
          );
        },
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Steam Account',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (isLoggedIn) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.greenAccent[400], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Signed in: $steamId',
                      style: TextStyle(color: Colors.greenAccent[100], fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(sessionStatus.icon, color: sessionStatus.color, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sessionStatus.text,
                      style: TextStyle(color: sessionStatus.color, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _openSteamLogin,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Re-sign in'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        ref.read(steamIdProvider.notifier).set('');
                        ref.read(steamLoginCookieProvider.notifier).set('');
                        _steamIdController.clear();
                        _steamCookieController.clear();
                        // Sign out of Firebase
                        ref.read(authProvider.notifier).signOut();
                        // Clear WebView cookies so next login starts fresh
                        try {
                          final cookieManager = WebViewCookieManager();
                          await cookieManager.clearCookies();
                        } catch (_) {}
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Signed out'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Sign out'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 4),
              Text(
                'Sign in to auto-fill Steam ID and enable price history charts',
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openSteamLogin,
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in with Steam'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(steamIdProvider);
    final inventoryAsync = ref.watch(inventoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Steam login
          _buildSteamLoginCard(currentId, ref.watch(steamLoginCookieProvider), ref),
          const SizedBox(height: 12),

          // Steam ID input (manual)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Steam Account',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _steamIdController,
                    decoration: InputDecoration(
                      labelText: 'Steam ID or Profile URL',
                      hintText: '76561198... or profile URL',
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _saveSteamId(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveSteamId,
                          icon: const Icon(Icons.sync),
                          label: const Text('Fetch Inventory'),
                        ),
                      ),
                    ],
                  ),
                  if (currentId.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Builder(builder: (context) {
                      final progress = ref.watch(inventoryFetchProgressProvider);
                      return inventoryAsync.when(
                      loading: () => Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            progress.itemsFetched > 0
                                ? 'Fetching... ${progress.itemsFetched} items (page ${progress.pagesFetched})'
                                : 'Fetching inventory...',
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          ),
                        ],
                      ),
                      error: (e, _) => Text(
                        'Error: $e',
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                      data: (items) => Text(
                        'Loaded ${items.length} unique items',
                        style: TextStyle(color: Colors.greenAccent[100], fontSize: 12),
                      ),
                    );
                    }),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // CSFloat API key
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CSFloat API Key',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Get from csfloat.com → Profile → Developer',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _csfloatKeyController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: 'Enter your CSFloat API key',
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _saveCsfloatKey(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveCsfloatKey,
                          icon: const Icon(Icons.save),
                          label: const Text('Save Key'),
                        ),
                      ),
                    ],
                  ),
                  if (ref.watch(csfloatApiKeyProvider).isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Key saved',
                      style: TextStyle(color: Colors.greenAccent[100], fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Steam login cookie (for price history)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Steam Login Cookie',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Required for price history charts. Get from browser DevTools → Cookies → steamLoginSecure',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _steamCookieController,
                    obscureText: true,
                    maxLines: 1,
                    decoration: InputDecoration(
                      labelText: 'steamLoginSecure cookie',
                      hintText: 'Paste cookie value here',
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _saveSteamCookie(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveSteamCookie,
                          icon: const Icon(Icons.save),
                          label: const Text('Save Cookie'),
                        ),
                      ),
                    ],
                  ),
                  if (ref.watch(steamLoginCookieProvider).isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Cookie saved — charts enabled',
                      style: TextStyle(color: Colors.greenAccent[100], fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Clear price history cache
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Clear Price History Cache'),
              subtitle: Text(
                'Force re-fetch chart data from Steam',
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
              onTap: () async {
                final service = ref.read(priceHistoryServiceProvider);
                await service.clearCache();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Price history cache cleared'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          ),
          const SizedBox(height: 12),

          // Currency selection
          Card(
            child: ListTile(
              leading: const Icon(Icons.attach_money),
              title: const Text('Currency'),
              subtitle: const Text('USD'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ),
          const SizedBox(height: 12),

          // Notification preferences
          Card(
            child: Column(
              children: [
                const ListTile(
                  leading: Icon(Icons.notifications_outlined),
                  title: Text('Notifications'),
                ),
                SwitchListTile(
                  title: const Text('Price spike alerts'),
                  subtitle: const Text('Notify when items spike >50%'),
                  value: true,
                  onChanged: (value) {},
                ),
                SwitchListTile(
                  title: const Text('Daily summary'),
                  subtitle: const Text('Daily portfolio value update'),
                  value: false,
                  onChanged: (value) {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // App info
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              subtitle: const Text('CS2 Portfolio Manager v0.1.0'),
            ),
          ),
        ],
      ),
    );
  }
}
