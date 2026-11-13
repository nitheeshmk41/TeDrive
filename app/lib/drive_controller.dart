import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_files.dart';
import 'media_server.dart';
import 'persisted_queue.dart';
import 'photo_metadata.dart';
import 'picker_catalogue.dart';
import 'stored_file.dart';
import 'td/td_client.dart' show TdError;
import 'tedrive_service.dart';
import 'thumbnailer.dart';
import 'vault_service.dart';

enum UploadStatus {
  queued,
  preparing,
  uploading,
  done,
  skipped,
  failed,
  cancelled,
}

/// One picked file on its way to the drive.
class UploadTask {
  /// A file chosen in the file picker. It is copied before upload.
  UploadTask(
    PlatformFile this.source, {
    this.folder,
    this.isVault = false,
    this.location,
    this.camera,
  })  : name = source.name,
        size = source.lengthSync(),
        directPath = null,
        taken = null,
        knownSha = null,
        fromBackup = false,
        deleteAfter = false;

  /// A photo or video read straight from the phone's storage by backup.
  UploadTask.fromPath(
    String this.directPath, {
    required this.name,
    required this.size,
    this.folder,
    this.taken,
    this.knownSha,
    this.fromBackup = true,
    this.deleteAfter = false,
    this.isVault = false,
    this.location,
    this.camera,
  }) : source = null;

  final PlatformFile? source;

  /// Uploaded in place (read-only), with no private copy.
  final String? directPath;
  final String name;

  /// Folder the file goes into, or null for none.
  final String? folder;

  /// When the photo or video was taken, if known.
  final DateTime? taken;

  /// The file's SHA-256 if it was computed on an earlier run.
  final String? knownSha;

  /// Backup tasks leave the list by themselves once they succeed.
  final bool fromBackup;

  /// The file at [directPath] is a temporary copy to remove afterwards
  /// (a file another app shared into TeDrive).
  final bool deleteAfter;

  /// Encrypt on device before uploading to vault.
  final bool isVault;

  /// Geotag location (latitude, longitude).
  ({double lat, double lng})? location;

  /// Camera make/model.
  String? camera;

  /// The file's SHA-256, set once it has been computed.
  String? sha;

  final _done = Completer<void>();

  /// Completes when the task has finished, whatever the outcome.
  Future<void> get done => _done.future;

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  int? size;
  UploadStatus status = UploadStatus.queued;

  /// 0..1 while preparing or uploading, null when unknown.
  double? progress;

  /// Why the task failed or was skipped.
  String? message;

  int? _tempMessageId;
  bool _cancelRequested = false;

  bool get isActive =>
      status == UploadStatus.queued ||
      status == UploadStatus.preparing ||
      status == UploadStatus.uploading;
}

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download cancelled';
}

/// State of the drive screen: the file list, the upload queue and the
/// downloads in progress.
class DriveController extends ChangeNotifier {
  DriveController(this._service) {
    if (!kIsWeb) {
      PersistedUploadQueue.instance.directoryProvider ??= getApplicationSupportDirectory;
    }
    _updates = _service.td.updates.listen(_onUpdate);
  }

  final TeDriveService _service;
  late final StreamSubscription<Json> _updates;
  late final MediaServer _media = MediaServer(_service);
  Timer? _catalogueTimer;

  bool loading = true;
  String? error;
  int? _chatId;
  bool _premium = false;

  /// Every file, including those in the trash, newest first.
  List<StoredFile> allFiles = const [];

  List<StoredFile>? _visible;
  List<StoredFile>? _trash;

  /// Files in the drive (not in the trash), newest first.
  List<StoredFile> get files =>
      _visible ??= allFiles.where((f) => !f.inTrash).toList();

  /// Files in the trash, most recently deleted first.
  List<StoredFile> get trash =>
      _trash ??= allFiles.where((f) => f.inTrash).toList()
        ..sort((a, b) => b.trashedAt!.compareTo(a.trashedAt!));

