import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../models/steam_login_session.dart';
import '../../providers/auth_provider.dart';

/// Returned only after Steam verification and Firebase sign-in both succeed.
class SteamLoginResult {
  final String steamId;
  final String? steamLoginCookie;
  const SteamLoginResult({required this.steamId, this.steamLoginCookie});
}

class SteamLoginScreen extends ConsumerStatefulWidget {
  const SteamLoginScreen({super.key});
  @override
  ConsumerState<SteamLoginScreen> createState() => _SteamLoginScreenState();
}

class _SteamLoginScreenState extends ConsumerState<SteamLoginScreen> {
  WebViewController? _controller;
  SteamLoginSession? _session;
  bool _loading = true;
  bool _verifying = false;
  String? _error;
  static const _cookieChannel = MethodChannel('com.deportfolio/cookies');

  @override
  void initState() {
    super.initState();
    _startLogin();
  }

  Future<void> _startLogin() async {
    setState(() {
      _error = null;
      _loading = true;
      _controller = null;
      _session = null;
    });
    try {
      final session = await ref.read(authProvider.notifier).beginSteamLogin();
      if (!mounted) return;
      _session = session;
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (session.isCallback(uri)) {
              if (request.isMainFrame) _finishLogin(uri);
              return NavigationDecision.prevent;
            }
            const hosts = ['steamcommunity.com', 'steampowered.com', 'steamstatic.com', 'akamaihd.net'];
            final allowed = uri.scheme == 'https' && hosts.any(
              (host) => uri.host == host || uri.host.endsWith('.$host'),
            );
            return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted && !_verifying) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() {
                _error = 'Steam could not load. Check your connection and try again.';
                _loading = false;
              });
            }
          },
        ));
      setState(() => _controller = controller);
      await controller.loadRequest(session.loginUrl);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not start Steam sign-in. Check your connection and try again.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _finishLogin(Uri uri) async {
    if (_verifying || !mounted) return;
    setState(() {
      _verifying = true;
      _loading = true;
    });
    try {
      if (uri.queryParameters['openid.mode'] == 'cancel') {
        throw const FormatException('Steam sign-in was cancelled.');
      }
      final session = _session!;
      final assertion = session.assertionFrom(uri);
      final steamId = await ref.read(authProvider.notifier).signInWithSteamAssertion(
        session.sessionId, assertion,
      );
      String? cookie;
      // Optional Android cookie enables Steam price-history requests. Identity
      // never comes from this cookie, the DOM, or a public profile URL.
      try {
        final cookies = await _cookieChannel.invokeMethod<String>(
          'getCookies', {'url': 'https://steamcommunity.com'},
        );
        final value = RegExp(r'steamLoginSecure=([^;]+)').firstMatch(cookies ?? '')?.group(1);
        if (value != null && Uri.decodeComponent(value).startsWith('$steamId||')) {
          cookie = value;
        }
      } catch (_) {
        // Native cookie extraction is currently Android-only.
      }
      if (mounted) {
        Navigator.of(context).pop(SteamLoginResult(steamId: steamId, steamLoginCookie: cookie));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Steam sign-in could not be verified. Please try again.';
          _loading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_verifying,
    child: Scaffold(
      appBar: AppBar(title: const Text('Sign in with Steam')),
      body: Stack(children: [
        if (_error != null)
          Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _startLogin, child: const Text('Try again')),
            ]),
          ))
        else if (_controller != null)
          AbsorbPointer(absorbing: _verifying, child: WebViewWidget(controller: _controller!)),
        if (_loading) const LinearProgressIndicator(),
      ]),
    ),
  );
}
