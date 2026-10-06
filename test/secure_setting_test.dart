// Tests for SecureSetting / SecureSettingNotifier: where the app keeps
// the Steam session cookie and API keys. The migration path matters
// because older builds left these secrets in plaintext files.

import 'dart:async';
import 'dart:io';

import 'package:de_portfolio/services/secure_setting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Secure storage that can be paused (to test races) or made to fail.
class ControlledStorage extends FlutterSecureStorage {
  ControlledStorage({this.failWrites = false});

  final bool failWrites;
  final values = <String, String>{};
  Completer<void>? readGate;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    // Capture the value first, like a real read already in flight.
    final value = values[key];
    await readGate?.future;
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrites) throw StateError('keystore unavailable');
    values[key] = value!;
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class TestSettingNotifier extends SecureSettingNotifier {
  TestSettingNotifier(this.setting);

  @override
  final SecureSetting setting;
}

void main() {
  late Directory docs;
  late ControlledStorage storage;

  setUp(() {
    docs = Directory.systemTemp.createTempSync('secure_setting_test');
    storage = ControlledStorage();
  });
  tearDown(() => docs.deleteSync(recursive: true));

  SecureSetting settingWith(FlutterSecureStorage s) => SecureSetting(
        'api_key',
        legacyFileName: 'api_key.txt',
        storage: s,
        documentsDirectory: () async => docs,
      );
  File legacyFile() => File('${docs.path}/api_key.txt');

  group('SecureSetting.read', () {
    test('migrates a plaintext file into secure storage, then deletes it', () async {
      legacyFile().writeAsStringSync('  secret-value\n');

      expect(await settingWith(storage).read(), 'secret-value');
      expect(storage.values['api_key'], 'secret-value');
      expect(legacyFile().existsSync(), isFalse);
    });

    test('secure storage wins, and a leftover plaintext copy is removed', () async {
      storage.values['api_key'] = 'current';
      legacyFile().writeAsStringSync('stale');

      expect(await settingWith(storage).read(), 'current');
      expect(legacyFile().existsSync(), isFalse);
    });

    test('an empty legacy file is removed without storing anything', () async {
      legacyFile().writeAsStringSync('   ');

      expect(await settingWith(storage).read(), isNull);
      expect(storage.values, isEmpty);
      expect(legacyFile().existsSync(), isFalse);
    });

    test('if secure storage fails, the plaintext value is kept, not lost', () async {
      legacyFile().writeAsStringSync('secret-value');

      await expectLater(settingWith(ControlledStorage(failWrites: true)).read(), throwsStateError);
      expect(legacyFile().readAsStringSync(), 'secret-value');
    });

    test('returns null when nothing was ever saved', () async {
      expect(await settingWith(storage).read(), isNull);
    });
  });

  test('SecureSetting.write with an empty string deletes the secret', () async {
    final setting = settingWith(storage);
    await setting.write('abc');
    expect(storage.values['api_key'], 'abc');
    await setting.write('');
    expect(storage.values.containsKey('api_key'), isFalse);
  });

  group('SecureSettingNotifier', () {
    NotifierProvider<TestSettingNotifier, String> providerFor(SecureSetting setting) =>
        NotifierProvider<TestSettingNotifier, String>(() => TestSettingNotifier(setting));

    test('starts empty and exposes the stored value once loaded', () async {
      storage.values['api_key'] = 'stored';
      final provider = providerFor(settingWith(storage));
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(provider), '');
      await container.read(provider.notifier).loaded;
      expect(container.read(provider), 'stored');
    });

    test('a value the user clears before the load finishes stays cleared', () async {
      storage.values['api_key'] = 'old-key';
      storage.readGate = Completer<void>();
      final provider = providerFor(settingWith(storage));
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(provider.notifier).set('');
      storage.readGate!.complete();
      await container.read(provider.notifier).loaded;

      expect(container.read(provider), '');
      expect(storage.values.containsKey('api_key'), isFalse);
    });

    test('set() saves through to secure storage', () async {
      final provider = providerFor(settingWith(storage));
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(provider.notifier).set('new-key');
      await pumpEventQueue();
      expect(storage.values['api_key'], 'new-key');
    });
  });

  test('every app secret has its own key and migrates from its old file', () {
    const secrets = [Secrets.csfloatApiKey, Secrets.storageApiKey, Secrets.steamLoginCookie];
    expect(secrets.map((s) => s.key).toSet(), hasLength(secrets.length));
    expect(secrets.every((s) => s.legacyFileName != null), isTrue);
  });
}
