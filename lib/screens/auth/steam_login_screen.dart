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
  bool _navigatedToProfile = false; // true after we redirect to steamcommunity
  bool _extracting = false;

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
      _onResumedFromBackground();
    }
  }

  /// Check current URL when returning from background.
  /// Only extract if the WebView already redirected past the login page.
  /// If still on the login/guard page, do nothing — let the user continue.
  Future<void> _onResumedFromBackground() async {
    await Future.delayed(const Duration(milliseconds: 500));
    final url = await _controller.currentUrl() ?? '';
    debugPrint('Resumed, current URL: $url');

    if (!url.contains('/login') && !url.contains('/signin') &&
        (url.contains('steampowered.com') || url.contains('steamcommunity.com'))) {
      debugPrint('Past login on resume, going to profile...');
      _goToProfileAndExtract();
    } else {
      debugPrint('Still on login/guard page, waiting for user to continue.');
    }
  }

  /// After any page finishes loading, check if we're past login.
  void _checkForLogin(String url) {
    debugPrint('PAGE FINISHED: $url');

    // If we already navigated to steamcommunity — extract from here
    if (_navigatedToProfile) {
      if (url.contains('steamcommunity.com')) {
        _tryExtract(url);
      }
      return;
    }

    // Still on login/signin/guard pages — not done yet
    if (url.contains('/login') || url.contains('/signin')) return;

    // Past login on any Steam domain — navigate to steamcommunity once
    // to ensure the steamLoginSecure cookie is accessible
    final isSteam = url.contains('steampowered.com') ||
        url.contains('steamcommunity.com');
    if (!isSteam) return;

    debugPrint('Login detected — navigating to steamcommunity for cookie...');
    _navigatedToProfile = true;
    _controller.loadRequest(
        Uri.parse('https://steamcommunity.com/my/profile'));
  }

  /// Attempt extraction once; no-op if already in progress.
  Future<void> _tryExtract(String url) async {
    if (_extracting) return;
    _extracting = true;
    try {
      final result = await _extract(url);
      if (result != null && mounted) {
        Navigator.of(context).pop(result);
      }
    } finally {
      _extracting = false;
    }
  }

  /// Navigate to steamcommunity then extract once the page loads.
  /// Used by Done button and resume-from-background.
  Future<void> _goToProfileAndExtract() async {
    if (_navigatedToProfile) {
      // Already there or navigating — just try extraction now
      final url = await _controller.currentUrl() ?? '';
      _tryExtract(url);
      return;
    }
    _navigatedToProfile = true;
    _controller.loadRequest(
        Uri.parse('https://steamcommunity.com/my/profile'));
    // onPageFinished will call _tryExtract once the page loads
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
            onPressed: _goToProfileAndExtract,
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
