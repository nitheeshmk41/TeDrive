import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_plan.dart';
import 'device.dart' as device;
import 'drive_controller.dart';
import 'stored_file.dart' show FileKind, formatBytes;
import 'tedrive_service.dart';

/// Phone backup and "free up space". Lives as long as the drive screen,
/// so a backup keeps going when its own page is closed.
class BackupController extends ChangeNotifier {
  BackupController(this._service, this._drive);

  final TeDriveService _service;
  final DriveController _drive;

  /// "full", "partial" or "none".
  String permission = 'none';
  BackupSettings settings = const BackupSettings();
  List<MediaItem> items = const [];
  bool scanning = false;

  /// A backup run is in progress.
  bool running = false;

  /// Why the last run stopped early or could not start, if it did.
  String? notice;

  /// Progress of the current run.
  int runDone = 0;
  int runTotal = 0;

  BackupIndex _index = BackupIndex();
  File? _indexFile;
  bool _stopRequested = false;
  UploadTask? _currentTask;
  Timer? _timer;
  bool _disposed = false;
  bool _askedNotifications = false;

  /// When automatic or manual backup last finished with nothing left.
  DateTime? lastRun;
  Timer? _widgetTimer;
  String? _widgetShown;

  bool _serviceOn = false;
  DateTime _lastServiceAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastServiceUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  bool get hasPermission => permission != 'none';
  List<AlbumInfo> get albums => albumsOf(items);
  Set<String> get selectedAlbums => settings.albums ?? const {};

  /// Photos and videos still to be checked or uploaded.
  List<MediaItem> get pending => pendingBackup(
    items,
    albums: selectedAlbums,
    index: _index,
    driveShas: _drive.sizeBySha.keys.toSet(),
  );

  /// Photos and videos in the chosen albums.
  int get selectedCount =>
      items.where((i) => selectedAlbums.contains(i.album)).length;

  /// Photos and videos that are safely in the drive and still on the phone.
  List<MediaItem> get freeableItems =>
      freeable(items, index: _index, driveSizeBySha: _drive.sizeBySha);

  void _notify() {
    if (_disposed) return;
    notifyListeners();
    _widgetTimer ??= Timer(const Duration(seconds: 2), () {
      _widgetTimer = null;
      if (!_disposed) _updateWidget();
    });
  }

  /// Keeps the home-screen widget in step.
  void _updateWidget() {
    final String status;
    String? why;
    if (!hasPermission) {
      status = 'Backup is off';
      why = 'Open TeDrive to allow access to photos';
    } else if (running) {
      status = runTotal == 0
          ? 'Checking for new photos…'
          : 'Backing up ${runDone + 1 > runTotal ? runTotal : runDone + 1} of $runTotal';
    } else if (notice != null) {
      status = 'Backup paused';
      why = notice;
    } else {
      final n = pending.length;
      status = n == 0
          ? 'All backed up'
          : n == 1
          ? '1 photo or video waiting'
          : '$n photos and videos waiting';
    }
    final last = lastRun;
    final detail = [
      ?why,
      last == null
          ? 'Not backed up yet'
          : 'Last backup: ${describeWhen(last, DateTime.now())}',
      if (settings.auto)
        settings.frequency.label.toLowerCase()
      else
        'automatic backup off',
    ].join(' · ');
    final files = _drive.files;
    final photos = files.where((f) => f.kind == FileKind.image).length;
    final videos = files.where((f) => f.kind == FileKind.video).length;
    final waiting = hasPermission ? pending.length : 0;
    final values = <String, Object>{
      'status': status,
      'detail': detail,
      'progress': running && runTotal > 0
          ? (runDone * 100 ~/ runTotal).clamp(0, 100)
          : -1,
      'size': formatBytes(_drive.totalBytes),
      'count': groupThousands(files.length),
      'files': files.length == 1
          ? '1 file'
          : '${groupThousands(files.length)} files',
      'media':
          '${groupThousands(photos)} photos · ${groupThousands(videos)} videos',
      'waiting': groupThousands(waiting),
    };
    final key = values.toString();
    if (key == _widgetShown) return;
    _widgetShown = key;
    device.updateWidget(values);
  }

  /// Tells Android when to wake TeDrive (or remind) for scheduled backup.
  void _syncSchedule() {
    device.setBackupSchedule(
      mode: settings.auto ? settings.frequency.name : 'off',
      albums: selectedAlbums,
      lastRun: lastRun,
    );
  }

  /// Tells the drive which of its files are already in the phone's
  /// gallery, so they open from the phone instead of downloading.
  void _sharePhoneCopies() {
    final bySha = <String, String>{};
    final byNameSize = <String, String>{};
    for (final i in items) {
      final sha = _index.shaOf(i);
      if (sha != null) bySha[sha] = i.path;
      byNameSize['${i.name}|${i.size}'] = i.path;
    }
    _drive.setPhoneCopies(bySha: bySha, byNameSize: byNameSize);
  }

