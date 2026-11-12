import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../backup_controller.dart';
import '../drive_controller.dart';
import '../stored_file.dart';
import '../tedrive_service.dart';
import 'backup_page.dart';
import 'gallery.dart';

/// The drive: file list, search, upload queue and per-file actions.
class DrivePage extends StatefulWidget {
  const DrivePage({super.key, required this.service});
  final TeDriveService service;

  @override
  State<DrivePage> createState() => _DrivePageState();
}

class _DrivePageState extends State<DrivePage> with WidgetsBindingObserver {
  late final DriveController _drive = DriveController(widget.service);
  late final BackupController _backup = BackupController(
    widget.service,
    _drive,
  );
  final _search = TextEditingController();
  bool _searching = false;
  bool _grid = true;
  Category _category = Category.all;
  String? _folder;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Backup compares the phone with the drive, so load the drive first.
    _drive.load().then((_) => _backup.init());
    widget.service.readSetting('view').then((v) {
      if (mounted && v == 'list') setState(() => _grid = false);
    });
  }

  void _toggleView() {
    setState(() => _grid = !_grid);
    widget.service.writeSetting('view', _grid ? 'grid' : 'list');
  }

  /// Images open in the built-in viewer; everything else in another app.
  void _tap(StoredFile file, List<StoredFile> shown) {
    if (file.kind != FileKind.image) {
      _open(file);
      return;
    }
    final images = shown.where((f) => f.kind == FileKind.image).toList();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImageViewerPage(
          drive: _drive,
          files: images,
          initialIndex: images.indexWhere((f) => f.messageId == file.messageId),
          onShare: _share,
          onMore: _showActions,
        ),
      ),
    );
  }

  Future<void> _move(StoredFile file) async {
    final choice = await showDialog<({String? folder})>(
      context: context,
      builder: (_) =>
          _FolderDialog(folders: _drive.folders, current: file.folder),
    );
    if (choice == null) return;
    await _guard(() async {
      await _drive.moveToFolder(file, choice.folder);
      final name = normalizeFolder(choice.folder);
      _toast(name == null ? 'Removed from its folder' : 'Moved to $name');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _backup.onResume();
  }

  void _openBackup() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => BackupPage(backup: _backup)),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backup.dispose();
    _drive.dispose();
    _search.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Runs a file action and reports any failure in a snackbar.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on DownloadCancelled {
      // The user asked for this.
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _pickAndUpload() async {
    final picked = await FilePicker.pickFiles();
    if (picked.isNotEmpty) _drive.enqueue(picked, folder: _folder);
  }

  Future<void> _open(StoredFile file) => _guard(() async {
    final path = await _drive.ensureLocal(file);
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      _toast(
        result.type == ResultType.noAppToOpen
            ? 'No app on this phone can open ${file.name}'
            : result.message,
      );
    }
  });

  Future<void> _share(StoredFile file) => _guard(() async {
    final path = await _drive.ensureLocal(file);
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  });

  Future<void> _keepOffline(StoredFile file) => _guard(() async {
    await _drive.ensureLocal(file);
    _toast('${file.name} is now available offline');
  });

  Future<void> _removeOffline(StoredFile file) => _guard(() async {
    await _drive.removeOffline(file);
    _toast('Freed ${formatBytes(file.size)} on this phone');
  });

  Future<void> _verify(StoredFile file) async {
    final go = await _confirm(
      title: 'Check this file?',
      body:
          'TeDrive will download a fresh copy (${formatBytes(file.size)}) '
          'from Telegram and compare it with the original\'s fingerprint.',
      action: 'Check',
    );
    if (!go) return;
    await _guard(() async {
      final ok = await _drive.verify(file);
      _toast(switch (ok) {
        true => '${file.name} is intact: identical to the original',
        false => 'WARNING: ${file.name} does not match the original',
        null => 'This file has no recorded fingerprint to check against',
      });
    });
  }

  Future<void> _delete(StoredFile file) async {
    final go = await _confirm(
      title: 'Delete ${file.name}?',
      body:
          'This removes the file from your Telegram storage channel. '
          'It cannot be undone.',
      action: 'Delete',
      destructive: true,
    );
    if (!go) return;
    await _guard(() async {
      await _drive.delete(file);
      _toast('Deleted ${file.name}');
    });
  }

  Future<void> _logOut() async {
    final go = await _confirm(
      title: 'Log out?',
      body:
          'Your files stay safe in Telegram. Copies downloaded to this '
          'phone are removed, and uploads in progress are stopped.',
      action: 'Log out',
    );
    if (go) await _guard(widget.service.logOut);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) async {
    final theme = Theme.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      )
                    : null,
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showActions(StoredFile original) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        // The sheet may be opened from a stale copy (e.g. the image viewer).
        final file = _drive.files.firstWhere(
          (f) => f.messageId == original.messageId,
          orElse: () => original,
        );
        void run(Future<void> Function(StoredFile) action) {
          Navigator.pop(sheet);
          action(file);
        }

        final offline = file.localPath != null;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: KindIcon(file.kind),
                  title: Text(file.name),
                  subtitle: Text(
                    '${formatBytes(file.size)} · ${formatDate(file.date)}'
                    '${file.folder == null ? '' : ' · ${file.folder}'}',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('Open'),
                  onTap: () => run(_open),
                ),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share or send'),
                  onTap: () => run(_share),
                ),
                ListTile(
                  leading: const Icon(Icons.drive_file_move_outlined),
                  title: const Text('Move to folder'),
                  onTap: () => run(_move),
                ),
                if (offline && widget.service.isCached(file.localPath!))
                  ListTile(
                    leading: const Icon(Icons.phonelink_erase_outlined),
                    title: const Text('Remove copy from this phone'),
                    subtitle: Text('Frees ${formatBytes(file.size)}'),
                    onTap: () => run(_removeOffline),
                  )
                else if (!offline)
                  ListTile(
                    leading: const Icon(Icons.download_for_offline_outlined),
                    title: const Text('Keep on this phone'),
                    onTap: () => run(_keepOffline),
                  ),
                if (file.sha256 != null) ...[
                  ListTile(
                    leading: const Icon(Icons.verified_outlined),
                    title: const Text('Check file integrity'),
                    onTap: () => run(_verify),
                  ),
                  ListTile(
                    leading: const Icon(Icons.fingerprint),
                    title: const Text('Copy SHA-256 fingerprint'),
                    subtitle: Text(
                      file.sha256!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      Clipboard.setData(ClipboardData(text: file.sha256!));
                      _toast('Fingerprint copied');
                    },
                  ),
                ],
                ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    'Delete from drive',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: () => run(_delete),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _drive,
      builder: (context, _) {
        // A folder disappears once its last file is moved out or deleted.
        if (_folder != null && !_drive.folders.contains(_folder)) {
          _folder = null;
        }
        final shown = filterFiles(
          _drive.files,
          category: _category,
          folder: _folder,
          query: _search.text,
        );
        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _search,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Search files',
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  )
                : Text(kIsWeb ? 'TeDrive (Web Preview)' : 'TeDrive'),
            actions: [
              IconButton(
                tooltip: _searching ? 'Close search' : 'Search',
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  _search.clear();
                }),
              ),
              IconButton(
                tooltip: 'Phone backup',
                icon: const Icon(Icons.backup_outlined),
                onPressed: _openBackup,
              ),
              IconButton(
                tooltip: _grid ? 'Show as list' : 'Show as grid',
                icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
                onPressed: _toggleView,
              ),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'refresh' ? _drive.load() : _logOut(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                  PopupMenuItem(value: 'logout', child: Text('Log out')),
                ],
              ),
            ],
            bottom: _drive.loading
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(4),
                    child: LinearProgressIndicator(),
                  )
                : null,
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _drive.error != null && _drive.files.isEmpty
                ? null
                : _pickAndUpload,
            icon: const Icon(Icons.upload),
            label: const Text('Upload'),
          ),
          body: RefreshIndicator(
            onRefresh: _drive.load,
            child: _body(context, shown),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, List<StoredFile> shown) {
    final theme = Theme.of(context);
    if (_drive.error != null && _drive.files.isEmpty) {
      return _Centered(
        icon: Icons.cloud_off,
        text: 'Could not load your drive.\n${_drive.error}',
        action: FilledButton(
          onPressed: _drive.load,
          child: const Text('Try again'),
        ),
      );
    }
    if (_drive.files.isEmpty && _drive.uploads.isEmpty) {
      return _drive.loading
          ? const _Centered(icon: Icons.cloud_sync, text: 'Loading your drive…')
          : const _Centered(
              icon: Icons.cloud_upload_outlined,
              text: 'Your drive is empty.\nTap Upload to add your first files.',
            );
    }
    final filtered =
        _category != Category.all ||
        _folder != null ||
        _search.text.trim().isNotEmpty;
    final top = [
      if (_drive.uploads.isNotEmpty) ...[
        _SectionHeader(
          'Uploads',
          trailing: _drive.uploads.any((t) => !t.isActive)
              ? TextButton(
                  onPressed: _drive.clearFinished,
                  child: const Text('Clear finished'),
                )
              : null,
        ),
        for (final task in _drive.uploads)
          _UploadTile(
            task: task,
            onCancel: () => _guard(() => _drive.cancel(task)),
            onRetry: () => _drive.retry(task),
          ),
        if (_drive.hasActiveUploads)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Uploads continue in the background. '
              'Do not swipe TeDrive away until they finish.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const Divider(height: 1),
      ],
      if (_drive.files.isNotEmpty)
        _FilterBar(
          category: _category,
          folder: _folder,
          folders: _drive.folders,
          onCategory: (c) => setState(() => _category = c),
          onFolder: (f) => setState(() => _folder = f),
        ),
      _SectionHeader(
        filtered
            ? '${shown.length} of ${_drive.files.length} files'
            : '${_drive.files.length} file${_drive.files.length == 1 ? '' : 's'}'
                  ' · ${formatBytes(_drive.totalBytes)}',
      ),
      if (shown.isEmpty && _drive.files.isNotEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Text('No files match.', textAlign: TextAlign.center),
        ),
    ];
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverList.list(children: top),
        if (_grid)
          ...gallerySlivers(
            context: context,
            drive: _drive,
            files: shown,
            onTap: (f) => _tap(f, shown),
            onLongPress: _showActions,
          )
        else
          SliverList.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final file = shown[i];
              return _FileTile(
                key: ValueKey(file.messageId),
                drive: _drive,
                file: file,
                downloading: _drive.isDownloading(file),
                progress: _drive.downloads[file.messageId],
                onTap: () => _tap(file, shown),
                onMore: () => _showActions(file),
                onCancel: () => _guard(() => _drive.cancelDownload(file)),
              );
            },
          ),
        // Room for the Upload button.
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }
}