  List<StoredFile> get starred => files.where((f) => f.starred).toList();

  /// Files with a complete copy on this device.
  List<StoredFile> get offline =>
      files.where((f) => localExists(f.localPath)).toList();

  /// Files stored in the encrypted vault.
  List<StoredFile> get vault => files.where((f) => f.isVault).toList();

  /// Files with geotagged GPS location.
  List<StoredFile> get geotagged =>
      files.where((f) => f.location != null).toList();

  final List<UploadTask> uploads = [];

  /// Download progress by message id (0..1, or null when unknown).
  final Map<int, double?> downloads = {};
  final Set<int> _cancelledDownloads = {};

  bool _pumping = false;
  bool _disposed = false;

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
  bool get hasActiveUploads => uploads.any((t) => t.isActive);

  void _notify() {
    if (_disposed) return;
    _visible = null;
    _trash = null;
    notifyListeners();
    _scheduleCatalogue();
  }

  @override
  void dispose() {
    _disposed = true;
    _updates.cancel();
    _catalogueTimer?.cancel();
    _media.close();
    super.dispose();
  }

  /// Keeps the list Android's file picker shows in step with the drive.
  void _scheduleCatalogue() {
    if (loading) return;
    _catalogueTimer ??= Timer(const Duration(seconds: 2), () {
      _catalogueTimer = null;
      if (!_disposed) writePickerCatalogue(files, _thumbPaths);
    });
  }

  // ---- Changes made on other devices ----

  /// Telegram pushes every change to the channel to all signed-in
  /// devices. Applying them here keeps this device's list current when a
  /// file is added, moved or deleted somewhere else.
  void _onUpdate(Json u) {
    if (_chatId == null) return;
    switch (u['@type']) {
      case 'updateNewMessage':
        final message = u['message'] as Json;
        if (message['chat_id'] != _chatId) return;
        final file = _service.fileOf(message);
        if (file != null) _addOrReplace(file);
      case 'updateDeleteMessages':
        if (u['chat_id'] != _chatId ||
            u['is_permanent'] != true ||
            u['from_cache'] == true) {
          return;
        }
        final gone = (u['message_ids'] as List).toSet();
        if (allFiles.any((f) => gone.contains(f.messageId))) {
          allFiles = allFiles
              .where((f) => !gone.contains(f.messageId))
              .toList();
          _notify();
        }
      case 'updateMessageContent' || 'updateMessageEdited':
        if (u['chat_id'] != _chatId) return;
        final id = u['message_id'] as int;
        if (!allFiles.any((f) => f.messageId == id)) return;
        _service.fetchFile(_chatId!, id).then((file) {
          if (file != null && !_disposed) _addOrReplace(file);
        });
    }
  }

  void _addOrReplace(StoredFile file) {
    if (allFiles.any((f) => f.messageId == file.messageId)) {
      // Keep what this device knows about its own local copy.
      final local = _current(file).localPath;
      _replace(file.localPath == null ? file.withLocalPath(local) : file);
    } else {
      allFiles = sortNewestFirst([file, ...allFiles]);
      _notify();
    }
  }

  /// A URL the in-app player can stream [file] from.
  Future<Uri> streamUrl(StoredFile file) => _media.urlFor(_current(file));

  // ---- Catalogue ----

  /// Finds (or creates) the storage channel and reads its history.
  Future<void> load() async {
    loading = true;
    error = null;
    _notify();
    try {
      _chatId ??= await _service.ensureChannel();
      _premium = await _service.isPremium();
      allFiles = sortNewestFirst(
        await _service.history(
          _chatId!,
          onPage: (soFar) {
            allFiles = sortNewestFirst(soFar);
            _notify();
          },
        ),
      );
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      _notify();
      _restorePersistedUploads();
      _pump();
    }
    final expired = expiredTrash(allFiles, DateTime.now());
    if (expired.isNotEmpty && error == null) {
      deleteForever(expired).catchError((_) {});
    }
  }