  Future<void> init() async {
    settings = BackupSettings.decode(await _service.readSetting('backup'));
    final last = int.tryParse(
      await _service.readSetting('backup_last_run') ?? '',
    );
    if (last != null) lastRun = DateTime.fromMillisecondsSinceEpoch(last);
    final support = await getApplicationSupportDirectory();
    _indexFile = File('${support.path}/backup_index.json');
    if (_indexFile!.existsSync()) {
      _index = BackupIndex.decode(await _indexFile!.readAsString());
    }
    permission = await device.mediaPermission();
    _drive.addListener(_onDriveChanged);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => maybeAutoRun());
    _syncSchedule();
    _notify();
    if (hasPermission) {
      await scan();
      maybeAutoRun();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRequested = true;
    _timer?.cancel();
    _widgetTimer?.cancel();
    _drive.removeListener(_onDriveChanged);
    if (_serviceOn) device.stopKeepAlive();
    super.dispose();
  }

  /// Called when the app returns to the screen.
  Future<void> onResume() async {
    final now = await device.mediaPermission();
    if (now != permission) {
      permission = now;
      _notify();
    }
    if (hasPermission && !running) {
      await scan();
      maybeAutoRun();
    }
  }

  Future<void> requestPermission() async {
    permission = await device.requestMediaPermission();
    _notify();
    if (hasPermission) await scan();
  }

  /// Re-reads the phone's media library.
  Future<void> scan() async {
    if (scanning || !hasPermission) return;
    scanning = true;
    _notify();
    try {
      items = await device.listMedia();
      _sharePhoneCopies();
      if (settings.albums == null && items.isNotEmpty) {
        await _saveSettings(
          settings.copyWith(albums: defaultAlbums(albumsOf(items))),
        );
      }
    } catch (e) {
      notice = 'Could not read the phone\'s photos: $e';
    } finally {
      scanning = false;
      _notify();
    }
  }

  Future<void> _saveSettings(BackupSettings next) async {
    settings = next;
    _notify();
    await _service.writeSetting('backup', next.encode());
  }

  Future<void> setAuto(bool on) async {
    await _saveSettings(settings.copyWith(auto: on));
    _syncSchedule();
    if (on) {
      _askForNotifications();
      maybeAutoRun();
    }
  }

  Future<void> setFrequency(BackupFrequency f) async {
    await _saveSettings(settings.copyWith(frequency: f));
    _syncSchedule();
    maybeAutoRun();
  }

  Future<void> setUnmeteredOnly(bool on) =>
      _saveSettings(settings.copyWith(unmeteredOnly: on));

  Future<void> setChargingOnly(bool on) =>
      _saveSettings(settings.copyWith(chargingOnly: on));

  Future<void> setAlbum(String name, bool on) async {
    final next = {...selectedAlbums};
    on ? next.add(name) : next.remove(name);
    await _saveSettings(settings.copyWith(albums: next));
    _syncSchedule();
  }

  void _askForNotifications() {
    if (_askedNotifications) return;
    _askedNotifications = true;
    device.requestNotificationPermission();
  }

  Future<void> _saveIndex() async {
    final file = _indexFile;
    if (file == null) return;
    // Write to a side file first so a crash cannot leave a half-written index.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(_index.encode(), flush: true);
    await tmp.rename(file.path);
  }

  // ---- Running a backup ----

  /// Starts a backup if automatic backup is on and nothing prevents it.
  void maybeAutoRun() {
    if (settings.auto &&
        !running &&
        hasPermission &&
        backupDue(settings.frequency, lastRun, DateTime.now())) {
      run();
    }
  }