/// Category chips, then one chip per folder.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.category,
    required this.folder,
    required this.folders,
    required this.onCategory,
    required this.onFolder,
  });

  final Category category;
  final String? folder;
  final List<String> folders;
  final ValueChanged<Category> onCategory;
  final ValueChanged<String?> onFolder;

  static const _labels = {
    Category.all: 'All',
    Category.photos: 'Photos',
    Category.videos: 'Videos',
    Category.audio: 'Audio',
    Category.documents: 'Documents',
    Category.other: 'Other',
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          for (final c in Category.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(_labels[c]!),
                selected: category == c,
                onSelected: (_) => onCategory(c),
              ),
            ),
          for (final name in folders)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                avatar: const Icon(Icons.folder_outlined, size: 18),
                label: Text(name),
                selected: folder == name,
                onSelected: (on) => onFolder(on ? name : null),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pick an existing folder, type a new one, or choose none.
class _FolderDialog extends StatefulWidget {
  const _FolderDialog({required this.folders, required this.current});
  final List<String> folders;
  final String? current;

  @override
  State<_FolderDialog> createState() => _FolderDialogState();
}

class _FolderDialogState extends State<_FolderDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _choose(String? folder) => Navigator.pop(context, (folder: folder));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move to folder'),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: TextField(
                controller: _name,
                maxLength: 40,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'New folder name',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Create folder and move',
                    icon: const Icon(Icons.check),
                    onPressed: () {
                      if (normalizeFolder(_name.text) != null) {
                        _choose(_name.text);
                      }
                    },
                  ),
                ),
                onSubmitted: (v) {
                  if (normalizeFolder(v) != null) _choose(v);
                },
              ),
            ),
            for (final name in widget.folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(name),
                trailing: name == widget.current
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => _choose(name),
              ),
            if (widget.current != null)
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('No folder'),
                onTap: () => _choose(null),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
        SizedBox(height: 40, child: trailing),
      ],
    ),
  );
}

