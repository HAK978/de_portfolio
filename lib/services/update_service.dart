import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// A release published on the app's GitHub Releases page.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.apkUrl,
    required this.checksumUrl,
    required this.notes,
    required this.pageUrl,
  });

  /// "1.3.1" (the tag without its leading "v").
  final String version;
  final Uri apkUrl;

  /// The release's `app-release.apk.sha256` asset.
  final Uri checksumUrl;
  final String notes;
  final Uri pageUrl;
}

/// Finds and downloads app updates from the project's GitHub Releases.
///
/// An updater is a code-delivery channel, so it's deliberately narrow:
/// - Only this repository's release assets are ever downloaded.
/// - The APK must match the SHA-256 published with the release, so a
///   truncated or corrupted download is never handed to the installer.
/// - Android itself refuses to install an update signed with a different
///   key than the installed app, so even a tampered download can't replace
///   the app without the release keystore.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const repository = 'HAK978/de_portfolio';
  static const apkAssetName = 'app-release.apk';
  static const checksumAssetName = 'app-release.apk.sha256';

  static final _latestReleaseUrl =
      Uri.parse('https://api.github.com/repos/$repository/releases/latest');

  final http.Client _client;

  /// The latest published release, or null if it has no APK attached.
  /// Throws [UpdateException] with a user-facing message on failure.
  Future<AppRelease?> latestRelease() async {
    final http.Response response;
    try {
      response = await _client.get(_latestReleaseUrl, headers: {
        'Accept': 'application/vnd.github+json',
      }).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const UpdateException('Could not reach GitHub. Check your connection.');
    }

    if (response.statusCode == 403 || response.statusCode == 429) {
      // Unauthenticated API calls are limited to 60 per hour per IP.
      throw const UpdateException('GitHub is rate-limiting update checks. Try again later.');
    }
    if (response.statusCode == 404) return null; // no releases yet
    if (response.statusCode != 200) {
      throw UpdateException('Update check failed (${response.statusCode}).');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = data['tag_name'] as String? ?? '';
    final assets = (data['assets'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    Uri? assetUrl(String name) {
      final raw = assets.where((a) => a['name'] == name).firstOrNull?['browser_download_url'];
      if (raw is! String) return null;
      final url = Uri.tryParse(raw);
      return url != null && isTrustedAssetUrl(url) ? url : null;
    }

    final apk = assetUrl(apkAssetName);
    if (apk == null) return null;
    final checksum = assetUrl(checksumAssetName);
    if (checksum == null) {
      throw UpdateException('Release $tag has no checksum, so it can\'t be verified.');
    }

    return AppRelease(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      apkUrl: apk,
      checksumUrl: checksum,
      notes: (data['body'] as String? ?? '').trim(),
      pageUrl: Uri.tryParse(data['html_url'] as String? ?? '') ??
          Uri.parse('https://github.com/$repository/releases'),
    );
  }

  /// Release assets must come from this repository over HTTPS.
  static bool isTrustedAssetUrl(Uri url) =>
      url.scheme == 'https' &&
      url.host == 'github.com' &&
      url.path.startsWith('/$repository/releases/download/');

  /// Whether [candidate] ("1.3.1") is a newer release than [current]
  /// ("1.3.0"). Compares major.minor.patch numerically; anything that
  /// isn't plain x.y.z (e.g. "1.4.0-beta") is never offered.
  static bool isNewer(String candidate, String current) {
    final a = _parse(candidate);
    final b = _parse(current.split('+').first);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int>? _parse(String version) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(version.trim());
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  /// Downloads [release]'s APK into [directory], verifies its SHA-256,
  /// and returns the file. Reports progress as (bytesReceived, totalBytes);
  /// total is null when the server doesn't say.
  Future<File> download(
    AppRelease release,
    Directory directory, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final expected = await _expectedChecksum(release);

    // The folder only ever holds the update in progress; drop APKs left
    // over from earlier updates.
    await directory.create(recursive: true);
    for (final old in directory.listSync().whereType<File>()) {
      old.deleteSync();
    }
    final file = File('${directory.path}/app-release-${release.version}.apk');
    final partial = File('${file.path}.part');

    try {
      final response = await _client
          .send(http.Request('GET', release.apkUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw UpdateException('Download failed (${response.statusCode}).');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = partial.openWrite();
      try {
        await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (total != null && received != total) {
        throw const UpdateException('Download was interrupted. Please try again.');
      }

      final actual = (await sha256.bind(partial.openRead()).first).toString();
      if (actual != expected) {
        throw const UpdateException('The download didn\'t match its checksum, so it was discarded.');
      }

      if (file.existsSync()) file.deleteSync();
      return partial.renameSync(file.path);
    } on UpdateException {
      if (partial.existsSync()) partial.deleteSync();
      rethrow;
    } catch (_) {
      if (partial.existsSync()) partial.deleteSync();
      throw const UpdateException('Download failed. Check your connection and try again.');
    }
  }

  Future<String> _expectedChecksum(AppRelease release) async {
    try {
      final response = await _client.get(release.checksumUrl).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        // sha256sum format: "<64 hex chars>  app-release.apk"
        final hash = response.body.trim().split(RegExp(r'\s+')).first.toLowerCase();
        if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) return hash;
      }
    } catch (_) {}
    throw const UpdateException('Could not read the release checksum.');
  }
}

/// A failure the UI can show as-is.
class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}