  Future<void> _restorePersistedUploads() async {
    if (kIsWeb) return;
    try {
      final saved = await PersistedUploadQueue.instance.load();
      for (final item in saved) {
        if (!uploads.any((u) => u.directPath == item.path)) {
          enqueuePath(
            item.path,
            name: item.name,
            size: item.size,
            folder: item.folder,
            taken: item.taken,
            knownSha: item.knownSha,
            isVault: item.isVault,
            fromBackup: false,
          );
        }
      }
    } catch (_) {}
  }

  void _persistQueue() {
    if (kIsWeb) return;
    final items = <QueuedUploadItem>[
      for (final u in uploads)
        if (u.isActive && u.directPath != null)
          QueuedUploadItem(
            path: u.directPath!,
            name: u.name,
            size: u.size ?? 0,
            folder: u.folder,
            taken: u.taken,
            knownSha: u.knownSha,
            isVault: u.isVault,
          ),
    ];
    PersistedUploadQueue.instance.save(items).catchError((_) {});
  }

  /// Shares all files in an album using a shared album link.
  Future<String?> shareAlbum(String albumName) async {
    final inAlbum = filterFiles(files, folder: albumName);
    if (inAlbum.isEmpty) return null;
    final first = inAlbum.first;
    final link = await shareLink(first);
    for (final f in inAlbum) {
      if (f.albumShareLink != link) {
        final updated = f.withAlbumShare(link);
        await _service.setCaption(_chatId!, updated.messageId, updated.caption);
        _replace(updated);
      }
    }
    return link;
  }

  // ---- Star, trash and bulk actions ----

  /// Rewrites each file's caption with [change]. Stops at the first error
  /// and reports how many were done before it.
  Future<int> _editAll(
    Iterable<StoredFile> targets,
    StoredFile Function(StoredFile) change,
  ) async {
    var done = 0;
    for (final f in targets) {
      final updated = change(_current(f));
      await _service.setCaption(_chatId!, updated.messageId, updated.caption);
      _replace(updated);
      done++;
    }
    return done;
  }

  Future<int> setStarred(Iterable<StoredFile> targets, bool on) =>
      _editAll(targets, (f) => f.withStar(on));

  /// Moves files to the trash. They disappear from every view and device,
  /// and can be restored for [trashDays] days.
  Future<int> moveToTrash(Iterable<StoredFile> targets) {
    final now = DateTime.now();
    return _editAll(targets, (f) => f.withTrashedAt(now));
  }

  Future<int> restore(Iterable<StoredFile> targets) =>
      _editAll(targets, (f) => f.withTrashedAt(null));

  Future<int> moveAllToFolder(Iterable<StoredFile> targets, String? folder) =>
      _editAll(targets, (f) => f.withFolder(normalizeFolder(folder)));

  /// Deletes files from Telegram for good. Cannot be undone.
  Future<void> deleteForever(List<StoredFile> targets) async {
    for (final f in targets) {
      await delete(f);
    }
  }

  /// Folder names in use, alphabetical.
  List<String> get folders => foldersOf(files);

  /// Size of every hashed file in the drive, by SHA-256.
  Map<String, int> get sizeBySha => {
    for (final f in allFiles)
      if (f.sha256 != null) f.sha256!: f.size,
  };

  /// Forgets local copies that are no longer on the phone, for example
  /// after "free up space" removed the originals.
  void recheckLocalPaths() {
    if (kIsWeb) return;
    allFiles = [
      for (final f in allFiles)
        if (f.localPath != null && !File(f.localPath!).existsSync())
          f.withLocalPath(null)
        else
          f,
    ];
    _notify();
  }

  /// Moves [file] into [folder], or out of any folder when null.
  Future<void> moveToFolder(StoredFile file, String? folder) async {
    final name = normalizeFolder(folder);
    if (name == file.folder) return;
    await _service.setFolder(_chatId!, file, name);
    _replace(_current(file).withFolder(name));
  }

