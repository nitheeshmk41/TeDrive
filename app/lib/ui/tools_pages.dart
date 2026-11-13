// "Find duplicates" and "Export everything".

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../device.dart' as device;
import '../drive_controller.dart';
import '../stored_file.dart';

// ---------------------------------------------------------------- Duplicates

/// Files stored more than once, with a button to move the extra copies to
/// the trash (from where they can still be restored).
class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key, required this.drive});
  final DriveController drive;

  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  bool _busy = false;

  Future<void> _trash(List<List<StoredFile>> groups) async {
    final extra = [for (final g in groups) ...g.skip(1)];
    if (extra.isEmpty) return;
    final bytes = extra.fold<int>(0, (s, f) => s + f.size);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          extra.length == 1
              ? 'Move 1 extra copy to the trash?'
              : 'Move ${extra.length} extra copies to the trash?',
        ),
        content: Text(
          'The oldest copy of each file stays. ${formatBytes(bytes)} of '
          'copies go to the trash, where you can still restore them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final moved = await widget.drive.moveToTrash(extra);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            moved == 1
                ? 'Moved 1 copy to the trash'
                : 'Moved $moved copies to the trash',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not move them: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.drive,
      builder: (context, _) {
        final groups = findDuplicates(widget.drive.files);
        final extra = groups.fold<int>(0, (s, g) => s + g.length - 1);
        final bytes = groups.fold<int>(
          0,
          (s, g) => s + g.first.size * (g.length - 1),
        );
        return Scaffold(
          appBar: AppBar(title: const Text('Duplicates')),
          bottomNavigationBar: groups.isEmpty
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _trash(groups),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_sweep_outlined),
                      label: Text(
                        'Move $extra extra ${extra == 1 ? 'copy' : 'copies'} '
                        'to trash (${formatBytes(bytes)})',
                      ),
                    ),
                  ),
                ),
          body: groups.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 56,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No duplicates',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Every file in your drive is stored once.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: groups.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          '${groups.length} ${groups.length == 1 ? 'file is' : 'files are'} '
                          'stored more than once. The extra copies use '
                          '${formatBytes(bytes)}. The oldest copy is kept.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      );
                    }
                    final g = groups[i - 1];
                    return _DuplicateTile(
                      drive: widget.drive,
                      group: g,
                      onTrash: _busy ? null : () => _trash([g]),
                    );
                  },
                ),
        );
      },
    );
  }
}

class _DuplicateTile extends StatelessWidget {
  const _DuplicateTile({
    required this.drive,
    required this.group,
    required this.onTrash,
  });
  final DriveController drive;
  final List<StoredFile> group;
  final VoidCallback? onTrash;

  @override
  Widget build(BuildContext context) {
    final first = group.first;
    final where = {
      for (final f in group)
        f.folder == null ? 'Files' : folderBaseName(f.folder!),
    }.join(', ');
    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: FutureBuilder<String?>(
            future: drive.thumbnail(first),
            builder: (context, snap) => snap.data == null
                ? ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: const Icon(Icons.insert_drive_file_outlined),
                  )
                : Image.file(File(snap.data!), fit: BoxFit.cover),
          ),
        ),
      ),
      title: Text(first.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${group.length} copies · ${formatBytes(first.size)} each · $where',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Move the extra copies to trash',
        icon: const Icon(Icons.delete_outline),
        onPressed: onTrash,
      ),
    );
  }
}

// ---------------------------------------------------------------- Export

