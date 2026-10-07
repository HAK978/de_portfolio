import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/update_provider.dart';

/// "About & updates" card for Settings: shows the installed version and
/// lets the user download and install the latest GitHub release.
class UpdateCard extends ConsumerWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider);
    final update = ref.watch(updateProvider);
    final notifier = ref.read(updateProvider.notifier);
    final release = update.release;
    final muted = TextStyle(color: Colors.grey[400], fontSize: 12);

    Widget body;
    switch (update.status) {
      case UpdateStatus.checking:
        body = const _Busy(label: 'Checking for updates...');
      case UpdateStatus.downloading:
        final percent = update.progress == null ? '' : ' ${(update.progress! * 100).round()}%';
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Downloading v${release?.version}...$percent', style: muted),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: update.progress),
          ],
        );
      case UpdateStatus.available:
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${release!.version} is available',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(release.notes, style: muted, maxLines: 6, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: notifier.downloadAndInstall,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download & install'),
            ),
          ],
        );
      case UpdateStatus.needsPermission:
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(update.message ?? '', style: muted),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: notifier.downloadAndInstall,
              icon: const Icon(Icons.install_mobile, size: 18),
              label: const Text('Install'),
            ),
          ],
        );
      case UpdateStatus.installing:
        body = Text(
          'The installer is open. Tap "Update" there to finish; the app restarts on the new version.',
          style: muted,
        );
      case UpdateStatus.error:
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(update.message ?? 'Something went wrong.', style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              // A failed download can be retried directly; a failed check re-checks.
              onPressed: release != null ? notifier.downloadAndInstall : notifier.check,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ],
        );
      case UpdateStatus.idle:
      case UpdateStatus.upToDate:
        body = Row(
          children: [
            Expanded(
              child: Text(
                update.status == UpdateStatus.upToDate ? 'You\'re on the latest version.' : '',
                style: muted,
              ),
            ),
            OutlinedButton.icon(
              onPressed: notifier.check,
              icon: const Icon(Icons.system_update, size: 18),
              label: const Text('Check for updates'),
            ),
          ],
        );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 20),
                const SizedBox(width: 8),
                const Text('About & updates', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  version.when(data: (v) => 'v$v', loading: () => '', error: (_, _) => ''),
                  style: muted,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('CS2 Portfolio Manager', style: muted),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
      ],
    );
  }
}