  /// Renames [file]. Returns the name actually used, or null if [typed]
  /// had nothing usable in it.
  Future<String?> rename(StoredFile file, String typed) async {
    final current = _current(file);
    final name = cleanNewName(typed, original: current.name);
    if (name == null) return null;
    if (name != current.name) {
      await _service.rename(_chatId!, current, name);
      _replace(_current(file).renamed(name));
    }
    return name;
  }

  /// Keeps downloaded copies on this device under [maxBytes].
  Future<void> trimCache(int maxBytes) async {
    await _service.trimCache(maxBytes);
    recheckLocalPaths();
  }

  /// The newest known state of [file] (its local path may have changed).
  StoredFile _current(StoredFile file) => allFiles.firstWhere(
    (f) => f.messageId == file.messageId,
    orElse: () => file,
  );

  final Map<int, Future<String?>> _thumbnails = {};
  final Map<int, String> _thumbPaths = {};

  /// Path of the preview image for [file], fetched once and then reused.
  /// Completes with null when the file has no preview.
  Future<String?> thumbnail(StoredFile file) {
    final id = file.thumbFileId;
    if (id == null) return Future.value();
    return _thumbnails[file.messageId] ??= _service.thumbnailPath(id).then((
      path,
    ) {
      if (path != null) _thumbPaths[file.messageId] = path;
      return path;
    });
  }

  void _replace(StoredFile updated) {
    allFiles = [
      for (final f in allFiles)
        if (f.messageId == updated.messageId) updated else f,
    ];
    _notify();
  }

  // ---- Uploads ----

  void enqueue(
    List<PlatformFile> picked, {
    String? folder,
    bool isVault = false,
    ({double lat, double lng})? location,
    String? camera,
  }) {
    uploads.insertAll(
      0,
      picked.map(
        (f) => UploadTask(
          f,
          folder: folder,
          isVault: isVault,
          location: location,
          camera: camera,
        ),
      ),
    );
    _notify();
    _persistQueue();
    _pump();
  }

  /// Queues a file for upload straight from [path]. The file is only
  /// read, never copied, moved or deleted.
  UploadTask enqueuePath(
    String path, {
    required String name,
    required int size,
    String? folder,
    DateTime? taken,
    String? knownSha,
    bool fromBackup = true,
    bool deleteAfter = false,
    bool isVault = false,
    ({double lat, double lng})? location,
    String? camera,
  }) {
    final task = UploadTask.fromPath(
      path,
      name: name,
      size: size,
      folder: folder,
      taken: taken,
      knownSha: knownSha,
      fromBackup: fromBackup,
      deleteAfter: deleteAfter,
      isVault: isVault,
      location: location,
      camera: camera,
    );
    uploads.insert(0, task);
    _notify();
    _persistQueue();
    _pump();
    return task;
  }

  void retry(UploadTask task) {
    if (task.isActive) return;
    task
      ..status = UploadStatus.queued
      ..progress = null
      ..message = null
      .._cancelRequested = false
      .._tempMessageId = null;
    _notify();
    _persistQueue();
    _pump();
  }

  Future<void> cancel(UploadTask task) async {
    if (!task.isActive) return;
    task._cancelRequested = true;
    if (task.status == UploadStatus.queued) {
      task.status = UploadStatus.cancelled;
      task._finish();
      if (task.fromBackup) uploads.remove(task);
      _notify();
      _persistQueue();
    } else if (task._tempMessageId != null) {
      await _service.cancelUpload(_chatId!, task._tempMessageId!);
    }
  }

  void clearFinished() {
    uploads.removeWhere((t) => !t.isActive);
    _notify();
    _persistQueue();
  }