class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    // Scrollable so pull-to-refresh works on empty and error states.
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(text, textAlign: TextAlign.center),
                  if (action != null) ...[const SizedBox(height: 16), action!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    super.key,
    required this.drive,
    required this.file,
    required this.downloading,
    required this.progress,
    required this.onTap,
    required this.onMore,
    required this.onCancel,
  });

  final DriveController drive;
  final StoredFile file;
  final bool downloading;
  final double? progress;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: file.kind == FileKind.image || file.kind == FileKind.video
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.square(
                dimension: 40,
                child: FileThumb(
                  drive: drive,
                  file: file,
                  fallback: KindIcon(file.kind),
                ),
              ),
            )
          : KindIcon(file.kind),
      title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: downloading
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 4),
                Text(
                  progress == null
                      ? 'Downloading…'
                      : 'Downloading ${(progress! * 100).round()}% of '
                            '${formatBytes(file.size)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            )
          : Row(
              children: [
                Flexible(
                  child: Text(
                    '${formatBytes(file.size)} · ${formatDate(file.date)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (file.localPath != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.offline_pin,
                    size: 16,
                    color: theme.colorScheme.primary,
                    semanticLabel: 'On this phone',
                  ),
                ],
              ],
            ),
      trailing: downloading
          ? IconButton(
              tooltip: 'Cancel download',
              icon: const Icon(Icons.close),
              onPressed: onCancel,
            )
          : IconButton(
              tooltip: 'More actions',
              icon: const Icon(Icons.more_vert),
              onPressed: onMore,
            ),
      onTap: downloading ? null : onTap,
      onLongPress: downloading ? null : onMore,
    );
  }
}

