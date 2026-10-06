import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// A secret string kept in Keystore-backed secure storage (Android
/// Keystore / iOS Keychain) rather than a plaintext file, which any
/// backup or rooted-device reader could copy.
///
/// Older builds wrote these values to plaintext files in the app's
/// documents directory. [read] migrates such a file once: it copies the
/// value into secure storage, then deletes the file.
class SecureSetting {
  const SecureSetting(
    this.key, {
    this.legacyFileName,
    this.storage = const FlutterSecureStorage(),
    this.documentsDirectory = getApplicationDocumentsDirectory,
  });

  final String key;
  final String? legacyFileName;
  final FlutterSecureStorage storage;
  final Future<Directory> Function() documentsDirectory;

  /// The stored value, or null if none. Never returns an empty string.
  Future<String?> read() async {
    final stored = await storage.read(key: key);
    final legacy = await _legacyFile();

    if (stored != null && stored.isNotEmpty) {
      // A plaintext copy can outlive the migration if deleting it failed.
      if (legacy != null) await _deleteQuietly(legacy);
      return stored;
    }
    if (legacy == null) return null;

    final value = (await legacy.readAsString()).trim();
    // Copy before deleting, so a failed write never loses the value.
    if (value.isNotEmpty) await storage.write(key: key, value: value);
    await _deleteQuietly(legacy);
    return value.isEmpty ? null : value;
  }

  Future<File?> _legacyFile() async {
    final fileName = legacyFileName;
    if (fileName == null) return null;
    final file = File('${(await documentsDirectory()).path}/$fileName');
    return file.existsSync() ? file : null;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Saves [value]; an empty string removes the secret.
  Future<void> write(String value) => value.isEmpty
      ? storage.delete(key: key)
      : storage.write(key: key, value: value);
}

/// Secrets the app stores on the device.
abstract final class Secrets {
  static const csfloatApiKey =
      SecureSetting('csfloat_api_key', legacyFileName: 'csfloat_api_key.txt');
  static const storageApiKey =
      SecureSetting('storage_api_key', legacyFileName: 'storage_api_key.txt');
  static const steamLoginCookie =
      SecureSetting('steam_login_cookie', legacyFileName: 'steam_login_cookie.txt');
}

/// Holds one [SecureSetting] as provider state.
///
/// State starts empty and fills in once the stored value has loaded.
/// Code that needs the real value right after launch should
/// `await notifier.loaded` and then re-read the provider, instead of
/// polling until the state turns non-empty.
abstract class SecureSettingNotifier extends Notifier<String> {
  SecureSetting get setting;

  /// Completes once the stored value has been loaded into [state].
  late Future<void> loaded;

  // Set once the user saves or clears the value, so the initial load
  // can't overwrite that choice (e.g. resurrect a key they just cleared).
  bool _changedByUser = false;

  @override
  String build() {
    // Keep the secret in memory for the whole session; re-reading
    // secure storage on every rebuild would flash an empty value.
    ref.keepAlive();
    loaded = _load();
    return '';
  }

  Future<void> _load() async {
    try {
      final value = await setting.read();
      if (value != null && !_changedByUser) state = value;
    } catch (e) {
      debugPrint('Could not load ${setting.key}: $e');
    }
  }

  void set(String value) {
    _changedByUser = true;
    state = value;
    setting.write(value).catchError(
      (Object e) => debugPrint('Could not save ${setting.key}: $e'),
    );
  }
}