  /// Uploads queued tasks one at a time, oldest first.
  Future<void> _pump() async {
    if (_pumping || _chatId == null) return;
    _pumping = true;
    try {
      while (!_disposed) {
        UploadTask? next;
        for (final t in uploads.reversed) {
          if (t.status == UploadStatus.queued) {
            next = t;
            break;
          }
        }
        if (next == null) break;
        await _runUpload(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _runUpload(UploadTask task) async {
    if (kIsWeb) return _runWebUpload(task);
    final limit = _premium ? maxUploadBytesPremium : maxUploadBytes;
    void fail(String why) {
      task
        ..status = UploadStatus.failed
        ..message = why;
    }

    task
      ..status = UploadStatus.preparing
      ..progress = null;
    _notify();

    final tmp = await getTemporaryDirectory();
    final dir = Directory(
      '${tmp.path}/upload_${DateTime.now().microsecondsSinceEpoch}',
    );
    // Picked files are uploaded from a private copy. Backup files are
    // uploaded in place: TeDrive only ever reads them, and it never asks
    // TDLib to delete a file outside its own cache (see removeOfflineCopy).
    final source = task.source;
    final directPath = task.directPath;
    final pickerCopy = source?.path;
    final ownsPickerCopy =
        pickerCopy != null &&
        pickerCopy.startsWith(tmp.path) &&
        File(pickerCopy).existsSync();
    try {
      if ((task.size ?? 0) > limit) {
        return fail('Larger than Telegram\'s ${formatBytes(limit)} limit');
      }
      dir.createSync(recursive: true);
      String path;
      if (directPath != null) {
        path = directPath;
      } else if (ownsPickerCopy) {
        path = pickerCopy;
      } else {
        path = '${dir.path}/${safeFileName(task.name)}';
        final sink = File(path).openWrite();
        var copied = 0;
        try {
          await for (final chunk in source!.readAsByteStream()) {
            if (task._cancelRequested) throw UploadCancelled();
            sink.add(chunk);
            copied += chunk.length;
            final total = task.size;
            if (total != null && total > 0) {
              final p = copied / total;
              if (p - (task.progress ?? 0) >= 0.01) {
                task.progress = p;
                _notify();
              }
            }
            // Let the file system keep up instead of buffering in memory.
            if (copied % (8 << 20) < chunk.length) await sink.flush();
          }
        } finally {
          await sink.close();
        }
      }
      if (task.isVault) {
        if (!VaultSession.instance.isUnlocked) {
          return fail('Vault is locked. Unlock vault to upload.');
        }
        final encPath = '${dir.path}/vault_${safeFileName(task.name)}';
        await VaultCipher.encryptFile(
          source: File(path),
          target: File(encPath),
          passphrase: VaultSession.instance.currentPassphrase!,
        );
        path = encPath;
      }
      final size = File(path).lengthSync();
      task.size = size;
      if (size == 0) return fail('The file is empty');
      if (size > limit) {
        return fail('Larger than Telegram\'s ${formatBytes(limit)} limit');
      }
      task.progress = null;
      _notify();
      if (!task.isVault && task.location == null) {
        final meta = await readPhotoMetadata(path);
        task.location = meta.location;
        task.camera ??= meta.camera;
      }
      final sha = task.knownSha ?? await sha256OfFile(path);
      task.sha = sha;
      if (task._cancelRequested) throw UploadCancelled();
      if (allFiles.any((f) => f.sha256 == sha)) {
        task
          ..status = UploadStatus.skipped
          ..message = 'Already in your drive';
        return;
      }
      final kind = kindOf(task.name);
      final thumbnail = kind == FileKind.image || kind == FileKind.video
          ? await createThumbnail(
              source: path,
              target: '${dir.path}/.tedrive_thumb.jpg',
              video: kind == FileKind.video,
            )
          : null;
      if (task._cancelRequested) throw UploadCancelled();
      task
        ..status = UploadStatus.uploading
        ..progress = 0;
      _notify();
      final stored = await _service.upload(
        _chatId!,
        {'@type': 'inputFileLocal', 'path': path},
        sha,
        folder: task.folder,
        taken: task.taken,
        thumbnail: thumbnail,
        location: task.location,
        camera: task.camera,
        isVault: task.isVault,
        onStarted: (id) {
          task._tempMessageId = id;
          if (task._cancelRequested) _service.cancelUpload(_chatId!, id);
        },
        onProgress: (done, total) {
          if (total > 0) {
            task.progress = done / total;
            _notify();
          }
        },
      );
      // A private copy is removed below, so it is not an offline copy. A
      // backed-up original stays where it is and counts as one.
      allFiles = sortNewestFirst([
        stored.withLocalPath(task.deleteAfter ? null : directPath),
        ...allFiles.where((f) => f.messageId != stored.messageId),
      ]);
      task
        ..status = UploadStatus.done
        ..progress = 1;
    } on UploadCancelled {
      task.status = UploadStatus.cancelled;
    } on FileSystemException catch (e) {
      fail(
        e.osError?.errorCode == 28
            ? 'Not enough free space on the phone to prepare the upload'
            : 'Could not read the file: ${e.message}',
      );
    } on TdError catch (e) {
      fail(e.message);
    } catch (e) {
      fail('$e');
    } finally {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        if (ownsPickerCopy) File(pickerCopy).deleteSync();
        // A shared-in temporary copy is kept only while a retry is possible.
        if (task.deleteAfter &&
            directPath != null &&
            task.status != UploadStatus.failed) {
          final shared = File(directPath);
          if (shared.existsSync()) shared.deleteSync();
        }
      } on FileSystemException {
        // Android clears the cache directory on its own if this fails.
      }
      task._finish();
      if (task.fromBackup &&
          (task.status == UploadStatus.done ||
              task.status == UploadStatus.skipped ||
              task.status == UploadStatus.cancelled)) {
        uploads.remove(task);
      }
      _persistQueue();
      _notify();
    }
  }

  /// Uploads a file picked in the browser. There is no file system there,
  /// so it is hashed as a stream and handed to Telegram's library as a Blob.
  Future<void> _runWebUpload(UploadTask task) async {
    final source = task.source!;
    final limit = _premium ? maxUploadBytesPremium : maxUploadBytes;
    task
      ..status = UploadStatus.preparing
      ..progress = null;
    _notify();
    try {
      final size = task.size ?? await source.length() ?? 0;
      task.size = size;
      if (size == 0) throw StateError('The file is empty');
      if (size > limit) {
        throw StateError('Larger than Telegram\'s ${formatBytes(limit)} limit');
      }
      final sha = await sha256OfStream(source.readAsByteStream());
      task.sha = sha;
      if (task._cancelRequested) throw UploadCancelled();
      if (allFiles.any((f) => f.sha256 == sha)) {
        task
          ..status = UploadStatus.skipped
          ..message = 'Already in your drive';
        return;
      }
      task
        ..status = UploadStatus.uploading
        ..progress = 0;
      _notify();
      final stored = await _service.uploadBlob(
        _chatId!,
        source.uri.toString(),
        task.name,
        sha,
        folder: task.folder,
        onStarted: (id) {
          task._tempMessageId = id;
          if (task._cancelRequested) _service.cancelUpload(_chatId!, id);
        },
        onProgress: (done, total) {
          if (total > 0) {
            task.progress = done / total;
            _notify();
          }
        },
      );
      allFiles = sortNewestFirst([
        stored.withLocalPath(null),
        ...allFiles.where((f) => f.messageId != stored.messageId),
      ]);
      task
        ..status = UploadStatus.done
        ..progress = 1;
    } on UploadCancelled {
      task.status = UploadStatus.cancelled;
    } on TdError catch (e) {
      task
        ..status = UploadStatus.failed
        ..message = e.message;
    } on StateError catch (e) {
      task
        ..status = UploadStatus.failed
        ..message = e.message;
    } catch (e) {
      task
        ..status = UploadStatus.failed
        ..message = '$e';
    } finally {
      task._finish();
      _notify();
    }
  }

  // ---- Downloads ----

  bool isDownloading(StoredFile file) => downloads.containsKey(file.messageId);

  /// Returns a local path for [file], downloading it if needed.
  /// A second request for a file that is already downloading joins the
  /// download in progress.
  Future<String> ensureLocal(StoredFile file) =>
      _inFlight[file.messageId] ??= _download(file)
          .whenComplete(() => _inFlight.remove(file.messageId));

  final Map<int, Future<String>> _inFlight = {};

  Future<String> _download(StoredFile file) async {
    final id = file.messageId;
    downloads[id] = null;
    _notify();
    try {
      final path = await _service.download(
        file.fileId,
        mime: mimeOf(file.name),
        onProgress: (done, total) {
          if (total > 0 && downloads.containsKey(id)) {
            downloads[id] = done / total;
            _notify();
          }
        },
      );
      _replace(_current(file).withLocalPath(path));
      return path;
    } catch (e) {
      if (_cancelledDownloads.remove(id)) throw DownloadCancelled();
      rethrow;
    } finally {
      downloads.remove(id);
      _cancelledDownloads.remove(id);
      _notify();
    }
  }

  Future<void> cancelDownload(StoredFile file) async {
    if (!downloads.containsKey(file.messageId)) return;
    _cancelledDownloads.add(file.messageId);
    await _service.cancelDownload(file.fileId);
  }

  /// Frees the phone storage used by a downloaded copy.
  Future<void> removeOffline(StoredFile file) async {
    await _service.removeOfflineCopy(file.fileId);
    _replace(_current(file).withLocalPath(null));
  }

  /// Downloads a fresh copy from Telegram and compares its SHA-256 with
  /// the one recorded at upload. Returns null if there is no recorded hash.
  Future<bool?> verify(StoredFile file) async {
    final expected = file.sha256;
    if (expected == null) return null;
    if (kIsWeb) {
      throw StateError(
        'The integrity check runs in the phone and desktop apps.',
      );
    }
    final local = _current(file).localPath;
    if (local != null &&
        !_service.isCached(local) &&
        File(local).existsSync()) {
      // Telegram's library would hand back the phone's own file, which
      // proves nothing about the copy stored in Telegram.
      throw StateError(
        'The original is still on this phone, so there is nothing to '
        'download and compare. This check works once the phone copy is gone.',
      );
    }
    final wasOffline = file.localPath != null;
    await _service.removeOfflineCopy(file.fileId);
    final path = await ensureLocal(file.withLocalPath(null));
    final ok =
        File(path).lengthSync() == file.size &&
        await sha256OfFile(path) == expected;
    if (!wasOffline) await removeOffline(file);
    return ok;
  }

  /// Permanently deletes the file from Telegram and from this phone's cache.
  /// Creates a public link for [file] (or returns the existing one).
  Future<String> shareLink(StoredFile file) async {
    final current = _current(file);
    final existing = current.shareLink;
    if (existing != null) return existing;
    final link = await _service.createShareLink(
      _chatId!,
      _current(file),
      // Only a copy that is really on this device can be re-sent as media.
      localCopy: localExists(current.localPath) ? current.localPath : null,
    );
    _replace(_current(file).withShareLink(link));
    return link;
  }

  /// Deletes the public copy, so the link stops working.
  Future<void> stopSharing(StoredFile file) async {
    await _service.removeShareLink(_chatId!, _current(file));
    _replace(_current(file).withShareLink(null));
  }

  Future<void> delete(StoredFile file) async {
    if (_current(file).shareLink != null) {
      // Best effort: the public copy should not outlive the file.
      await _service
          .removeShareLink(_chatId!, _current(file))
          .catchError((_) {});
    }
    await _service.removeOfflineCopy(file.fileId);
    await _service.deleteFromDrive(_chatId!, [file.messageId]);
    allFiles = allFiles.where((f) => f.messageId != file.messageId).toList();
    _notify();
  }
}
