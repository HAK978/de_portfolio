import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:webview_flutter/webview_flutter.dart';

import '../../providers/auth_provider.dart';
import '../../providers/inventory_provider.dart';
import '../../providers/price_history_provider.dart';
import '../../providers/price_provider.dart';
import '../../providers/storage_provider.dart';
import '../auth/steam_login_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _csfloatKeyController;
  late TextEditingController _storageUrlController;
  late TextEditingController _storageApiKeyController;

  @override
  void initState() {
    super.initState();
    _csfloatKeyController = TextEditingController(
      text: ref.read(csfloatApiKeyProvider),
    );
    _storageUrlController = TextEditingController(
      text: ref.read(storageServiceUrlProvider),
    );
    _storageApiKeyController = TextEditingController(
      text: ref.read(storageApiKeyProvider),
    );
  }

  @override
  void dispose() {
    _csfloatKeyController.dispose();
    _storageUrlController.dispose();
    _storageApiKeyController.dispose();
    super.dispose();
  }

  Future<void> _openSteamLogin() async {
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

  void _saveStorageConfig() {
    final url = _storageUrlController.text.trim();
    final key = _storageApiKeyController.text.trim();
    if (url.isNotEmpty) {
      ref.read(storageServiceUrlProvider.notifier).set(url);
    }
    ref.read(storageApiKeyProvider.notifier).set(key);
    // Re-check connection with the new config so the Storage tab's
    // status indicator reflects the change immediately.
    ref.invalidate(storageStatusProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Storage service config saved'),
        duration: Duration(seconds: 2),
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

          // Storage service (Steam GC) — URL + API key
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Storage Service',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'URL of the Steam Game Coordinator service. Defaults to the GCE VM. The API key authenticates each request.',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _storageUrlController,
                    decoration: InputDecoration(
                      labelText: 'Service URL',
                      hintText: 'http://192.168.1.100:3456',
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _storageApiKeyController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'API Key (leave blank for local dev)',
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _saveStorageConfig(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveStorageConfig,
                          icon: const Icon(Icons.save),
                          label: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
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
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Price history cache cleared'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // App info
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('About'),
              subtitle: Text('CS2 Portfolio Manager v1.1.0'),
            ),
          ),
        ],
      ),
    );
  }
}
