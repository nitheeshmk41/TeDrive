import 'package:flutter/material.dart';

import '../backup_controller.dart';
import '../backup_plan.dart';
import '../stored_file.dart' show formatBytes;

/// Phone backup settings, progress, and "free up space". Shown as the body
/// of the Backup tab.
class BackupBody extends StatelessWidget {
  const BackupBody({super.key, required this.backup});
  final BackupController backup;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: backup,
    builder: (context, _) => Column(
      children: [
        if (backup.scanning) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: backup.hasPermission
              ? _Content(backup: backup)
              : _PermissionRequest(backup: backup),
        ),
      ],
    ),
  );
}

class _PermissionRequest extends StatelessWidget {
  const _PermissionRequest({required this.backup});
  final BackupController backup;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const Text(
              'To back up your photos and videos, TeDrive needs permission '
              'to read them. They are sent only to your own Telegram channel.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: backup.requestPermission,
              child: const Text('Allow access'),
            ),
            const SizedBox(height: 8),
            Text(
              'If nothing happens, allow "Photos and videos" for TeDrive in '
              'the phone\'s Settings, under Apps.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.backup});
  final BackupController backup;

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _freeUpSpace(BuildContext context) async {
    final items = backup.freeableItems;
    final bytes = items.fold(0, (sum, i) => sum + i.size);
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Free up space?'),
        content: Text(
          '${items.length} photos and videos (${formatBytes(bytes)}) are '
          'already in your drive and will be deleted from this phone.\n\n'
          'TeDrive first asks Telegram to confirm each file is still in '
          'your channel with the same fingerprint and size. They stay '
          'available in TeDrive, but need internet to open.\n\n'
          'Your phone will ask you to confirm the deletion.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    try {
      final result = await backup.freeUpSpace();
      if (!context.mounted) return;
      _toast(
        context,
        result.count == 0
            ? 'Nothing was deleted'
            : 'Deleted ${result.count} items and freed '
                  '${formatBytes(result.bytes)}',
      );
    } catch (e) {
      if (context.mounted) _toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = backup.pending;
    final pendingBytes = pending.fold(0, (sum, i) => sum + i.size);
    final selected = backup.selectedCount;
    final freeable = backup.freeableItems;
    final freeableBytes = freeable.fold(0, (sum, i) => sum + i.size);
    final settings = backup.settings;

    final String headline;
    if (backup.running) {
      headline = backup.runTotal == 0
          ? 'Checking your photos…'
          : 'Backing up ${backup.runDone + 1 > backup.runTotal ? backup.runTotal : backup.runDone + 1} '
                'of ${backup.runTotal}';
    } else if (selected == 0) {
      headline = 'Choose albums to back up';
    } else if (pending.isEmpty) {
      headline = 'All $selected items are backed up';
    } else {
      headline =
          '${pending.length} of $selected items to back up '
          '(${formatBytes(pendingBytes)})';
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (backup.permission == 'partial')
          const _Banner(
            icon: Icons.info_outline,
            text:
                'TeDrive can only see the photos you selected. To back up '
                'everything, allow access to all photos in the phone\'s '
                'Settings.',
          ),
        Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      pending.isEmpty && !backup.running && selected > 0
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_upload_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(headline, style: theme.textTheme.titleMedium),
                    ),
                  ],
                ),
                if (backup.running) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: backup.runTotal == 0
                        ? null
                        : backup.runDone / backup.runTotal,
                  ),
                ],
                if (backup.notice != null) ...[
                  const SizedBox(height: 8),
                  Text(backup.notice!, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 12),
                if (backup.running)
                  OutlinedButton.icon(
                    onPressed: backup.stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  )
                else
                  FilledButton.icon(
                    onPressed: pending.isEmpty ? null : backup.run,
                    icon: const Icon(Icons.backup_outlined),
                    label: const Text('Back up now'),
                  ),
              ],
            ),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.autorenew),
          title: const Text('Back up automatically'),
          subtitle: const Text(
            'New photos and videos are uploaded whenever TeDrive is open '
            'or running in the background.',
          ),
          value: settings.auto,
          onChanged: backup.setAuto,
        ),
        if (settings.auto)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<BackupFrequency>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: BackupFrequency.instant,
                      label: Text('Instantly'),
                    ),
                    ButtonSegment(
                      value: BackupFrequency.daily,
                      label: Text('Daily'),
                    ),
                    ButtonSegment(
                      value: BackupFrequency.weekly,
                      label: Text('Weekly'),
                    ),
                  ],
                  selected: {settings.frequency},
                  onSelectionChanged: (s) => backup.setFrequency(s.first),
                ),
                const SizedBox(height: 6),
                Text(switch (settings.frequency) {
                  BackupFrequency.instant =>
                    'Uploads as soon as new photos appear.',
                  BackupFrequency.daily =>
                    'Backs up once a day. If TeDrive is closed at 9 pm, '
                        'a notification offers to back up with one tap.',
                  BackupFrequency.weekly =>
                    'Backs up once a week. If TeDrive is closed at 9 pm, '
                        'a notification offers to back up with one tap.',
                }, style: theme.textTheme.bodySmall),
                if (backup.lastRun != null)
                  Text(
                    'Last backup: ${describeWhen(backup.lastRun!, DateTime.now())}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.wifi),
          title: const Text('Only on Wi-Fi'),
          subtitle: const Text('Do not use mobile data for backup.'),
          value: settings.unmeteredOnly,
          onChanged: backup.setUnmeteredOnly,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.battery_charging_full),
          title: const Text('Only while charging'),
          value: settings.chargingOnly,
          onChanged: backup.setChargingOnly,
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Albums to back up', style: theme.textTheme.titleSmall),
        ),
        if (backup.albums.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No photos or videos were found on this phone.'),
          ),
        for (final AlbumInfo album in backup.albums)
          CheckboxListTile(
            value: backup.selectedAlbums.contains(album.name),
            onChanged: backup.running
                ? null
                : (on) => backup.setAlbum(album.name, on ?? false),
            title: Text(album.name),
            subtitle: Text(
              '${album.count} items · ${formatBytes(album.bytes)}',
            ),
          ),
        const Divider(),
        Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.cleaning_services_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Free up space',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  freeable.isEmpty
                      ? 'Photos and videos can be removed from the phone '
                            'once they are backed up. Nothing is ready yet.'
                      : '${freeable.length} backed-up photos and videos are '
                            'still using ${formatBytes(freeableBytes)} on '
                            'this phone.',
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: freeable.isEmpty || backup.running
                      ? null
                      : () => _freeUpSpace(context),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(
                    freeable.isEmpty
                        ? 'Free up space'
                        : 'Free up ${formatBytes(freeableBytes)}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(icon, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
