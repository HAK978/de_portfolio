import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../services/update_service.dart';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  needsPermission,
  installing,
  error,
}

class UpdateState {
  const UpdateState({
    this.status = UpdateStatus.idle,
    this.release,
    this.progress,
    this.message,
  });

  final UpdateStatus status;
  final AppRelease? release;

  /// Download progress from 0 to 1, or null when the size is unknown.
  final double? progress;

  /// User-facing explanation for [UpdateStatus.error] and
  /// [UpdateStatus.needsPermission].
  final String? message;
}

enum InstallResult { started, needsPermission }

/// Hands a downloaded APK to Android's package installer (see
/// MainActivity.kt). Android asks the user to confirm the update, and
/// rejects it unless it's signed with the same key as the installed app.
class ApkInstaller {
  const ApkInstaller();

  static const _channel = MethodChannel('com.deportfolio/updates');

  Future<InstallResult> install(String apkPath) async {
    final result = await _channel.invokeMethod<String>('installApk', {'path': apkPath});
    return result == 'needs_permission' ? InstallResult.needsPermission : InstallResult.started;
  }
}

final updateServiceProvider = Provider<UpdateService>((ref) => UpdateService());

final apkInstallerProvider = Provider<ApkInstaller>((ref) => const ApkInstaller());

/// The installed app's version, e.g. "1.3.1".
final appVersionProvider = FutureProvider<String>((ref) async {
  return (await PackageInfo.fromPlatform()).version;
});

/// Where downloaded APKs go. Must match res/xml/update_paths.xml, which
/// is the only folder the installer is allowed to read from.
final updateDirectoryProvider = Provider<Future<Directory> Function()>((ref) {
  return () async => Directory('${(await getTemporaryDirectory()).path}/updates');
});

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);

class UpdateNotifier extends Notifier<UpdateState> {
  File? _downloaded;

  @override
  UpdateState build() => const UpdateState();

  bool get _busy =>
      state.status == UpdateStatus.checking || state.status == UpdateStatus.downloading;

  /// Looks up the latest GitHub release and compares it to this build.
  Future<void> check() async {
    if (_busy) return;
    state = const UpdateState(status: UpdateStatus.checking);
    try {
      final current = await ref.read(appVersionProvider.future);
      final release = await ref.read(updateServiceProvider).latestRelease();
      state = release != null && UpdateService.isNewer(release.version, current)
          ? UpdateState(status: UpdateStatus.available, release: release)
          : const UpdateState(status: UpdateStatus.upToDate);
    } on UpdateException catch (e) {
      state = UpdateState(status: UpdateStatus.error, message: e.message);
    } catch (_) {
      state = const UpdateState(status: UpdateStatus.error, message: 'Update check failed.');
    }
  }

  /// Downloads and verifies the available release, then opens the
  /// installer. If Android needs the "install unknown apps" permission
  /// first, calling this again after granting it reuses the download.
  Future<void> downloadAndInstall() async {
    final release = state.release;
    if (release == null || _busy) return;

    try {
      var apk = _downloaded;
      if (apk == null || !apk.existsSync() || !apk.path.contains(release.version)) {
        state = UpdateState(status: UpdateStatus.downloading, release: release, progress: 0);
        final directory = await ref.read(updateDirectoryProvider)();
        var lastPercent = 0;
        apk = await ref.read(updateServiceProvider).download(
          release,
          directory,
          onProgress: (received, total) {
            if (total == null || total <= 0) return;
            // Rebuild once per percent, not once per network chunk.
            final percent = received * 100 ~/ total;
            if (percent == lastPercent) return;
            lastPercent = percent;
            state = UpdateState(status: UpdateStatus.downloading, release: release, progress: percent / 100);
          },
        );
        _downloaded = apk;
      }

      final result = await ref.read(apkInstallerProvider).install(apk.path);
      state = switch (result) {
        InstallResult.started => UpdateState(status: UpdateStatus.installing, release: release),
        InstallResult.needsPermission => UpdateState(
            status: UpdateStatus.needsPermission,
            release: release,
            message: 'Allow "Install unknown apps" for CS2 Portfolio, then tap Install again.',
          ),
      };
    } on UpdateException catch (e) {
      state = UpdateState(status: UpdateStatus.error, release: release, message: e.message);
    } catch (_) {
      state = UpdateState(status: UpdateStatus.error, release: release, message: 'Could not install the update.');
    }
  }
}
