import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'media_server.dart';
import 'picker_catalogue.dart';
import 'stored_file.dart';
import 'td/td_client.dart' show TdError;
import 'tedrive_service.dart';
import 'thumbnailer.dart';

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
  UploadTask(PlatformFile this.source, {this.folder})
    : name = source.name,
      size = source.lengthSync(),
      directPath = null,
      taken = null,
      knownSha = null,
      fromBackup = false;

  /// A photo or video read straight from the phone's storage by backup.
  UploadTask.fromPath(
    String this.directPath, {
    required this.name,
    required this.size,
    this.folder,
    this.taken,
    this.knownSha,
  }) : source = null,
       fromBackup = true;

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
    _updates = _service.td.updates.listen(_onUpdate);
  }

  final TeDriveService _service;
  late final StreamSubscription<Json> _updates;
  late final MediaServer _media = MediaServer(_service);
  Timer? _catalogueTimer;

  /// True in the web demo, where files are samples and cannot be opened.
  bool get isDemo => _service.isDemo;

  bool loading = true;
  String? error;
  int? _chatId;
  bool _premium = false;

  /// Files in the drive, newest first.
  List<StoredFile> files = const [];

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
    if (isDemo || loading) return;
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
        if (files.any((f) => gone.contains(f.messageId))) {
          files = files.where((f) => !gone.contains(f.messageId)).toList();
          _notify();
        }
      case 'updateMessageContent' || 'updateMessageEdited':
        if (u['chat_id'] != _chatId) return;
        final id = u['message_id'] as int;
        if (!files.any((f) => f.messageId == id)) return;
        _service.fetchFile(_chatId!, id).then((file) {
          if (file != null && !_disposed) _addOrReplace(file);
        });
    }
  }

  void _addOrReplace(StoredFile file) {
    if (files.any((f) => f.messageId == file.messageId)) {
      // Keep what this device knows about its own local copy.
      final local = _current(file).localPath;
      _replace(file.localPath == null ? file.withLocalPath(local) : file);
    } else {
      files = sortNewestFirst([file, ...files]);
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
      files = sortNewestFirst(
        await _service.history(
          _chatId!,
          onPage: (soFar) {
            files = sortNewestFirst(soFar);
            _notify();
          },
        ),
      );
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      _notify();
      _pump();
    }
  }

  /// Folder names in use, alphabetical.
  List<String> get folders => foldersOf(files);

  /// Size of every hashed file in the drive, by SHA-256.
  Map<String, int> get sizeBySha => {
    for (final f in files)
      if (f.sha256 != null) f.sha256!: f.size,
  };

  /// Forgets local copies that are no longer on the phone, for example
  /// after "free up space" removed the originals.
  void recheckLocalPaths() {
    if (isDemo) return;
    files = [
      for (final f in files)
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

  /// The newest known state of [file] (its local path may have changed).
  StoredFile _current(StoredFile file) => files.firstWhere(
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
    files = [
      for (final f in files)
        if (f.messageId == updated.messageId) updated else f,
    ];
    _notify();
  }

  // ---- Uploads ----

  void enqueue(List<PlatformFile> picked, {String? folder}) {
    uploads.insertAll(0, picked.map((f) => UploadTask(f, folder: folder)));
    _notify();
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
  }) {
    final task = UploadTask.fromPath(
      path,
      name: name,
      size: size,
      folder: folder,
      taken: taken,
      knownSha: knownSha,
    );
    uploads.insert(0, task);
    _notify();
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
    } else if (task._tempMessageId != null) {
      await _service.cancelUpload(_chatId!, task._tempMessageId!);
    }
  }

  void clearFinished() {
    uploads.removeWhere((t) => !t.isActive);
    _notify();
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
      final size = File(path).lengthSync();
      task.size = size;
      if (size == 0) return fail('The file is empty');
      if (size > limit) {
        return fail('Larger than Telegram\'s ${formatBytes(limit)} limit');
      }
      task.progress = null;
      _notify();
      final sha = task.knownSha ?? await sha256OfFile(path);
      task.sha = sha;
      if (task._cancelRequested) throw UploadCancelled();
      if (files.any((f) => f.sha256 == sha)) {
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
        path,
        sha,
        folder: task.folder,
        taken: task.taken,
        thumbnail: thumbnail,
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
      files = sortNewestFirst([
        stored.withLocalPath(directPath),
        ...files.where((f) => f.messageId != stored.messageId),
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
  Future<void> delete(StoredFile file) async {
    await _service.removeOfflineCopy(file.fileId);
    await _service.deleteFromDrive(_chatId!, [file.messageId]);
    files = files.where((f) => f.messageId != file.messageId).toList();
    _notify();
  }
}