/// Downloads every file of the drive and packs it into .zip parts saved on
/// this device, so the user always has a copy outside Telegram.
class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.drive});
  final DriveController drive;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  static const _gb = 1024 * 1024 * 1024;
  int _partBytes = _gb;

  bool _running = false;
  bool _cancel = false;
  bool _finished = false;
  int _part = 0;
  int _parts = 0;
  int _doneBytes = 0;
  int _totalBytes = 0;
  String _current = '';
  StoredFile? _currentFile;
  final List<String> _saved = [];
  final List<String> _failed = [];

  List<StoredFile> get _files {
    final files = [
      for (final f in widget.drive.files)
        if (!f.isVault) f,
    ];
    // Oldest first, so the parts read like a timeline.
    files.sort((a, b) => a.date.compareTo(b.date));
    return files;
  }

  Future<void> _start() async {
    final files = _files;
    if (files.isEmpty) return;
    String? targetDir;
    if (device.isDesktop) {
      targetDir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Save the export to…',
      );
      if (targetDir == null) return;
    }
    final parts = splitIntoParts(files, _partBytes);
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    setState(() {
      _running = true;
      _cancel = false;
      _finished = false;
      _parts = parts.length;
      _doneBytes = 0;
      _totalBytes = files.fold(0, (s, f) => s + f.size);
      _saved.clear();
      _failed.clear();
    });
    final tmp = await getTemporaryDirectory();
    for (var p = 0; p < parts.length && !_cancel; p++) {
      setState(() => _part = p + 1);
      final zipName = parts.length == 1
          ? 'TeDrive-export-$stamp.zip'
          : 'TeDrive-export-$stamp-part${p + 1}-of-${parts.length}.zip';
      final zipPath = '${tmp.path}/$zipName';
      final old = File(zipPath);
      if (old.existsSync()) old.deleteSync();
      final encoder = ZipFileEncoder()..create(zipPath);
      final downloadedHere = <StoredFile>[];
      final used = <String>{};
      var packed = 0;
      for (final f in parts[p]) {
        if (_cancel) break;
        setState(() {
          _current = f.name;
          _currentFile = f;
        });
        try {
          final wasLocal = widget.drive.localCopyOf(f) != null;
          final local = await widget.drive.ensureLocal(f);
          if (!wasLocal) downloadedHere.add(f);
          final folder = f.folder == null
              ? ''
              : '${f.folder!.split('/').map(safeFileName).join('/')}/';
          var name = '$folder${safeFileName(f.name)}';
          for (var n = 2; !used.add(name.toLowerCase()); n++) {
            name = '$folder($n) ${safeFileName(f.name)}';
          }
          await encoder.addFile(File(local), name, ZipFileEncoder.store);
          packed++;
        } catch (_) {
          if (!_cancel) _failed.add(f.name);
        }
        if (mounted) setState(() => _doneBytes += f.size);
      }
      await encoder.close();
      if (packed > 0 && !_cancel) {
        String? where;
        try {
          if (targetDir != null) {
            await File(zipPath)
                .copy('$targetDir${Platform.pathSeparator}$zipName');
            where = '$targetDir${Platform.pathSeparator}$zipName';
          } else {
            where = await device.saveToDownloads(
              zipPath,
              name: zipName,
              mime: 'application/zip',
              folder: 'TeDrive Export',
            );
          }
        } catch (_) {
          where = null;
        }
        if (where != null) {
          _saved.add(where);
        } else {
          _failed.add('$zipName (could not be saved: is the phone full?)');
        }
      }
      // Free the space again before the next part.
      try {
        File(zipPath).deleteSync();
      } catch (_) {}
      for (final f in downloadedHere) {
        try {
          await widget.drive.removeOffline(f);
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _finished = !_cancel;
      _currentFile = null;
    });
  }

  Future<void> _stop() async {
    setState(() => _cancel = true);
    final f = _currentFile;
    if (f != null) {
      try {
        await widget.drive.cancelDownload(f);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = _files;
    final total = files.fold<int>(0, (s, f) => s + f.size);
    final vaulted = widget.drive.files.where((f) => f.isVault).length;
    final whereTo = device.isAndroid
        ? 'Downloads/TeDrive Export on this phone'
        : 'a folder you choose';
    final Widget body;
    if (_running) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _cancel ? 'Stopping…' : 'Part $_part of $_parts',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: _totalBytes == 0 ? null : _doneBytes / _totalBytes,
          ),
          const SizedBox(height: 8),
          Text(
            '${formatBytes(_doneBytes)} of ${formatBytes(_totalBytes)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            _current,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          const Text(
            'Keep TeDrive open until it finishes. Each part is saved as soon '
            'as it is ready, so nothing is lost if you stop.',
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _cancel ? null : _stop,
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
          ),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${files.length} files · ${formatBytes(total)}',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Every file is downloaded from Telegram and packed into .zip '
            'files with your folders kept, saved to $whereTo. Each part is '
            'saved and its downloads cleared before the next one starts, so '
            'you need about twice the part size free.'
            '${vaulted > 0 ? '\n\nThe $vaulted files in your vault are not included.' : ''}',
          ),
          const SizedBox(height: 16),
          Text('Size of each part', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _gb ~/ 2, label: Text('500 MB')),
              ButtonSegment(value: _gb, label: Text('1 GB')),
              ButtonSegment(value: 2 * _gb, label: Text('2 GB')),
            ],
            selected: {_partBytes},
            onSelectionChanged: (s) => setState(() => _partBytes = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            'That makes ${splitIntoParts(files, _partBytes).length} part(s).',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: files.isEmpty ? null : _start,
            icon: const Icon(Icons.download_outlined),
            label: Text(
              _finished || _saved.isNotEmpty ? 'Export again' : 'Start export',
            ),
          ),
          if (_saved.isNotEmpty || _failed.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              _finished ? 'Export finished' : 'Export stopped',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final s in _saved)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_zip_outlined),
                title: Text(s),
              ),
            if (_failed.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${_failed.length} could not be exported:',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              for (final f in _failed.take(20))
                Text('• $f', style: theme.textTheme.bodySmall),
              if (_failed.length > 20)
                Text(
                  '…and ${_failed.length - 20} more',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ],
        ],
      );
    }
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Stop the export first')),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Export everything')),
        body: ListView(padding: const EdgeInsets.all(16), children: [body]),
      ),
    );
  }
}
