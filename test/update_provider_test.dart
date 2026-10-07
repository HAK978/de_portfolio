// Tests for the update button's flow (UpdateNotifier), with the network
// and the Android installer faked.

import 'dart:io';

import 'package:de_portfolio/providers/update_provider.dart';
import 'package:de_portfolio/services/update_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

AppRelease release(String version) => AppRelease(
      version: version,
      apkUrl: Uri.parse('https://github.com/HAK978/de_portfolio/releases/download/v$version/app-release.apk'),
      checksumUrl: Uri.parse('https://github.com/HAK978/de_portfolio/releases/download/v$version/app-release.apk.sha256'),
      notes: 'notes',
      pageUrl: Uri.parse('https://github.com/HAK978/de_portfolio/releases'),
    );

class FakeService extends UpdateService {
  FakeService({this.latest, this.checkError, this.downloadError});
  AppRelease? latest;
  UpdateException? checkError;
  UpdateException? downloadError;
  int downloads = 0;

  @override
  Future<AppRelease?> latestRelease() async {
    if (checkError != null) throw checkError!;
    return latest;
  }

  @override
  Future<File> download(AppRelease release, Directory directory,
      {void Function(int received, int? total)? onProgress}) async {
    downloads++;
    if (downloadError != null) throw downloadError!;
    onProgress?.call(50, 100);
    onProgress?.call(100, 100);
    await directory.create(recursive: true);
    return File('${directory.path}/app-release-${release.version}.apk')..writeAsStringSync('apk');
  }
}

class FakeInstaller implements ApkInstaller {
  final results = <InstallResult>[];
  final installed = <String>[];

  @override
  Future<InstallResult> install(String apkPath) async {
    installed.add(apkPath);
    return results.isEmpty ? InstallResult.started : results.removeAt(0);
  }
}

void main() {
  late Directory dir;
  late FakeService service;
  late FakeInstaller installer;
  late ProviderContainer container;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('update_provider_test');
    service = FakeService(latest: release('1.3.1'));
    installer = FakeInstaller();
    container = ProviderContainer(overrides: [
      updateServiceProvider.overrideWithValue(service),
      apkInstallerProvider.overrideWithValue(installer),
      appVersionProvider.overrideWith((ref) async => '1.3.0'),
      updateDirectoryProvider.overrideWithValue(() async => Directory('${dir.path}/updates')),
    ]);
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  UpdateState state() => container.read(updateProvider);
  UpdateNotifier notifier() => container.read(updateProvider.notifier);

  group('check', () {
    test('offers a newer release', () async {
      await notifier().check();
      expect(state().status, UpdateStatus.available);
      expect(state().release!.version, '1.3.1');
    });

    test('reports up to date when the latest release is this build', () async {
      service.latest = release('1.3.0');
      await notifier().check();
      expect(state().status, UpdateStatus.upToDate);
    });

    test('reports up to date when there are no releases', () async {
      service.latest = null;
      await notifier().check();
      expect(state().status, UpdateStatus.upToDate);
    });

    test('shows the service\'s message on failure', () async {
      service.checkError = const UpdateException('GitHub is rate-limiting update checks.');
      await notifier().check();
      expect(state().status, UpdateStatus.error);
      expect(state().message, contains('rate-limiting'));
    });
  });

  group('downloadAndInstall', () {
    test('downloads with progress, then opens the installer', () async {
      await notifier().check();
      final seen = <UpdateStatus>[];
      container.listen(updateProvider, (_, next) => seen.add(next.status));

      await notifier().downloadAndInstall();

      expect(seen, containsAllInOrder([UpdateStatus.downloading, UpdateStatus.installing]));
      expect(installer.installed.single, endsWith('app-release-1.3.1.apk'));
    });

    test('after granting install permission, reuses the download', () async {
      installer.results.add(InstallResult.needsPermission);
      await notifier().check();

      await notifier().downloadAndInstall();
      expect(state().status, UpdateStatus.needsPermission);
      expect(state().message, contains('Install unknown apps'));

      await notifier().downloadAndInstall();
      expect(state().status, UpdateStatus.installing);
      expect(service.downloads, 1);
      expect(installer.installed, hasLength(2));
    });

    test('a failed download keeps the release so the user can retry', () async {
      service.downloadError = const UpdateException('The download didn\'t match its checksum, so it was discarded.');
      await notifier().check();

      await notifier().downloadAndInstall();
      expect(state().status, UpdateStatus.error);
      expect(state().release!.version, '1.3.1');
      expect(installer.installed, isEmpty);

      service.downloadError = null;
      await notifier().downloadAndInstall();
      expect(state().status, UpdateStatus.installing);
    });

    test('does nothing until a release has been found', () async {
      await notifier().downloadAndInstall();
      expect(service.downloads, 0);
      expect(state().status, UpdateStatus.idle);
    });
  });
}