  /// Backs up everything pending. Honours the Wi-Fi and charging settings.
  Future<void> run() async {
    if (running || _disposed) return;
    if (_drive.loading || _drive.error != null) {
      // The drive's contents are not known yet, so nothing can be compared.
      return;
    }
    running = true;
    _stopRequested = false;
    notice = null;
    runDone = 0;
    runTotal = 0;
    _notify();
    try {
      await scan();
      final todo = pending;
      runTotal = todo.length;
      _notify();
      if (todo.isEmpty) {
        await _markRun();
        return;
      }
      _askForNotifications();
      var failuresInARow = 0;
      for (final item in todo) {
        if (_stopRequested) break;
        final status = await device.deviceStatus();
        final blocked = blockedReason(
          settings,
          online: status.online,
          unmetered: status.unmetered,
          charging: status.charging,
        );
        if (blocked != null) {
          notice = blocked;
          break;
        }
        if (File(item.path).existsSync()) {
          final task = _drive.enqueuePath(
            item.path,
            name: item.name,
            size: item.size,
            folder: item.album,
            taken: item.takenAt,
            knownSha: _index.shaOf(item),
          );
          _currentTask = task;
          await task.done;
          _currentTask = null;
          final sha = task.sha;
          if (sha != null) {
            _index.record(item, sha);
            _sharePhoneCopies();
          }
          if (task.status == UploadStatus.failed) {
            if (++failuresInARow >= 3) {
              notice = 'Stopped after repeated errors: ${task.message}';
              break;
            }
          } else {
            failuresInARow = 0;
          }
        }
        runDone++;
        if (runDone % 20 == 0) await _saveIndex();
        _notify();
      }
      if (runDone == todo.length && notice == null && !_stopRequested) {
        await _markRun();
      }
    } catch (e) {
      notice = 'Backup stopped: $e';
    } finally {
      _currentTask = null;
      running = false;
      _index.prune(items);
      try {
        await _saveIndex();
      } on FileSystemException {
        // The index is only a cache; it is rebuilt by hashing again.
      }
      _notify();
      _onDriveChanged();
    }
  }

  Future<void> _markRun() async {
    lastRun = DateTime.now();
    await _service.writeSetting(
      'backup_last_run',
      '${lastRun!.millisecondsSinceEpoch}',
    );
    _syncSchedule();
  }

  /// Stops the run after cancelling the upload in progress.
  Future<void> stop() async {
    if (!running) return;
    _stopRequested = true;
    final task = _currentTask;
    if (task != null) await _drive.cancel(task);
  }

  // ---- Free up space ----

  /// Deletes from the phone the photos and videos that are safely in the
  /// drive. Returns how many were deleted and how many bytes that freed.
  Future<({int count, int bytes})> freeUpSpace() async {
    if (running) {
      throw StateError('Wait for the backup to finish first.');
    }
    // Ask Telegram again what the channel holds, so a file deleted from
    // the channel elsewhere is not treated as backed up.
    await _drive.load();
    if (_drive.error != null) {
      throw StateError('Could not confirm your files with Telegram.');
    }
    await scan();
    final safe = [
      for (final item in freeableItems)
        // The file must still be the one that was hashed.
        if (_sameAsScanned(item)) item,
    ];
    if (safe.isEmpty) return (count: 0, bytes: 0);
    final deleted = await device.deleteMedia(safe);
    final before = {for (final i in safe) i.id: i.size};
    await scan();
    final stillThere = {for (final i in items) i.id};
    final bytes = before.entries
        .where((e) => !stillThere.contains(e.key))
        .fold(0, (sum, e) => sum + e.value);
    _index.prune(items);
    await _saveIndex();
    _drive.recheckLocalPaths();
    _notify();
    return (count: deleted, bytes: bytes);
  }

  bool _sameAsScanned(MediaItem item) {
    try {
      return File(item.path).lengthSync() == item.size;
    } on FileSystemException {
      return false;
    }
  }

  // ---- Keeping uploads alive in the background ----

  /// Runs the background service while anything is uploading, and keeps
  /// its notification text current.
  void _onDriveChanged() {
    if (_disposed) return;
    _widgetTimer ??= Timer(const Duration(seconds: 2), () {
      _widgetTimer = null;
      if (!_disposed) _updateWidget();
    });
    final active = _drive.hasActiveUploads || running;
    final now = DateTime.now();
    if (!active) {
      if (_serviceOn) {
        _serviceOn = false;
        device.stopKeepAlive();
      }
      return;
    }
    final (text, progress) = _serviceText();
    if (!_serviceOn) {
      if (now.difference(_lastServiceAttempt).inSeconds < 20) return;
      _lastServiceAttempt = now;
      device.startKeepAlive(text, progress: progress).then((ok) {
        // If uploads ended while Android was starting the service, stop it.
        if (ok && !(_drive.hasActiveUploads || running) || _disposed) {
          device.stopKeepAlive();
        } else {
          _serviceOn = ok;
        }
      });
    } else if (now.difference(_lastServiceUpdate).inMilliseconds > 1500) {
      _lastServiceUpdate = now;
      device.updateKeepAlive(text, progress: progress);
    }
  }

  (String, int) _serviceText() {
    final uploading = _drive.uploads
        .where((t) => t.status == UploadStatus.uploading)
        .firstOrNull;
    final waiting = running
        ? runTotal - runDone
        : _drive.uploads.where((t) => t.isActive).length;
    final left = waiting > 1 ? ' · $waiting left' : '';
    if (uploading == null) return ('Preparing files$left', -1);
    final size = uploading.size == null
        ? ''
        : ' (${formatBytes(uploading.size!)})';
    return (
      'Uploading ${uploading.name}$size$left',
      ((uploading.progress ?? 0) * 100).round(),
    );
  }
}
