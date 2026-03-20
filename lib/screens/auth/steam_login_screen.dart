import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Result returned after a successful Steam login.
class SteamLoginResult {
  final String steamId;
  final String? steamLoginCookie;

  const SteamLoginResult({
    required this.steamId,
    this.steamLoginCookie,
  });
}

class SteamLoginScreen extends StatefulWidget {
  const SteamLoginScreen({super.key});

  @override
  State<SteamLoginScreen> createState() => _SteamLoginScreenState();
}

class _SteamLoginScreenState extends State<SteamLoginScreen>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _isLoading = true;
  bool _wasBackgrounded = false;
  bool _redirectedToProfile = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            debugPrint('STARTED: $url');
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (url) {
            debugPrint('FINISHED: $url');
            if (mounted) setState(() => _isLoading = false);
            _checkForLogin(url);
          },
          onWebResourceError: (e) {
            debugPrint('ERROR: ${e.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(
        'https://store.steampowered.com/login/?redir=my/profile',
      ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
    }
    if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      debugPrint('Resumed from background, extracting...');
      _extractAndClose();
    }
  }

  /// After any page finishes loading, check if we're past the login page.
  void _checkForLogin(String url) {
    if (_redirectedToProfile) {
      // Already redirected — extract data now
      if (url.contains('steamcommunity.com')) {
        _extract(url).then((result) {
          if (result != null && mounted) {
            Navigator.of(context).pop(result);
          }
        });
      }
      return;
    }

    if (url.contains('/login')) return;

    final isSteam = url.contains('steampowered.com') ||
        url.contains('steamcommunity.com');
    if (!isSteam) return;

    debugPrint('Login detected, navigating to profile...');
    _redirectedToProfile = true;
    _controller.loadRequest(
      Uri.parse('https://steamcommunity.com/my/profile'),
    );
  }

  /// Navigate to community profile, read cookie + Steam ID, close.
  Future<void> _extractAndClose() async {
    try {
      await _controller.loadRequest(
        Uri.parse('https://steamcommunity.com/my/profile'),
      );
      await Future.delayed(const Duration(seconds: 3));

      final url = await _controller.currentUrl() ?? '';
      final result = await _extract(url);

      if (result != null && mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      debugPrint('Extract error: $e');
    }
  }

  /// Platform channel to read HttpOnly cookies from Android's native CookieManager.
  static const _cookieChannel = MethodChannel('com.deportfolio/cookies');

  /// Read native HttpOnly cookies for a given URL.
  Future<String?> _getNativeCookies(String url) async {
    try {
      final cookies = await _cookieChannel.invokeMethod<String>(
        'getCookies',
        {'url': url},
      );
      return cookies;
    } catch (e) {
      debugPrint('Native cookie read error: $e');
      return null;
    }
  }

  /// Read cookie and Steam ID from the current WebView state.
  Future<SteamLoginResult?> _extract(String url) async {
    String? steamId;
    String? cookie;

    // Steam ID from URL
    final m = RegExp(r'profiles/(\d{17})').firstMatch(url);
    if (m != null) steamId = m.group(1);

    // Read HttpOnly cookies via native Android CookieManager
    final nativeCookies =
        await _getNativeCookies('https://steamcommunity.com');
    if (nativeCookies != null && nativeCookies.isNotEmpty) {
      debugPrint('Native cookies length: ${nativeCookies.length}');
      final cm =
          RegExp(r'steamLoginSecure=([^;]+)').firstMatch(nativeCookies);
      if (cm != null) {
        cookie = cm.group(1);
        debugPrint('Found steamLoginSecure via native CookieManager');

        // Extract Steam ID from cookie value if not found in URL
        if (steamId == null) {
          final im = RegExp(r'^(\d{17})').firstMatch(cookie!);
          if (im != null) steamId = im.group(1);
        }
      } else {
        debugPrint('steamLoginSecure not found in native cookies');
      }
    } else {
      debugPrint('No native cookies returned');
    }

    // Fallback: Steam ID from page DOM
    if (steamId == null) {
      try {
        final r = await _controller.runJavaScriptReturningResult(
          '(function(){var e=document.querySelector("[data-steamid]");'
          'if(e)return e.getAttribute("data-steamid");'
          'if(typeof g_steamID!=="undefined"&&g_steamID)return g_steamID;'
          'return "";})()',
        );
        final id = r.toString().replaceAll('"', '');
        if (RegExp(r'^\d{17}$').hasMatch(id)) steamId = id;
      } catch (_) {}
    }

    if (steamId == null && cookie == null) return null;

    debugPrint('Steam ID: $steamId, cookie: ${cookie != null ? "yes" : "no"}');
    return SteamLoginResult(steamId: steamId ?? '', steamLoginCookie: cookie);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Sign in with Steam',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        actions: [
          TextButton(
            onPressed: _extractAndClose,
            child: const Text('Done'),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
