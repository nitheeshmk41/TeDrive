import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../app_lock.dart';
import '../device.dart' as device;
import '../drive_controller.dart';
import '../stored_file.dart';
import '../tedrive_service.dart';

import 'package:flutter/services.dart';

import '../config.dart';
import '../error_log.dart';
import '../updater.dart';

/// Who is signed in, what the drive holds, and how much of it is kept on
/// this device.
class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.service,
    required this.drive,
    required this.onLogOut,
    required this.onAbout,
  });

  final TeDriveService service;
  final DriveController drive;
  final VoidCallback onLogOut;
  final VoidCallback onAbout;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  String? _name;
  String? _phone;
  int? _cacheBytes;
  bool _clearing = false;
  bool _appLockEnabled = AppLockService.instance.isConfigured;

  Future<void> _setupPin() async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set 4-Digit App Lock PIN'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 4,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Enter 4-digit PIN',
            prefixIcon: Icon(Icons.pin),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().length == 4) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
    if (pin != null && pin.length == 4) {
      await AppLockService.instance.setPin(pin);
      if (mounted) {
        setState(() => _appLockEnabled = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('App Lock PIN enabled')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final me = await widget.service.me();
      final name = [
        me['first_name'],
        me['last_name'],
      ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
      final phone = me['phone_number'] as String? ?? '';
      final cache = await widget.service.cacheBytes();
      if (!mounted) return;
      setState(() {
        _name = name.isEmpty ? 'Telegram account' : name;
        _phone = phone.isEmpty ? null : '+$phone';
        _cacheBytes = cache;
      });
    } catch (_) {
      if (mounted) setState(() => _name = 'Telegram account');
    }
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final before = _cacheBytes ?? 0;
      await widget.drive.trimCache(0);
      final after = await widget.service.cacheBytes();
      if (!mounted) return;
      setState(() => _cacheBytes = after);
      final freed = before - (after ?? 0);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            freed > 0
                ? 'Freed ${formatBytes(freed)}. Your files are still in '
                      'Telegram.'
                : 'Nothing to clear.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  static const _categoryLabels = {
    Category.photos: ('Photos', Icons.image_outlined, Colors.teal),
    Category.videos: ('Videos', Icons.movie_outlined, Colors.deepPurple),
    Category.audio: ('Audio', Icons.audiotrack_outlined, Colors.orange),
    Category.documents: ('Documents', Icons.description_outlined, Colors.blue),
    Category.other: (
      'Other',
      Icons.insert_drive_file_outlined,
      Colors.blueGrey,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Account and storage')),
      body: ListenableBuilder(
        listenable: widget.drive,
        builder: (context, _) {
          final stats = DriveStats(widget.drive.files);
          final devices = stats.byDevice.entries.toList()
            ..sort((a, b) => b.value.bytes.compareTo(a.value.bytes));
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: CircleAvatar(
                        radius: 26,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        foregroundColor: theme.colorScheme.onPrimaryContainer,
                        child: Text(
                          (_name ?? '?').characters.first.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      title: Text(
                        _name ?? 'Loading…',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        [
                          ?_phone,
                          'This device: ${widget.service.deviceName}',
                        ].join('\n'),
                      ),
                      isThreeLine: _phone != null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatCard(
                          label: 'In your drive',
                          value: formatBytes(stats.bytes),
                          detail:
                              '${stats.count} file${stats.count == 1 ? '' : 's'}',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatCard(
                          label: 'Since',
                          value: stats.oldest == null
                              ? '-'
                              : formatDate(stats.oldest!).split(',').first,
                          detail: 'oldest file',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text('What is in it', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        children: [
                          for (final entry in _categoryLabels.entries)
                            _BreakdownRow(
                              icon: entry.value.$2,
                              color: entry.value.$3,
                              label: entry.value.$1,
                              count: stats.byCategory[entry.key]?.count ?? 0,
                              bytes: stats.byCategory[entry.key]?.bytes ?? 0,
                              total: stats.bytes,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (devices.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Uploaded from', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          children: [
                            for (final d in devices)
                              _BreakdownRow(
                                icon: Icons.devices_other_outlined,
                                color: theme.colorScheme.primary,
                                label: d.key,
                                count: d.value.count,
                                bytes: d.value.bytes,
                                total: stats.bytes,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text('On this device', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            kIsWeb
                                ? 'Kept in this browser'
                                : _cacheBytes == null
                                ? 'Checking…'
                                : '${formatBytes(_cacheBytes!)} of downloaded '
                                      'copies and previews',
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            kIsWeb
                                ? 'Files you open are kept in this browser\'s '
                                      'storage so they open quickly. Logging '
                                      'out removes them. Everything stays in '
                                      'Telegram.'
                                : 'Files you open are kept for a while so '
                                      'they open quickly. TeDrive keeps this '
                                      'under 1 GB by itself, and everything '
                                      'stays in Telegram.'
                                      '${device.isAndroid && stats.localCount > 0 ? '\n\n${stats.localCount} backed-up originals are also still in your gallery. Use Backup, then Free up space, to remove those.' : ''}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (!kIsWeb) const SizedBox(height: 12),
                          if (!kIsWeb)
                            OutlinedButton.icon(
                              onPressed: _clearing || (_cacheBytes ?? 0) == 0
                                  ? null
                                  : _clearCache,
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                              ),
                              label: Text(
                                _clearing ? 'Clearing…' : 'Clear downloads now',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Security and privacy',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        SwitchListTile(
                          secondary: const Icon(Icons.lock_outline),
                          title: const Text('App Lock (PIN)'),
                          subtitle: Text(
                            _appLockEnabled
                                ? 'App requires 4-digit PIN to open'
                                : 'Protect your drive with a PIN',
                          ),
                          value: _appLockEnabled,
                          onChanged: (on) async {
                            if (on) {
                              await _setupPin();
                            } else {
                              await AppLockService.instance.disable();
                              if (mounted)
                                setState(() => _appLockEnabled = false);
                            }
                          },
                        ),
                        if (_appLockEnabled)
                          ListTile(
                            leading: const SizedBox(width: 24),
                            title: const Text('Change PIN'),
                            onTap: _setupPin,
                          ),
                        if (_appLockEnabled)
                          FutureBuilder<bool>(
                            future: AppLockService.instance.canUseBiometric(),
                            builder: (context, snap) => snap.data != true
                                ? const SizedBox.shrink()
                                : SwitchListTile(
                                    secondary: const Icon(Icons.fingerprint),
                                    title: const Text(
                                      'Unlock with fingerprint',
                                    ),
                                    value: AppLockService
                                        .instance
                                        .biometricEnabled,
                                    onChanged: (on) async {
                                      await AppLockService.instance
                                          .setBiometric(on);
                                      if (mounted) setState(() {});
                                    },
                                  ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: const Text('About TeDrive'),
                          subtitle: const Text('Version $appVersion'),
                          onTap: widget.onAbout,
                        ),
                        if (!kIsWeb)
                          ListTile(
                            leading: const Icon(Icons.bug_report_outlined),
                            title: const Text('Copy error log'),
                            subtitle: const Text(
                              'To report a problem. Stays on this device.',
                            ),
                            onTap: () async {
                              final log = await readErrorLog();
                              await Clipboard.setData(
                                ClipboardData(
                                  text: log.isEmpty
                                      ? 'TeDrive v$appVersion: no errors logged'
                                      : 'TeDrive v$appVersion\n$log',
                                ),
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    log.isEmpty
                                        ? 'No errors have been logged'
                                        : 'Error log copied',
                                  ),
                                ),
                              );
                            },
                          ),
                        if (!kIsWeb)
                          ListTile(
                            leading: const Icon(Icons.system_update_outlined),
                            title: const Text('Check for updates'),
                            onTap: () => showUpdateDialog(context),
                          ),
                        ListTile(
                          leading: Icon(
                            Icons.logout,
                            color: theme.colorScheme.error,
                          ),
                          title: Text(
                            'Log out',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            widget.onLogOut();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(detail, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.count,
    required this.bytes,
    required this.total,
  });

  final IconData icon;
  final Color color;
  final String label;
  final int count;
  final int bytes;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '$count · ${formatBytes(bytes)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: total == 0 ? 0 : bytes / total,
                  color: color,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
