import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../device.dart' as device;
import '../drive_controller.dart';
import '../stored_file.dart';
import '../wifi_transfer.dart';

/// Wi-Fi transfer: shows how to connect, who is connected and every file
/// going in or out. The server runs only while this page is open.
class WifiTransferPage extends StatefulWidget {
  const WifiTransferPage({super.key, required this.drive});
  final DriveController drive;

  @override
  State<WifiTransferPage> createState() => _WifiTransferPageState();
}

class _WifiTransferPageState extends State<WifiTransferPage> {
  final _service = WifiTransferService.instance;
  StreamSubscription<void>? _changes;
  StreamSubscription<File>? _received;
  Timer? _tick;
  String? _error;
  bool _starting = true;
  bool _addToDrive = true;

  @override
  void initState() {
    super.initState();
    _changes = _service.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _received = _service.onFileReceived.listen(_onReceived);
    // "Connected" fades by itself when the other device goes away.
    _tick = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
    _start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _changes?.cancel();
    _received?.cancel();
    _service.stop();
    super.dispose();
  }

  List<WifiFile> _offered() => [
    for (final c in widget.drive.onThisDevice)
      if (!c.file.isVault && !c.file.inTrash)
        (
          name: c.file.name,
          size: c.file.size,
          path: c.path,
          thumb: widget.drive.thumbPathOf(c.file),
        ),
  ];

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final base = device.isAndroid
          ? await getTemporaryDirectory()
          : (await getDownloadsDirectory() ?? await getTemporaryDirectory());
      await _service.start(
        files: _offered,
        uploadDir: Directory(
          '${base.path}${Platform.pathSeparator}'
          '${device.isAndroid ? 'wifi_received' : 'TeDrive received'}',
        ),
        deviceName: await device.deviceName(),
      );
    } catch (e) {
      _error = e is StateError ? e.message : '$e';
    }
    if (mounted) setState(() => _starting = false);
  }

  void _onReceived(File file) {
    if (!_addToDrive) return;
    widget.drive.enqueuePath(
      file.path,
      name: file.uri.pathSegments.last,
      size: file.lengthSync(),
      fromBackup: false,
      // On a phone the copy sits in the cache and is removed after upload.
      deleteAfter: device.isAndroid,
    );
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final url = _service.url;
    final Widget body;
    if (_starting) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null || url == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off, size: 56, color: scheme.error),
              const SizedBox(height: 16),
              Text(
                _error ?? 'Wi-Fi transfer could not start.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _start, child: const Text('Try again')),
            ],
          ),
        ),
      );
    } else {
      body = LayoutBuilder(
        builder: (context, box) {
          final connect = _ConnectCard(
            service: _service,
            onCopyAddress: () => _copy(_service.shortUrl!, 'Address'),
          );
          final activity = _ActivityCard(
            service: _service,
            offered: _offered().length,
            addToDrive: _addToDrive,
            onAddToDrive: (v) => setState(() => _addToDrive = v),
          );
          if (box.maxWidth >= 860) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 380,
                    child: SingleChildScrollView(child: connect),
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: SingleChildScrollView(child: activity)),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [connect, const SizedBox(height: 16), activity],
          );
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi transfer'),
        actions: [
          if (!_starting && _error == null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                avatar: Icon(
                  Icons.circle,
                  size: 12,
                  color: _service.connected ? Colors.green : scheme.outline,
                ),
                label: Text(
                  _service.connected ? 'Device connected' : 'Waiting',
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({required this.service, required this.onCopyAddress});
  final WifiTransferService service;
  final VoidCallback onCopyAddress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text('Connect another device', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Both devices must be on the same Wi-Fi or hotspot.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: QrImageView(
                data: service.url!,
                size: 200,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Phone: scan with the camera',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 32),
            Text(
              'Computer: open this address in a browser',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onCopyAddress,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        service.shortUrl!.replaceFirst('http://', ''),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(Icons.copy, size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('then enter this code', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final digit in service.code.split(''))
                  Container(
                    width: 38,
                    height: 48,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      digit,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Only devices with the code can connect. It changes '
                    'every time, and transfer stops when you leave this page.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.service,
    required this.offered,
    required this.addToDrive,
    required this.onAddToDrive,
  });
  final WifiTransferService service;
  final int offered;
  final bool addToDrive;
  final ValueChanged<bool> onAddToDrive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = service.activity;
    final sent = items
        .where((a) => a.direction == WifiDirection.sent && a.finished)
        .length;
    final received = items
        .where((a) => a.direction == WifiDirection.received && a.finished)
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Stat(label: 'Offered', value: '$offered'),
                _Stat(label: 'Sent', value: '$sent'),
                _Stat(label: 'Received', value: '$received'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              offered == 0
                  ? 'No files are on this device yet. Download a file in '
                        'TeDrive and it can be picked up from here. The '
                        'other device can still send files to you.'
                  : 'The other device can take any of the $offered files '
                        'kept on this device, and send files to you.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Add received files to my drive'),
              subtitle: Text(
                device.isAndroid
                    ? 'They are uploaded to your Telegram storage'
                    : 'Also saved in Downloads › TeDrive received',
              ),
              value: addToDrive,
              onChanged: onAddToDrive,
            ),
            const Divider(),
            Text('Activity', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Transfers will appear here',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              for (final a in items.take(50)) _ActivityRow(a),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow(this.a);
  final WifiActivity a;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sent = a.direction == WifiDirection.sent;
    final status = a.failed
        ? 'Stopped'
        : a.finished
        ? (sent ? 'Sent' : 'Received')
        : '${(a.progress * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: sent
                ? scheme.primaryContainer
                : scheme.tertiaryContainer,
            child: Icon(
              sent ? Icons.arrow_upward : Icons.arrow_downward,
              size: 16,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                if (!a.finished && !a.failed)
                  LinearProgressIndicator(
                    value: a.total > 0 ? a.progress : null,
                    borderRadius: BorderRadius.circular(3),
                  )
                else
                  Text(
                    formatBytes(a.total > 0 ? a.total : a.done),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            status,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: a.failed
                  ? scheme.error
                  : a.finished
                  ? Colors.green
                  : scheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