class _UploadTile extends StatelessWidget {
  const _UploadTile({
    required this.task,
    required this.onCancel,
    required this.onRetry,
  });

  final UploadTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = task.progress == null
        ? ''
        : ' ${(task.progress! * 100).round()}%';
    final (label, icon, color) = switch (task.status) {
      UploadStatus.queued => ('Waiting', Icons.schedule, null),
      UploadStatus.preparing => ('Preparing$percent', Icons.sync, null),
      UploadStatus.uploading => ('Uploading$percent', Icons.upload, null),
      UploadStatus.done => ('Uploaded', Icons.check_circle, Colors.green),
      UploadStatus.skipped => (
        task.message ?? 'Skipped',
        Icons.info_outline,
        null,
      ),
      UploadStatus.failed => (
        task.message ?? 'Failed',
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      UploadStatus.cancelled => ('Cancelled', Icons.cancel_outlined, null),
    };
    final size = task.size == null ? '' : '${formatBytes(task.size!)} · ';
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(task.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$size$label',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
          if (task.status == UploadStatus.preparing ||
              task.status == UploadStatus.uploading) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: task.progress),
          ],
        ],
      ),
      trailing: task.isActive
          ? IconButton(
              tooltip: 'Cancel upload',
              icon: const Icon(Icons.close),
              onPressed: onCancel,
            )
          : task.status == UploadStatus.failed ||
                task.status == UploadStatus.cancelled
          ? IconButton(
              tooltip: 'Try again',
              icon: const Icon(Icons.refresh),
              onPressed: onRetry,
            )
          : null,
    );
  }
}
