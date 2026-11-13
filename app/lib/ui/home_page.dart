import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_lock.dart';
import '../backup_controller.dart';
import '../device.dart' as device;
import '../drive_controller.dart';
import '../stored_file.dart';
import '../local_files.dart';
import '../td/web_bridge.dart';
import '../tedrive_service.dart';
import '../vault_service.dart';
import '../updater.dart';
import '../wifi_transfer.dart';
import 'account_page.dart';
import 'backup_page.dart';
import 'gallery.dart';
import 'player_page.dart';
import 'theme.dart';

enum _Tab { photos, albums, files, backup }

enum _Sort { newest, oldest, largest, name }

/// The smart views of the Files tab.
enum _View { all, recent, starred, vault, offline, large, duplicates, trash }

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
  _View _view = _View.all;
  bool _appLockInitialized = false;
  bool _photoMapView = false;

  /// Message ids of the selected files. Not empty means selection mode.
  final Set<int> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  /// What is on screen now, for "Select all".
  List<StoredFile> _shown = const [];

  bool get _hasBackup => device.isAndroid;
  String get _query => _search.text.trim();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLockService.instance.init().then((_) {
      if (mounted) setState(() => _appLockInitialized = true);
    });
    // Backup compares the phone with the drive, so load the drive first.
    _drive.load().then((_) {
      if (!mounted) return;
      if (_hasBackup) _backup.init();
      // Keep the app light: downloaded copies are a cache, not storage.
      _drive.trimCache(_cacheLimitBytes).catchError((_) {});
      _takeSharedFiles();
      checkForUpdateQuietly(context);
    });
    device.onSharedFiles(_takeSharedFiles);
  }

  /// Downloaded copies are trimmed to this size, oldest use first.
  static const _cacheLimitBytes = 1024 * 1024 * 1024;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      AppLockService.instance.onPaused();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (AppLockService.instance.onResumed() && mounted) setState(() {});
    if (_hasBackup) _backup.onResume();
    _takeSharedFiles();
  }

  /// Uploads files that another app shared into TeDrive.
  Future<void> _takeSharedFiles() async {
    if (!mounted || _drive.loading) return;
    final shared = await device.takeSharedFiles();
    if (shared.isEmpty || !mounted) return;
    for (final f in shared) {
      _drive.enqueuePath(
        f.path,
        name: f.name,
        size: f.size,
        taken: f.taken,
        fromBackup: false,
        deleteAfter: f.temporary,
      );
    }
    _toast(
      shared.length == 1
          ? 'Adding ${shared.first.name} to your drive'
          : 'Adding ${shared.length} files to your drive',
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    device.onSharedFiles(null);
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

  /// Returns a local path for [file]. If it has to be downloaded first, a
  /// progress dialog with a Cancel button is shown meanwhile. Null if the
  /// download was cancelled or failed.
  Future<String?> _fetch(StoredFile original, String verb) async {
    final file = _latest(original);
    final local = file.localPath;
    if (localExists(local)) return local;
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

  StoredFile _latest(StoredFile file) => _drive.allFiles.firstWhere(
    (f) => f.messageId == file.messageId,
    orElse: () => file,
  );

  // ------------------------------------------------------------ Actions

  Future<void> _pickAndUpload({String? folder}) async {
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
              onShare: _shareMenu,
              onMore: _showActions,
            ),
          ),
        );
      case FileKind.video || FileKind.audio when device.hasBuiltInPlayer:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlayerPage(
              drive: _drive,
              file: _latest(file),
              onShare: _shareMenu,
              onMore: _showActions,
              onOpenElsewhere: _openElsewhere,
            ),
          ),
        );
      default:
        _openElsewhere(file);
    }
  }

  Future<String?> _promptVaultPassphrase() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock Encrypted Vault'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Vault passphrase',
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  Future<String?> _fetchDecrypted(StoredFile file, String verb) async {
    final encPath = await _fetch(file, verb);
    if (encPath == null) return null;
    if (!file.isVault) return encPath;
    if (kIsWeb) {
      _toast('Vault files open in the phone or desktop app');
      return null;
    }
    if (!VaultSession.instance.isUnlocked) {
      final pass = await _promptVaultPassphrase();
      if (pass == null || pass.isEmpty) return null;
      VaultSession.instance.unlock(pass);
    }
    final tmp = await getTemporaryDirectory();
    final decFile = File('${tmp.path}/dec_${safeFileName(file.name)}');
    try {
      await VaultCipher.decryptFile(
        source: File(encPath),
        target: decFile,
        passphrase: VaultSession.instance.currentPassphrase!,
      );
      return decFile.path;
    } on VaultAuthException catch (e) {
      _toast(e.message);
      return null;
    }
  }

  Future<void> _openElsewhere(StoredFile file) => _guard(() async {
    final path = await _fetchDecrypted(file, 'Opening');
    if (path == null) return;
    final mime = mimeOf(file.name);
    if (device.isAndroid) {
      if (!await device.openFile(path, mime: mime, name: file.name)) {
        _toast('No app on this phone can open ${file.name}');
      }
    } else {
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done) _toast(result.message);
    }
  });

  Future<void> _share(StoredFile file) => _guard(() async {
    final path = await _fetchDecrypted(file, 'Preparing');
    if (path == null) return;
    final mime = mimeOf(file.name);
    if (!await device.shareFile(path, mime: mime, name: file.name)) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: mime, name: file.name)],
        ),
      );
    }
  });

  /// Desktop: copies the file into a folder the user picks. Browser:
  /// saves it to the downloads folder.
  Future<void> _saveCopy(StoredFile file) => _guard(() async {
    if (kIsWeb) {
      final url = await _fetch(file, 'Downloading');
      if (url != null) WebTd.save(url, safeFileName(file.name));
      return;
    }
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Save ${file.name} to…',
    );
    if (folder == null) return;
    final path = await _fetchDecrypted(file, 'Downloading');
    if (path == null) return;
    final target = File(
      '$folder${Platform.pathSeparator}${safeFileName(file.name)}',
    );
    if (target.existsSync()) {
      _toast('${target.path} already exists');
      return;
    }
    await File(path).copy(target.path);
    _toast('Saved to ${target.path}');
  });

  Future<String?> _ensureShareLink(StoredFile original) async {
    var link = _latest(original).shareLink;
    if (link != null) return link;
    final go = await _confirm(
      title: 'Create a public link?',
      body:
          'Anyone who has the link can see and download '
          '${_latest(original).name}, without signing in.\n\n'
          'TeDrive copies the file into a public channel called '
          '"TeDrive Shared" in your Telegram. Your other files stay '
          'private. You can stop sharing at any time.',
      action: 'Create link',
    );
    if (!go || !mounted) return null;
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(width: 20),
              Expanded(child: Text('Creating link…')),
            ],
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);
    try {
      link = await _drive.shareLink(original);
      return link;
    } catch (e) {
      _toast(e is StateError ? e.message : 'Could not create the link: $e');
      return null;
    } finally {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _copyShareLink(StoredFile original) async {
    final link = await _ensureShareLink(original);
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link));
    _toast('Link copied');
  }

  Future<void> _sharePublicLink(StoredFile original) async {
    final link = await _ensureShareLink(original);
    if (link == null) return;
    await SharePlus.instance.share(ShareParams(text: link));
  }

  void _shareMenu(StoredFile original) {
    final file = _latest(original);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: _Leading(drive: _drive, file: file),
                  title: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(file.shareLink ?? formatBytes(file.size)),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Copy link'),
                  subtitle: const Text('Direct link to copy and share'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _copyShareLink(original);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share link'),
                  subtitle: const Text(
                    'Send link via WhatsApp, messaging apps…',
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    _sharePublicLink(original);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.download_for_offline_outlined),
                  title: const Text('Send file directly'),
                  subtitle: Text(
                    'Download & send full file (${formatBytes(file.size)})',
                  ),
                  onTap: () {
                    Navigator.pop(sheet);
                    _share(original);
                  },
                ),
                if (file.shareLink != null)
                  ListTile(
                    leading: const Icon(
                      Icons.link_off,
                      color: Colors.redAccent,
                    ),
                    title: const Text('Manage or stop sharing link'),
                    onTap: () {
                      Navigator.pop(sheet);
                      _shareLink(original);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Creates (after a warning) or shows the public link of a file.
  Future<void> _shareLink(StoredFile original) async {
    final link = await _ensureShareLink(original);
    if (link == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ShareLinkDialog(
        name: _latest(original).name,
        link: link,
        onCopy: () {
          Clipboard.setData(ClipboardData(text: link));
          _toast('Link copied');
        },
        onSend: () => SharePlus.instance.share(ShareParams(text: link)),
        onStop: () => _guard(() async {
          await _drive.stopSharing(original);
          _toast('Link removed. It no longer works.');
        }),
      ),
    );
  }

  Future<void> _rename(StoredFile file) async {
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(currentName: _latest(file).name),
    );
    if (typed == null) return;
    await _guard(() async {
      final name = await _drive.rename(file, typed);
      _toast(name == null ? 'That name cannot be used' : 'Renamed to $name');
    });
  }

  void _openAccount() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AccountPage(
          service: widget.service,
          drive: _drive,
          onLogOut: _logOut,
          onAbout: _showAbout,
        ),
      ),
    );
  }

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

  Future<void> _delete(StoredFile file) => _trashFiles([file]);

  /// Moves files to the trash, with an Undo button.
  Future<void> _trashFiles(List<StoredFile> targets) async {
    if (targets.isEmpty) return;
    await _guard(() async {
      final done = await _drive.moveToTrash(targets);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              done == 1 ? 'Moved to trash' : 'Moved $done items to trash',
            ),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => _guard(() => _drive.restore(targets)),
            ),
          ),
        );
    });
  }

  Future<void> _deleteForever(List<StoredFile> targets) async {
    final go = await _confirm(
      title: targets.length == 1
          ? 'Delete ${targets.first.name} forever?'
          : 'Delete ${targets.length} items forever?',
      body: 'They are removed from Telegram on every device. This cannot be undone.',
      action: 'Delete forever',
      destructive: true,
    );
    if (!go) return;
    await _guard(() async {
      await _drive.deleteForever(targets);
      _toast('Deleted for good');
    });
  }

  // ------------------------------------------------------------ Selection

  void _toggleSelect(StoredFile f) => setState(() {
    if (!_selected.remove(f.messageId)) _selected.add(f.messageId);
  });

  void _clearSelection() => setState(_selected.clear);

  /// Tap opens a file, or toggles it while selecting.
  void _tap(StoredFile f, List<StoredFile> siblings) =>
      _selecting ? _toggleSelect(f) : _open(f, siblings);

  List<StoredFile> get _selectedFiles => [
    for (final f in _drive.allFiles)
      if (_selected.contains(f.messageId)) f,
  ];

  Future<void> _bulk(Future<void> Function(List<StoredFile>) action) async {
    final targets = _selectedFiles;
    _clearSelection();
    await action(targets);
  }

  Future<void> _bulkMove(List<StoredFile> targets) async {
    final choice = await showDialog<({String? folder})>(
      context: context,
      builder: (_) => _AlbumDialog(albums: _drive.folders, current: null),
    );
    if (choice == null) return;
    await _guard(() async {
      final n = await _drive.moveAllToFolder(targets, choice.folder);
      _toast('Moved $n item${n == 1 ? '' : 's'}');
    });
  }

  Future<void> _bulkShare(List<StoredFile> targets) => _guard(() async {
    final paths = <XFile>[];
    for (final f in targets) {
      final path = await _fetch(f, 'Preparing');
      if (path == null) return;
      paths.add(XFile(path, mimeType: mimeOf(f.name), name: f.name));
    }
    await SharePlus.instance.share(ShareParams(files: paths));
  });

  Future<void> _bulkDownload(List<StoredFile> targets) async {
    for (final f in targets) {
      await _saveCopy(f);
    }
  }

  PreferredSizeWidget _selectionBar() {
    final inTrash = _view == _View.trash && _tab == _Tab.files;
    final all = _selectedFiles;
    final allStarred = all.isNotEmpty && all.every((f) => f.starred);
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel selection',
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Select all',
          icon: const Icon(Icons.select_all),
          onPressed: () =>
              setState(() => _selected.addAll(_shown.map((f) => f.messageId))),
        ),
        if (inTrash) ...[
          IconButton(
            tooltip: 'Restore',
            icon: const Icon(Icons.restore_from_trash),
            onPressed: () => _bulk(
              (t) => _guard(() async {
                final n = await _drive.restore(t);
                _toast('Restored $n item${n == 1 ? '' : 's'}');
              }),
            ),
          ),
          IconButton(
            tooltip: 'Delete forever',
            icon: const Icon(Icons.delete_forever),
            onPressed: () => _bulk(_deleteForever),
          ),
        ] else ...[
          IconButton(
            tooltip: allStarred ? 'Remove star' : 'Star',
            icon: Icon(allStarred ? Icons.star : Icons.star_border),
            onPressed: () =>
                _bulk((t) => _guard(() => _drive.setStarred(t, !allStarred))),
          ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _bulk(_bulkShare),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) => switch (v) {
              'move' => _bulk(_bulkMove),
              'download' => _bulk(_bulkDownload),
              _ => _bulk(_trashFiles),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'move', child: Text('Move to album')),
              if (kIsWeb || device.isDesktop)
                const PopupMenuItem(value: 'download', child: Text('Download')),
              const PopupMenuItem(value: 'trash', child: Text('Move to trash')),
            ],
          ),
        ],
      ],
    );
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
    if (_latest(original).inTrash) {
      _showTrashActions(_latest(original));
      return;
    }
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
                  leading: Icon(file.starred ? Icons.star : Icons.star_border),
                  title: Text(file.starred ? 'Remove star' : 'Star'),
                  onTap: () {
                    Navigator.pop(sheet);
                    _guard(() => _drive.setStarred([file], !file.starred));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share or send'),
                  subtitle: const Text('Copy link, share link, or send file'),
                  onTap: () => run(_shareMenu),
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Copy link'),
                  subtitle: file.shareLink == null
                      ? const Text('Share instantly via link')
                      : Text(
                          file.shareLink!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => run(_copyShareLink),
                ),
                if (device.isDesktop || kIsWeb)
                  ListTile(
                    leading: const Icon(Icons.save_alt),
                    title: Text(
                      kIsWeb ? 'Download' : 'Save a copy to this computer',
                    ),
                    onTap: () => run(_saveCopy),
                  ),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('Open in another app'),
                  onTap: () => run(_openElsewhere),
                ),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: const Text('Rename'),
                  onTap: () => run(_rename),
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
                if (file.sha256 != null && !kIsWeb)
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

  void _showTrashActions(StoredFile file) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
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
              subtitle: Text(
                'In trash since ${formatDate(file.trashedAt!).split(',').first}',
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.restore_from_trash),
              title: const Text('Restore'),
              onTap: () {
                Navigator.pop(sheet);
                _guard(() => _drive.restore([file]));
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete forever',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheet);
                _deleteForever([file]);
              },
            ),
          ],
        ),
      ),
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
    if (_appLockInitialized && !AppLockService.instance.isUnlocked) {
      return AppLockScreen(onSuccess: () => setState(() {}));
    }
    final home = _buildHome(context);
    if (!device.isDesktop) return home;
    // On a computer, files dragged onto the window are uploaded.
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _uploadDropped(details.files.map((f) => f.path).toList());
      },
      child: Stack(
        children: [
          home,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer
                        .withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_upload_outlined,
                          size: 72,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Drop files to upload',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _dragging = false;

  void _uploadDropped(List<String> paths) {
    final files = [
      for (final p in paths)
        if (FileSystemEntity.isFileSync(p)) File(p),
    ];
    if (files.isEmpty) {
      _toast('Drop files, not folders');
      return;
    }
    for (final file in files) {
      _drive.enqueuePath(
        file.path,
        name: file.uri.pathSegments.last,
        size: file.lengthSync(),
        taken: file.lastModifiedSync(),
        fromBackup: false,
      );
    }
    _toast(
      files.length == 1
          ? 'Uploading ${files.first.uri.pathSegments.last}'
          : 'Uploading ${files.length} files',
    );
  }

  Widget _buildHome(BuildContext context) {
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
          final content = Column(children: [Expanded(child: _tabBody())]);
          return Scaffold(
            appBar: _selecting
                ? _selectionBar()
                : onBackup
                ? AppBar(title: const Text('Phone backup'))
                : _searchBar(),
            body: wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: tabs.indexOf(_tab),
                        onDestinationSelected: (i) => setState(() {
                          _tab = tabs[i];
                          _selected.clear();
                        }),
                        labelType: NavigationRailLabelType.all,
                        leading: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: AppLogo(size: 36),
                        ),
                        trailing: Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!kIsWeb)
                                    IconButton(
                                      tooltip:
                                          'Wi-Fi Transfer (Phone to Laptop)',
                                      icon: const Icon(Icons.wifi_tethering),
                                      onPressed: _openWifiTransfer,
                                    ),
                                  IconButton(
                                    tooltip: 'Switch theme',
                                    icon: Icon(
                                      Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Icons.light_mode_outlined
                                          : Icons.dark_mode_outlined,
                                    ),
                                    onPressed: () {
                                      final dark =
                                          Theme.of(context).brightness ==
                                          Brightness.dark;
                                      themeMode.value = dark
                                          ? ThemeMode.light
                                          : ThemeMode.dark;
                                      widget.service.writeSetting(
                                        'theme',
                                        dark ? 'light' : 'dark',
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
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
                    onDestinationSelected: (i) => setState(() {
                      _tab = tabs[i];
                      _selected.clear();
                    }),
                    destinations: [
                      for (final t in tabs)
                        NavigationDestination(
                          icon: Icon(_tabIcon(t, false)),
                          selectedIcon: Icon(_tabIcon(t, true)),
                          label: _tabLabel(t),
                        ),
                    ],
                  ),
            floatingActionButton: onBackup || _selecting
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

  Future<void> _shareAlbum(String name) async {
    final link = await _drive.shareAlbum(name);
    if (!mounted) return;
    if (link != null) {
      await Clipboard.setData(ClipboardData(text: link));
      _toast('Album share link copied: $link');
    } else {
      _toast('Album is empty or link could not be generated');
    }
  }

  Future<void> _createSubfolder(String parent) async {
    final controller = TextEditingController();
    final subName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New subfolder in ${folderBaseName(parent)}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Subfolder name',
            hintText: 'e.g. 2026, Summer, Invoices',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (subName != null && subName.isNotEmpty) {
      final fullPath = normalizeFolder('$parent/$subName');
      if (fullPath != null) {
        _pickAndUpload(folder: fullPath);
      }
    }
  }

  Future<void> _openVaultAddDocument() async {
    if (!VaultSession.instance.isUnlocked) {
      final pass = await _promptVaultPassphrase();
      if (!mounted) return;
      if (pass == null || pass.isEmpty) return;
      VaultSession.instance.unlock(pass);
      setState(() {});
    }
    if (!mounted) return;
    final preset = await showDialog<VaultDocType>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose Document Type'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final doc in VaultDocType.values)
              ListTile(
                leading: Icon(
                  doc == VaultDocType.aadhaar || doc == VaultDocType.pan
                      ? Icons.badge_outlined
                      : Icons.description_outlined,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
                title: Text(doc.label),
                onTap: () => Navigator.pop(ctx, doc),
              ),
          ],
        ),
      ),
    );
    if (preset == null) return;
    if (kIsWeb) {
      _toast('Add vault files from the phone or desktop app');
      return;
    }
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    _drive.enqueue(
      picked,
      folder: 'Documents/Vault/${preset.label}',
      isVault: true,
    );
    _toast('Encrypting and adding ${picked.length} document(s) to Vault');
  }

  void _openWifiTransfer() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _WifiTransferSheet(drive: _drive),
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
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: _drive.loading ? null : _drive.load,
                ),
                if (!kIsWeb)
                  IconButton(
                    tooltip: 'Phone-to-Laptop Wi-Fi Transfer',
                    icon: const Icon(Icons.wifi_tethering),
                    onPressed: _openWifiTransfer,
                  ),
                IconButton(
                  tooltip: 'Switch light or dark theme',
                  icon: Icon(
                    Theme.of(context).brightness == Brightness.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                  ),
                  onPressed: () {
                    final dark =
                        Theme.of(context).brightness == Brightness.dark;
                    themeMode.value = dark ? ThemeMode.light : ThemeMode.dark;
                    widget.service.writeSetting(
                      'theme',
                      dark ? 'light' : 'dark',
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Account and storage',
                  icon: const Icon(Icons.account_circle_outlined),
                  onPressed: _openAccount,
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
    _shown = media;
    final memories = onThisDay(media, DateTime.now());
    final geotagged = geotaggedFiles(media);

    return _scroll([
      if (memories.isNotEmpty && !_selecting)
        SliverToBoxAdapter(
          child: _Memories(
            drive: _drive,
            memories: memories,
            onOpen: (f, all) => _open(f, all),
          ),
        ),
      if (geotagged.isNotEmpty && !_selecting)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                ActionChip(
                  avatar: Icon(
                    _photoMapView ? Icons.grid_view : Icons.map_outlined,
                    size: 18,
                  ),
                  label: Text(
                    _photoMapView
                        ? 'Photo Grid'
                        : 'Photo Map (${geotagged.length})',
                  ),
                  onPressed: () =>
                      setState(() => _photoMapView = !_photoMapView),
                ),
              ],
            ),
          ),
        ),
      if (_photoMapView && geotagged.isNotEmpty)
        SliverToBoxAdapter(
          child: _PhotoMapView(
            drive: _drive,
            files: geotagged,
            onOpen: (f) => _open(f, geotagged),
          ),
        )
      else
        ...gallerySlivers(
          context: context,
          drive: _drive,
          files: media,
          onTap: (f) => _tap(f, media),
          onLongPress: _toggleSelect,
          isSelected: _selecting
              ? (f) => _selected.contains(f.messageId)
              : null,
        ),
    ]);
  }

  Widget _albums() {
    final rootFolders = directSubfolders(_drive.files);
    final display = rootFolders.isNotEmpty ? rootFolders : _drive.folders;
    if (display.isEmpty) {
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
          itemCount: display.length,
          itemBuilder: (context, i) {
            final name = display[i];
            final inAlbum = filesInFolder(_drive.files, name, recursive: true);
            return _AlbumCard(
              drive: _drive,
              name: folderBaseName(name),
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
      final inFolder = filesInFolder(_drive.files, name, recursive: false);
      final subfolders = directSubfolders(_drive.files, name);
      final crumbs = folderBreadcrumbs(name);
      return Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(folderBaseName(name)),
              Text(
                '${inFolder.length} items · '
                '${formatBytes(inFolder.fold(0, (s, f) => s + f.size))}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Share album link',
              icon: const Icon(Icons.share_outlined),
              onPressed: () => _shareAlbum(name),
            ),
            IconButton(
              tooltip: 'New subfolder',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () => _createSubfolder(name),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _pickAndUpload(folder: name),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: CustomScrollView(
          slivers: [
            if (crumbs.length > 1)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < crumbs.length; i++) ...[
                          if (i > 0)
                            const Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: Colors.grey,
                            ),
                          InkWell(
                            onTap: i == crumbs.length - 1
                                ? null
                                : () => Navigator.of(context).pushReplacement(
                                    MaterialPageRoute<void>(
                                      builder: (_) => _albumPage(crumbs[i]),
                                    ),
                                  ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              child: Text(
                                folderBaseName(crumbs[i]),
                                style: TextStyle(
                                  fontWeight: i == crumbs.length - 1
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: i == crumbs.length - 1
                                      ? null
                                      : Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            if (subfolders.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Subfolders',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.86,
                  ),
                  itemCount: subfolders.length,
                  itemBuilder: (context, i) {
                    final sub = subfolders[i];
                    final inSub = filesInFolder(
                      _drive.files,
                      sub,
                      recursive: true,
                    );
                    return _AlbumCard(
                      drive: _drive,
                      name: folderBaseName(sub),
                      files: inSub,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _albumPage(sub),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (inFolder.isEmpty && subfolders.isEmpty)
              const SliverFillRemaining(
                child: _Centered(
                  icon: Icons.photo_album_outlined,
                  title: 'This album is empty',
                  text: 'Tap Add to upload files into it.',
                ),
              )
            else ...[
              if (inFolder.isNotEmpty && subfolders.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Files in this folder',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ...gallerySlivers(
                context: context,
                drive: _drive,
                files: inFolder,
                onTap: (f) => _open(f, inFolder),
                onLongPress: _showActions,
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      );
    },
  );

  Widget _files() {
    if (_view == _View.vault && !VaultSession.instance.isUnlocked) {
      return _VaultUnlockCard(onUnlocked: () => setState(() {}));
    }
    final now = DateTime.now();
    final dupGroups = _view == _View.duplicates
        ? duplicateGroups(_drive.files)
        : const <List<StoredFile>>[];
    final base = switch (_view) {
      _View.all => _sorted(_drive.files),
      _View.recent => recentFiles(_drive.files, now),
      _View.starred => _sorted(_drive.starred),
      _View.vault => _sorted(_drive.vault),
      _View.large => largeFiles(_drive.files, minBytes: 10 * 1024 * 1024),
      _View.duplicates => [for (final g in dupGroups) ...g],
      _View.offline => _sorted(_drive.offline),
      _View.trash => _drive.trash,
    };
    final shown = filterFiles(base, category: _category);
    final (emptyTitle, emptyText) = switch (_view) {
      _View.all when _drive.files.isEmpty => (
        'Your drive is empty',
        'Tap Upload to add your first files.',
      ),
      _View.recent => (
        'Nothing recent',
        'Files uploaded in the last 30 days show here.',
      ),
      _View.starred => (
        'No starred files',
        'Star a file from its menu to find it here.',
      ),
      _View.vault => (
        'Vault is empty',
        'Store confidential files like Aadhaar, PAN card and certificates safely.',
      ),
      _View.large => (
        'No large files',
        'Files of 10 MB or more show here, biggest first.',
      ),
      _View.duplicates => (
        'No duplicates',
        'Every file in your drive is unique.',
      ),
      _View.offline => (
        'Nothing offline',
        'Files you open or keep on this device show here.',
      ),
      _View.trash => (
        'Trash is empty',
        'Deleted files stay here for $trashDays days.',
      ),
      _ => ('Nothing here', 'No files of this type.'),
    };
    final wasted = [for (final g in dupGroups) ...g.skip(1)];
    return _fileList(
      shown,
      emptyTitle: emptyTitle,
      emptyText: emptyText,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ViewBar(
            selected: _view,
            trashCount: _drive.trash.length,
            onSelected: (v) => setState(() {
              _view = v;
              _selected.clear();
            }),
          ),
          if (_view == _View.vault)
            _Banner(
              icon: Icons.shield_outlined,
              text: 'Documents are AES-256 encrypted on device. Telegram cannot read them.',
              action: 'Add Document',
              onAction: _openVaultAddDocument,
            ),
          if (_view == _View.duplicates && wasted.isNotEmpty)
            _Banner(
              icon: Icons.copy_all,
              text:
                  '${wasted.length} extra cop${wasted.length == 1 ? 'y' : 'ies'} use '
                  '${formatBytes(wasted.fold(0, (s, f) => s + f.size))}. The oldest '
                  'copy of each is kept.',
              action: 'Select extras',
              onAction: () => setState(
                () => _selected.addAll(wasted.map((f) => f.messageId)),
              ),
            ),
          if (_view == _View.trash && _drive.trash.isNotEmpty)
            _Banner(
              icon: Icons.delete_outline,
              text: 'Items are deleted for good after $trashDays days.',
              action: 'Empty trash',
              onAction: () => _deleteForever(_drive.trash),
            ),
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
    _shown = shown;
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
            selecting: _selecting,
            selected: _selected.contains(file.messageId),
            onTap: () => _tap(file, shown),
            onLongPress: () => _toggleSelect(file),
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
    this.selecting = false,
    this.selected = false,
    this.onLongPress,
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
  final bool selecting;
  final bool selected;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloading = drive.isDownloading(file);
    final progress = drive.downloads[file.messageId];
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.5,
      ),
      leading: selecting
          ? Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? theme.colorScheme.primary : null,
            )
          : _Leading(drive: drive, file: file),
      title: Row(
        children: [
          Flexible(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (file.starred) ...[
            const SizedBox(width: 4),
            Icon(Icons.star, size: 16, color: Colors.amber.shade700),
          ],
        ],
      ),
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
      onLongPress: downloading ? null : (onLongPress ?? onMore),
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

/// Asks for a new file name. The extension is shown but left unselected,
/// so typing replaces only the name part.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.currentName});
  final String currentName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.currentName);

  @override
  void initState() {
    super.initState();
    final dot = widget.currentName.lastIndexOf('.');
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: dot > 0 ? dot : widget.currentName.length,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isNotEmpty) Navigator.pop(context, _name.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 120,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: 'Name',
        helperText: 'The new name shows on all your devices.',
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
        onPressed: _submit,
        child: const Text('Rename'),
      ),
    ],
  );
}

/// A file's public link, with copy, send and stop-sharing actions.
class _ShareLinkDialog extends StatelessWidget {
  const _ShareLinkDialog({
    required this.name,
    required this.link,
    required this.onCopy,
    required this.onSend,
    required this.onStop,
  });

  final String name;
  final String link;
  final VoidCallback onCopy;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void close(VoidCallback action) {
      Navigator.pop(context);
      action();
    }

    return AlertDialog(
      title: const Text('Share link'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Anyone with this link can see and download $name.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              link,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => close(onCopy),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => close(onSend),
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Send'),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          onPressed: () => close(onStop),
          child: const Text('Stop sharing'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _ViewBar extends StatelessWidget {
  const _ViewBar({
    required this.selected,
    required this.trashCount,
    required this.onSelected,
  });

  final _View selected;
  final int trashCount;
  final ValueChanged<_View> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = <(_View, IconData, String)>[
      (_View.all, Icons.folder_outlined, 'All files'),
      (_View.recent, Icons.schedule, 'Recent'),
      (_View.starred, Icons.star_border, 'Starred'),
      (_View.vault, Icons.lock_outline, 'Encrypted Vault'),
      (_View.offline, Icons.offline_pin_outlined, 'Offline'),
      (_View.large, Icons.data_usage, 'Large'),
      (_View.duplicates, Icons.copy_all, 'Duplicates'),
      (
        _View.trash,
        Icons.delete_outline,
        trashCount > 0 ? 'Trash ($trashCount)' : 'Trash',
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          for (final (view, icon, label) in items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: selected == view,
                showCheckmark: false,
                onSelected: (_) => onSelected(view),
              ),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.action,
    required this.onAction,
  });

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Card(
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
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
              TextButton(onPressed: onAction, child: Text(action)),
            ],
          ),
        ),
      ),
    );
  }
}

/// "On this day": photos taken on today's date in earlier years.
class _Memories extends StatelessWidget {
  const _Memories({
    required this.drive,
    required this.memories,
    required this.onOpen,
  });

  final DriveController drive;
  final List<({int yearsAgo, List<StoredFile> files})> memories;
  final void Function(StoredFile, List<StoredFile>) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'On this day',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 150,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final m in memories)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => onOpen(m.files.first, m.files),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 120,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FileThumb(
                                drive: drive,
                                file: m.files.first,
                                fallback: ColoredBox(
                                  color: theme.colorScheme.secondaryContainer,
                                ),
                              ),
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black54,
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 10,
                                right: 10,
                                bottom: 8,
                                child: Text(
                                  m.yearsAgo == 1
                                      ? '1 year ago'
                                      : '${m.yearsAgo} years ago',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VaultUnlockCard extends StatefulWidget {
  const _VaultUnlockCard({required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  State<_VaultUnlockCard> createState() => _VaultUnlockCardState();
}

class _VaultUnlockCardState extends State<_VaultUnlockCard> {
  final _pass = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  void _unlock() {
    final p = _pass.text.trim();
    if (p.isEmpty) {
      setState(() => _error = 'Please enter your vault passphrase');
      return;
    }
    VaultSession.instance.unlock(p);
    widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          margin: const EdgeInsets.all(24),
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    Icons.shield_outlined,
                    size: 36,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Encrypted Document Vault',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sensitive documents like Aadhaar, PAN card, passport and certificates are encrypted on your device using AES-256 before uploading.\n\nOnly your passphrase can decrypt them.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _pass,
                  obscureText: _obscure,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Vault passphrase',
                    hintText: 'Enter or create your passphrase',
                    prefixIcon: const Icon(Icons.key_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _unlock(),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Unlock Vault'),
                    onPressed: _unlock,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WifiTransferSheet extends StatefulWidget {
  const _WifiTransferSheet({required this.drive});
  final DriveController drive;

  @override
  State<_WifiTransferSheet> createState() => _WifiTransferSheetState();
}

class _WifiTransferSheetState extends State<_WifiTransferSheet> {
  String? _url;
  bool _starting = true;
  String? _error;
  late final StreamSubscription<File> _sub;
  final List<File> _received = [];

  @override
  void initState() {
    super.initState();
    _start();
    _sub = WifiTransferService.instance.onFileReceived.listen((file) {
      if (mounted) setState(() => _received.insert(0, file));
    });
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final tmp = await getTemporaryDirectory();
      final uploadDir = Directory('${tmp.path}/wifi_received');
      final shareable = [
        for (final f in widget.drive.offline)
          if (f.localPath != null)
            (name: f.name, size: f.size, path: f.localPath!),
      ];
      final url = await WifiTransferService.instance.startServer(
        shareableFiles: shareable,
        uploadDir: uploadDir,
      );
      if (mounted) setState(() => _url = url);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering, color: scheme.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Phone-to-Laptop Wi-Fi Transfer',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Direct LAN transfer — zero internet data',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_starting)
              const CircularProgressIndicator()
            else if (_error != null) ...[
              Icon(Icons.error_outline, color: scheme.error, size: 40),
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ] else if (_url != null) ...[
              Text(
                'Open this link in your laptop browser:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      _url!,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: 'Copy link',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _url!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Wi-Fi Transfer URL copied'),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: 160,
                height: 160,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _url!,
                  backgroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Scan QR with laptop or other phone on the same Wi-Fi',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_received.isNotEmpty) ...[
              const Divider(height: 32),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Received from Laptop (${_received.length})',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final file in _received)
                ListTile(
                  leading: const Icon(Icons.file_download_done),
                  title: Text(file.uri.pathSegments.last),
                  subtitle: Text(formatBytes(file.lengthSync())),
                  trailing: TextButton(
                    onPressed: () {
                      widget.drive.enqueuePath(
                        file.path,
                        name: file.uri.pathSegments.last,
                        size: file.lengthSync(),
                        fromBackup: false,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Adding ${file.uri.pathSegments.last} to TeDrive',
                          ),
                        ),
                      );
                    },
                    child: const Text('Add to drive'),
                  ),
                ),
            ],
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () {
                WifiTransferService.instance.stopServer();
                Navigator.pop(context);
              },
              child: const Text('Stop transfer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoMapView extends StatelessWidget {
  const _PhotoMapView({
    required this.drive,
    required this.files,
    required this.onOpen,
  });

  final DriveController drive;
  final List<StoredFile> files;
  final void Function(StoredFile) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${files.length} photos with a location',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: PhotoMap(files: files, drive: drive, onOpen: onOpen),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Locations',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          for (final f in files)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: SizedBox(
                  width: 48,
                  height: 48,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: FileThumb(
                      drive: drive,
                      file: f,
                      fallback: const Icon(Icons.photo),
                    ),
                  ),
                ),
                title: Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${f.location!.lat.toStringAsFixed(4)}°, ${f.location!.lng.toStringAsFixed(4)}° · ${formatDate(f.date).split(',').first}',
                ),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                onTap: () => onOpen(f),
              ),
            ),
        ],
      ),
    );
  }
}

/// An OpenStreetMap map with a photo pin for each geotagged file.
class PhotoMap extends StatelessWidget {
  const PhotoMap({
    super.key,
    required this.files,
    required this.drive,
    required this.onOpen,
    this.zoom,
  });

  final List<StoredFile> files;
  final DriveController drive;
  final void Function(StoredFile) onOpen;
  final double? zoom;

  @override
  Widget build(BuildContext context) {
    final points = [
      for (final f in files)
        if (f.location != null) LatLng(f.location!.lat, f.location!.lng),
    ];
    if (points.isEmpty) return const SizedBox.shrink();
    final single = points.length == 1 || points.every((p) => p == points.first);
    return FlutterMap(
      options: MapOptions(
        initialCenter: points.first,
        initialZoom: zoom ?? 12,
        initialCameraFit: single
            ? null
            : CameraFit.coordinates(
                coordinates: points,
                padding: const EdgeInsets.all(40),
                maxZoom: 15,
              ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'dev.tedrive.tedrive',
        ),
        MarkerLayer(
          markers: [
            for (final f in files)
              if (f.location != null)
                Marker(
                  point: LatLng(f.location!.lat, f.location!.lng),
                  width: 44,
                  height: 44,
                  child: GestureDetector(
                    onTap: () => onOpen(f),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 2),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: const [
                          BoxShadow(color: Colors.black38, blurRadius: 4),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: FileThumb(
                          drive: drive,
                          file: f,
                          fallback: const ColoredBox(
                            color: Colors.white,
                            child: Icon(Icons.photo, size: 20),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
          ],
        ),
        const SimpleAttributionWidget(
          source: Text('OpenStreetMap contributors'),
        ),
      ],
    );
  }
}
