import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../backup_controller.dart';
import '../device.dart' as device;
import '../drive_controller.dart';
import '../stored_file.dart';
import '../tedrive_service.dart';
import 'backup_page.dart';
import 'gallery.dart';
import 'player_page.dart';
import 'theme.dart';

enum _Tab { photos, albums, files, backup }

enum _Sort { newest, oldest, largest, name }

/// The signed-in app: Photos, Albums, Files and (on Android) Backup.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.service});
  final TeDriveService service;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final DriveController _drive = DriveController(widget.service);
  late final BackupController _backup = BackupController(
    widget.service,
    _drive,
  );
  final _search = TextEditingController();
  _Tab _tab = _Tab.photos;
  Category _category = Category.all;
  _Sort _sort = _Sort.newest;

  bool get _hasBackup => device.isAndroid;
  String get _query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Backup compares the phone with the drive, so load the drive first.
    _drive.load().then((_) {
      if (mounted && _hasBackup) _backup.init();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasBackup) _backup.onResume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backup.dispose();
    _drive.dispose();
    _search.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ Helpers

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
      _toast(e is StateError ? e.message : '$e');
    }
  }

  bool _demoBlocks() {
    if (!_drive.isDemo) return false;
    _toast('This is a demo with sample files, so there is nothing to open.');
    return true;
  }

  /// Returns a local path for [file]. If it has to be downloaded first, a
  /// progress dialog with a Cancel button is shown meanwhile. Null if the
  /// download was cancelled or failed.
  Future<String?> _fetch(StoredFile original, String verb) async {
    if (_demoBlocks()) return null;
    final file = _latest(original);
    final local = file.localPath;
    if (local != null && File(local).existsSync()) return local;
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(
        drive: _drive,
        file: file,
        verb: verb,
        onCancel: () => _drive.cancelDownload(file),
      ),
    ).then((_) => dialogOpen = false);
    try {
      return await _drive.ensureLocal(file);
    } on DownloadCancelled {
      return null;
    } catch (e) {
      _toast('Could not download ${file.name}: $e');
      return null;
    } finally {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  StoredFile _latest(StoredFile file) => _drive.files.firstWhere(
    (f) => f.messageId == file.messageId,
    orElse: () => file,
  );

  // ------------------------------------------------------------ Actions

  Future<void> _pickAndUpload({String? folder}) async {
    if (_drive.isDemo) {
      _toast('Uploading needs the Android app and your own Telegram account.');
      return;
    }
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    _drive.enqueue(picked, folder: folder);
    _toast(
      picked.length == 1
          ? 'Uploading ${picked.first.name}'
          : 'Uploading ${picked.length} files',
    );
  }

  /// Opens a file: images, videos and audio inside the app, anything else
  /// in whichever app handles it.
  void _open(StoredFile file, List<StoredFile> siblings) {
    if (_demoBlocks()) return;
    switch (file.kind) {
      case FileKind.image:
        final images = siblings.where((f) => f.kind == FileKind.image).toList();
        final index = images.indexWhere((f) => f.messageId == file.messageId);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ImageViewerPage(
              drive: _drive,
              files: images,
              initialIndex: index < 0 ? 0 : index,
              onShare: _share,
              onMore: _showActions,
            ),
          ),
        );
      case FileKind.video || FileKind.audio:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlayerPage(
              drive: _drive,
              file: _latest(file),
              onShare: _share,
              onMore: _showActions,
              onOpenElsewhere: _openElsewhere,
            ),
          ),
        );
      default:
        _openElsewhere(file);
    }
  }

  Future<void> _openElsewhere(StoredFile file) => _guard(() async {
    final path = await _fetch(file, 'Opening');
    if (path == null) return;
    final mime = mimeOf(file.name);
    if (device.isAndroid) {
      if (!await device.openFile(path, mime: mime)) {
        _toast('No app on this phone can open ${file.name}');
      }
    } else {
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done) _toast(result.message);
    }
  });

  Future<void> _share(StoredFile file) => _guard(() async {
    final path = await _fetch(file, 'Preparing');
    if (path == null) return;
    final mime = mimeOf(file.name);
    if (!await device.shareFile(path, mime: mime)) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path, mimeType: mime)]),
      );
    }
  });

  Future<void> _keepOffline(StoredFile file) => _guard(() async {
    if (await _fetch(file, 'Downloading') != null) {
      _toast('${file.name} is now on this device');
    }
  });

  Future<void> _removeOffline(StoredFile file) => _guard(() async {
    await _drive.removeOffline(file);
    _toast('Freed ${formatBytes(file.size)} on this device');
  });

  Future<void> _verify(StoredFile file) async {
    if (_demoBlocks()) return;
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
          'This removes the file from your drive on every device. '
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

  Future<void> _move(StoredFile file) async {
    final choice = await showDialog<({String? folder})>(
      context: context,
      builder: (_) =>
          _AlbumDialog(albums: _drive.folders, current: file.folder),
    );
    if (choice == null) return;
    await _guard(() async {
      await _drive.moveToFolder(file, choice.folder);
      final name = normalizeFolder(choice.folder);
      _toast(name == null ? 'Removed from its album' : 'Moved to $name');
    });
  }

  Future<void> _logOut() async {
    final go = await _confirm(
      title: 'Log out?',
      body:
          'Your files stay safe in Telegram. Copies downloaded to this '
          'device are removed, and uploads in progress are stopped.',
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
    final scheme = Theme.of(context).colorScheme;
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
                style: FilledButton.styleFrom(
                  minimumSize: const Size(64, 40),
                  backgroundColor: destructive ? scheme.error : null,
                  foregroundColor: destructive ? scheme.onError : null,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showDetails(StoredFile file) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Details'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Detail('Name', file.name),
              _Detail('Size', formatBytes(file.size)),
              _Detail(
                file.taken == null ? 'Uploaded' : 'Taken',
                formatDate(file.date),
              ),
              _Detail('Album', file.folder ?? 'None'),
              _Detail('Uploaded from', file.device ?? 'Unknown device'),
              _Detail(
                'On this device',
                file.localPath == null ? 'No, stored in Telegram only' : 'Yes',
              ),
              if (file.sha256 != null)
                _Detail('SHA-256 fingerprint', file.sha256!, mono: true),
            ],
          ),
        ),
        actions: [
          if (file.sha256 != null)
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: file.sha256!));
                Navigator.pop(context);
                _toast('Fingerprint copied');
              },
              child: const Text('Copy fingerprint'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showActions(StoredFile original) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        final file = _latest(original);
        final error = Theme.of(context).colorScheme.error;
        void run(void Function(StoredFile) action) {
          Navigator.pop(sheet);
          action(file);
        }

        final local = file.localPath;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: _Leading(drive: _drive, file: file),
                  title: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_subtitle(file)),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share or send'),
                  onTap: () => run(_share),
                ),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('Open in another app'),
                  onTap: () => run(_openElsewhere),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_album_outlined),
                  title: const Text('Move to album'),
                  onTap: () => run(_move),
                ),
                if (local != null && widget.service.isCached(local))
                  ListTile(
                    leading: const Icon(Icons.phonelink_erase_outlined),
                    title: const Text('Remove copy from this device'),
                    subtitle: Text('Frees ${formatBytes(file.size)}'),
                    onTap: () => run(_removeOffline),
                  )
                else if (local == null)
                  ListTile(
                    leading: const Icon(Icons.download_for_offline_outlined),
                    title: const Text('Keep on this device'),
                    onTap: () => run(_keepOffline),
                  ),
                if (file.sha256 != null)
                  ListTile(
                    leading: const Icon(Icons.verified_outlined),
                    title: const Text('Check file integrity'),
                    onTap: () => run(_verify),
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Details'),
                  onTap: () => run(_showDetails),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: error),
                  title: Text(
                    'Delete from drive',
                    style: TextStyle(color: error),
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

  void _showUploads() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => ListenableBuilder(
        listenable: _drive,
        builder: (context, _) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (context, scroll) => ListView(
            controller: scroll,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Uploads',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (_drive.uploads.any((t) => !t.isActive))
                      TextButton(
                        onPressed: _drive.clearFinished,
                        child: const Text('Clear finished'),
                      ),
                  ],
                ),
              ),
              if (_drive.uploads.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No uploads.', textAlign: TextAlign.center),
                ),
              for (final task in _drive.uploads)
                _UploadTile(
                  task: task,
                  onCancel: () => _guard(() => _drive.cancel(task)),
                  onRetry: () => _drive.retry(task),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(StoredFile file) => [
    formatBytes(file.size),
    // Day only: the list row is narrow, and Details has the exact time.
    formatDate(file.date).split(',').first,
    if (file.device != null) file.device!,
  ].join(' · ');

  // ------------------------------------------------------------ Build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _drive,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 800;
          final tabs = [
            _Tab.photos,
            _Tab.albums,
            _Tab.files,
            if (_hasBackup) _Tab.backup,
          ];
          if (!tabs.contains(_tab)) _tab = _Tab.photos;
          final onBackup = _tab == _Tab.backup;
          final content = Column(
            children: [
              if (_drive.isDemo) const _DemoBanner(),
              Expanded(child: _tabBody()),
            ],
          );
          return Scaffold(
            appBar: onBackup
                ? AppBar(title: const Text('Phone backup'))
                : _searchBar(),
            body: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: tabs.indexOf(_tab),
                        onDestinationSelected: (i) =>
                            setState(() => _tab = tabs[i]),
                        labelType: NavigationRailLabelType.all,
                        destinations: [
                          for (final t in tabs)
                            NavigationRailDestination(
                              icon: Icon(_tabIcon(t, false)),
                              selectedIcon: Icon(_tabIcon(t, true)),
                              label: Text(_tabLabel(t)),
                            ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: content),
                    ],
                  )
                : content,
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: tabs.indexOf(_tab),
                    onDestinationSelected: (i) =>
                        setState(() => _tab = tabs[i]),
                    destinations: [
                      for (final t in tabs)
                        NavigationDestination(
                          icon: Icon(_tabIcon(t, false)),
                          selectedIcon: Icon(_tabIcon(t, true)),
                          label: _tabLabel(t),
                        ),
                    ],
                  ),
            floatingActionButton: onBackup
                ? null
                : FloatingActionButton.extended(
                    onPressed: _pickAndUpload,
                    icon: const Icon(Icons.add),
                    label: const Text('Upload'),
                  ),
          );
        },
      ),
    );
  }

  static IconData _tabIcon(_Tab tab, bool selected) => switch (tab) {
    _Tab.photos =>
      selected ? Icons.photo_library : Icons.photo_library_outlined,
    _Tab.albums => selected ? Icons.photo_album : Icons.photo_album_outlined,
    _Tab.files => selected ? Icons.folder : Icons.folder_outlined,
    _Tab.backup => selected ? Icons.backup : Icons.backup_outlined,
  };

  static String _tabLabel(_Tab tab) => switch (tab) {
    _Tab.photos => 'Photos',
    _Tab.albums => 'Albums',
    _Tab.files => 'Files',
    _Tab.backup => 'Backup',
  };

  PreferredSizeWidget _searchBar() {
    final scheme = Theme.of(context).colorScheme;
    return PreferredSize(
      preferredSize: const Size.fromHeight(68),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(28),
            child: Row(
              children: [
                const SizedBox(width: 10),
                const AppLogo(size: 32),
                Expanded(
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Search your drive',
                      filled: false,
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(_search.clear),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Account and settings',
                  icon: const Icon(Icons.account_circle_outlined),
                  onSelected: (v) => switch (v) {
                    'refresh' => _drive.load(),
                    'about' => _showAbout(),
                    _ => _logOut(),
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      enabled: false,
                      child: Text('This device: ${widget.service.deviceName}'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'refresh',
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('Refresh'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'about',
                      child: ListTile(
                        leading: Icon(Icons.info_outline),
                        title: Text('About TeDrive'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    if (!_drive.isDemo)
                      const PopupMenuItem(
                        value: 'logout',
                        child: ListTile(
                          leading: Icon(Icons.logout),
                          title: Text('Log out'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'TeDrive',
      applicationVersion: '1.0.0',
      applicationIcon: const AppLogo(size: 48),
      children: const [
        Text(
          'A personal cloud drive that keeps your files in a private '
          'channel of your own Telegram account.\n\n'
          'TeDrive is an independent app. It uses the Telegram API but is '
          'not made or endorsed by Telegram.',
        ),
      ],
    );
  }

  Widget _tabBody() {
    if (_tab == _Tab.backup) return BackupBody(backup: _backup);
    if (_drive.error != null && _drive.files.isEmpty) {
      return _Centered(
        icon: Icons.cloud_off,
        title: 'Could not load your drive',
        text: _drive.error!,
        action: FilledButton(
          onPressed: _drive.load,
          child: const Text('Try again'),
        ),
      );
    }
    final Widget body;
    if (_query.isNotEmpty) {
      body = _fileList(
        filterFiles(_drive.files, query: _query),
        emptyTitle: 'No results',
        emptyText: 'Nothing in your drive matches "$_query".',
        header: null,
      );
    } else {
      body = switch (_tab) {
        _Tab.photos => _photos(),
        _Tab.albums => _albums(),
        _ => _files(),
      };
    }
    return Column(
      children: [
        if (_drive.loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(onRefresh: _drive.load, child: body),
        ),
      ],
    );
  }

  Widget? _uploadsCard() => _drive.uploads.isEmpty
      ? null
      : _UploadsCard(drive: _drive, onTap: _showUploads);

  Widget _scroll(List<Widget> slivers) => CustomScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    slivers: [
      if (_uploadsCard() case final card?) SliverToBoxAdapter(child: card),
      ...slivers,
      // Room for the Upload button.
      const SliverToBoxAdapter(child: SizedBox(height: 96)),
    ],
  );

  Widget _photos() {
    final media = filterFiles(_drive.files)
        .where((f) => f.kind == FileKind.image || f.kind == FileKind.video)
        .toList();
    if (media.isEmpty) {
      return _emptyOrLoading(
        icon: Icons.photo_library_outlined,
        title: 'No photos or videos yet',
        text: _hasBackup
            ? 'Turn on backup in the Backup tab, or tap Upload.'
            : 'Tap Upload to add some.',
      );
    }
    return _scroll(
      gallerySlivers(
        context: context,
        drive: _drive,
        files: media,
        onTap: (f) => _open(f, media),
        onLongPress: _showActions,
      ),
    );
  }

  Widget _albums() {
    final names = _drive.folders;
    if (names.isEmpty) {
      return _emptyOrLoading(
        icon: Icons.photo_album_outlined,
        title: 'No albums yet',
        text:
            'Backed-up photos are grouped into albums automatically. You '
            'can also move any file into an album from its menu.',
      );
    }
    return _scroll([
      SliverPadding(
        padding: const EdgeInsets.all(12),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.86,
          ),
          itemCount: names.length,
          itemBuilder: (context, i) {
            final name = names[i];
            final inAlbum = filterFiles(_drive.files, folder: name);
            return _AlbumCard(
              drive: _drive,
              name: name,
              files: inAlbum,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => _albumPage(name))),
            );
          },
        ),
      ),
    ]);
  }

  Widget _albumPage(String name) => ListenableBuilder(
    listenable: _drive,
    builder: (context, _) {
      final inAlbum = filterFiles(_drive.files, folder: name);
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name),
              Text(
                '${inAlbum.length} items · '
                '${formatBytes(inAlbum.fold(0, (s, f) => s + f.size))}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _pickAndUpload(folder: name),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: inAlbum.isEmpty
            ? const _Centered(
                icon: Icons.photo_album_outlined,
                title: 'This album is empty',
                text: 'Tap Add to upload files into it.',
              )
            : CustomScrollView(
                slivers: [
                  ...gallerySlivers(
                    context: context,
                    drive: _drive,
                    files: inAlbum,
                    onTap: (f) => _open(f, inAlbum),
                    onLongPress: _showActions,
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
      );
    },
  );

  Widget _files() {
    final shown = _sorted(filterFiles(_drive.files, category: _category));
    return _fileList(
      shown,
      emptyTitle: _drive.files.isEmpty ? 'Your drive is empty' : 'Nothing here',
      emptyText: _drive.files.isEmpty
          ? 'Tap Upload to add your first files.'
          : 'No files of this type.',
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CategoryBar(
            selected: _category,
            onSelected: (c) => setState(() => _category = c),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${shown.length} file${shown.length == 1 ? '' : 's'} · '
                    '${formatBytes(shown.fold(0, (s, f) => s + f.size))}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                PopupMenuButton<_Sort>(
                  tooltip: 'Sort',
                  icon: const Icon(Icons.sort),
                  initialValue: _sort,
                  onSelected: (s) => setState(() => _sort = s),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _Sort.newest,
                      child: Text('Newest first'),
                    ),
                    PopupMenuItem(
                      value: _Sort.oldest,
                      child: Text('Oldest first'),
                    ),
                    PopupMenuItem(
                      value: _Sort.largest,
                      child: Text('Largest first'),
                    ),
                    PopupMenuItem(value: _Sort.name, child: Text('Name')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<StoredFile> _sorted(List<StoredFile> files) {
    if (_sort == _Sort.newest) return files;
    final copy = [...files];
    switch (_sort) {
      case _Sort.oldest:
        return copy.reversed.toList();
      case _Sort.largest:
        copy.sort((a, b) => b.size.compareTo(a.size));
      case _Sort.name:
        copy.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case _Sort.newest:
        break;
    }
    return copy;
  }

  Widget _fileList(
    List<StoredFile> shown, {
    required String emptyTitle,
    required String emptyText,
    required Widget? header,
  }) {
    if (shown.isEmpty && header == null) {
      return _emptyOrLoading(
        icon: Icons.search_off,
        title: emptyTitle,
        text: emptyText,
      );
    }
    return _scroll([
      if (header != null) SliverToBoxAdapter(child: header),
      if (shown.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              children: [
                Text(
                  emptyTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(emptyText, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final file = shown[i];
          return _FileTile(
            key: ValueKey(file.messageId),
            drive: _drive,
            file: file,
            subtitle: _subtitle(file),
            onTap: () => _open(file, shown),
            onMore: () => _showActions(file),
            onCancel: () => _guard(() => _drive.cancelDownload(file)),
          );
        },
      ),
    ]);
  }

  Widget _emptyOrLoading({
    required IconData icon,
    required String title,
    required String text,
  }) {
    if (_drive.loading && _drive.files.isEmpty) {
      return const _Centered(
        icon: Icons.cloud_sync_outlined,
        title: 'Loading your drive',
        text: 'Reading your files from Telegram…',
      );
    }
    final card = _uploadsCard();
    final empty = _Centered(icon: icon, title: title, text: text);
    return card == null
        ? empty
        : Column(
            children: [
              card,
              Expanded(child: empty),
            ],
          );
  }
}

// ---------------------------------------------------------------- Widgets

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.science_outlined, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Demo with sample files. It is not connected to Telegram and '
              'nothing can be opened or uploaded. Install the Android app to '
              'use your own account.',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value, {this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: mono
                ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                : theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: 44,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (action != null) ...[const SizedBox(height: 20), action!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.selected, required this.onSelected});
  final Category selected;
  final ValueChanged<Category> onSelected;

  static const _labels = {
    Category.all: 'All',
    Category.photos: 'Photos',
    Category.videos: 'Videos',
    Category.audio: 'Audio',
    Category.documents: 'Documents',
    Category.other: 'Other',
  };

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: Row(
      children: [
        for (final c in Category.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(_labels[c]!),
              selected: selected == c,
              onSelected: (_) => onSelected(c),
            ),
          ),
      ],
    ),
  );
}

/// Thumbnail for photos and videos, type icon for everything else.
class _Leading extends StatelessWidget {
  const _Leading({required this.drive, required this.file});
  final DriveController drive;
  final StoredFile file;

  @override
  Widget build(BuildContext context) =>
      file.kind == FileKind.image || file.kind == FileKind.video
      ? ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(
            dimension: 44,
            child: FileThumb(
              drive: drive,
              file: file,
              fallback: KindIcon(file.kind),
            ),
          ),
        )
      : KindIcon(file.kind);
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    super.key,
    required this.drive,
    required this.file,
    required this.subtitle,
    required this.onTap,
    required this.onMore,
    required this.onCancel,
  });

  final DriveController drive;
  final StoredFile file;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloading = drive.isDownloading(file);
    final progress = drive.downloads[file.messageId];
    return ListTile(
      leading: _Leading(drive: drive, file: file),
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
                      : 'Downloading ${(progress * 100).round()}% of '
                            '${formatBytes(file.size)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            )
          : Row(
              children: [
                Flexible(
                  child: Text(
                    subtitle,
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
                    semanticLabel: 'On this device',
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

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.drive,
    required this.name,
    required this.files,
    required this.onTap,
  });

  final DriveController drive;
  final String name;
  final List<StoredFile> files;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = files
        .where((f) => f.kind == FileKind.image || f.kind == FileKind.video)
        .firstOrNull;
    final placeholder = Container(
      color: theme.colorScheme.secondaryContainer,
      child: Icon(
        Icons.photo_album_outlined,
        size: 44,
        color: theme.colorScheme.onSecondaryContainer,
      ),
    );
    return Semantics(
      button: true,
      label: '$name, ${files.length} items',
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox.expand(
                  child: cover == null
                      ? placeholder
                      : FileThumb(
                          drive: drive,
                          file: cover,
                          fallback: placeholder,
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '${files.length} item${files.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-line summary of the upload queue; tap for the full list.
class _UploadsCard extends StatelessWidget {
  const _UploadsCard({required this.drive, required this.onTap});
  final DriveController drive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = drive.uploads.where((t) => t.isActive).toList();
    final failed = drive.uploads
        .where((t) => t.status == UploadStatus.failed)
        .length;
    final current = drive.uploads
        .where(
          (t) =>
              t.status == UploadStatus.uploading ||
              t.status == UploadStatus.preparing,
        )
        .firstOrNull;
    final String title;
    final String subtitle;
    if (active.isNotEmpty) {
      title = active.length == 1
          ? 'Uploading 1 file'
          : 'Uploading ${active.length} files';
      subtitle = current == null
          ? 'Waiting…'
          : current.status == UploadStatus.preparing
          ? 'Preparing ${current.name}'
          : '${current.name} · ${((current.progress ?? 0) * 100).round()}%';
    } else if (failed > 0) {
      title = '$failed upload${failed == 1 ? '' : 's'} failed';
      subtitle = 'Tap to see why and try again';
    } else {
      title = 'Uploads finished';
      subtitle = 'Tap to review';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Card(
        color: failed > 0 && active.isEmpty
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.primaryContainer,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  active.isNotEmpty
                      ? Icons.cloud_upload_outlined
                      : failed > 0
                      ? Icons.error_outline
                      : Icons.cloud_done_outlined,
                ),
                title: Text(title),
                subtitle: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
              if (active.isNotEmpty)
                LinearProgressIndicator(
                  value: current?.status == UploadStatus.uploading
                      ? current?.progress
                      : null,
                  minHeight: 3,
                ),
            ],
          ),
        ),
      ),
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
    final running =
        task.status == UploadStatus.preparing ||
        task.status == UploadStatus.uploading;
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
          if (running) ...[
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

/// Shown while a file is fetched before sharing or opening it.
class _DownloadDialog extends StatelessWidget {
  const _DownloadDialog({
    required this.drive,
    required this.file,
    required this.verb,
    required this.onCancel,
  });

  final DriveController drive;
  final StoredFile file;
  final String verb;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text('$verb…'),
      content: ListenableBuilder(
        listenable: drive,
        builder: (context, _) {
          final progress = drive.downloads[file.messageId];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                progress == null
                    ? 'Downloading from Telegram…'
                    : '${(progress * 100).round()}% of '
                          '${formatBytes(file.size)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
      actions: [TextButton(onPressed: onCancel, child: const Text('Cancel'))],
    ),
  );
}

/// Pick an existing album, type a new one, or choose none.
class _AlbumDialog extends StatefulWidget {
  const _AlbumDialog({required this.albums, required this.current});
  final List<String> albums;
  final String? current;

  @override
  State<_AlbumDialog> createState() => _AlbumDialogState();
}

class _AlbumDialogState extends State<_AlbumDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _choose(String? album) => Navigator.pop(context, (folder: album));

  void _create() {
    if (normalizeFolder(_name.text) != null) _choose(_name.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Move to album'),
    contentPadding: const EdgeInsets.only(top: 16),
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
                labelText: 'New album',
                suffixIcon: IconButton(
                  tooltip: 'Create album and move',
                  icon: const Icon(Icons.check),
                  onPressed: _create,
                ),
              ),
              onSubmitted: (_) => _create(),
            ),
          ),
          for (final name in widget.albums)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.photo_album_outlined),
              title: Text(name),
              trailing: name == widget.current ? const Icon(Icons.check) : null,
              onTap: () => _choose(name),
            ),
          if (widget.current != null)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.block),
              title: const Text('No album'),
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
