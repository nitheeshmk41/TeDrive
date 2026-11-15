// Looks inside the drive's photos and video previews, on the phone
// (Google ML Kit, models
// built into the app): things ("beach", "food"), printed text and faces.
// Search and the smart albums use it. Nothing is sent anywhere; the
// results stay in a file on this device.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'device.dart' as device;
import 'drive_controller.dart';
import 'error_log.dart';
import 'search.dart';
import 'stored_file.dart';

class ContentIndex extends ChangeNotifier {
  ContentIndex(this._drive);

  /// Raised when what is stored per photo changes, so old results are redone.
  static const _version = 3;

  final DriveController _drive;

  /// Message id -> what was found in that photo.
  final Map<int, PhotoContent> _found = {};

  /// Photos that could not be read (no preview yet, say), and when, so
  /// they are tried again later.
  final Map<int, DateTime> _skipped = {};
  static const _retryAfter = Duration(minutes: 10);
  File? _file;
  bool _disposed = false;
  bool _running = false;
  int _unsaved = 0;
  List<SmartAlbum>? _albums;

  /// This device can look inside photos.
  static bool get available => device.isAndroid;

  /// Photos, and videos (by their preview picture).
  List<StoredFile> get _photos => [
    for (final f in _drive.files)
      if ((f.kind == FileKind.image || f.kind == FileKind.video) && !f.isVault)
        f,
  ];

  /// How many photos and videos have been looked at, of how many, and how
  /// many of the rest could not be read so far.
  ({int done, int total, int unread}) get progress {
    final photos = _photos;
    return (
      done: photos.where((f) => _found.containsKey(f.messageId)).length,
      total: photos.length,
      unread: photos.where((f) => _skipped.containsKey(f.messageId)).length,
    );
  }

  /// What is in [file], if it has been looked at.
  PhotoContent? contentOf(StoredFile file) => _found[file.messageId];

  /// People, text and the most common things, as albums.
  List<SmartAlbum> get albums => _albums ??= smartAlbums(_photos, contentOf);

  Future<void> init() async {
    if (!available) return;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/content_index.json');
    try {
      if (_file!.existsSync()) {
        final m = jsonDecode(await _file!.readAsString());
        if (m is Map && m['v'] == _version && m['items'] is Map) {
          for (final e in (m['items'] as Map).entries) {
            final id = int.tryParse('${e.key}');
            if (id != null && e.value is Map) {
              _found[id] = PhotoContent.fromJson(e.value as Map);
            }
          }
        }
      }
    } on Object {
      // A damaged index is rebuilt.
    }
    _drive.addListener(_onDriveChanged);
    _onDriveChanged();
  }

  @override
  void dispose() {
    _disposed = true;
    _drive.removeListener(_onDriveChanged);
    _save();
    super.dispose();
  }

  void _onDriveChanged() {
    _albums = null;
    if (_running || _disposed || _drive.loading) return;
    _run();
  }

  bool _waiting(StoredFile f) {
    if (_found.containsKey(f.messageId)) return false;
    final skipped = _skipped[f.messageId];
    return skipped == null || DateTime.now().difference(skipped) >= _retryAfter;
  }

  /// What is in [file]: from the copy on this phone if there is one (sharp
  /// enough for faces and small text), otherwise from its preview.
  Future<PhotoContent?> _lookAt(StoredFile file) async {
    final local = file.kind == FileKind.image ? _drive.localCopyOf(file) : null;
    var result = local == null ? null : await device.analyzeImage(local);
    if (result == null) {
      final thumb = await _drive.thumbnail(file).catchError((_) => null);
      if (thumb != null && thumb != local) {
        result = await device.analyzeImage(thumb);
      }
    }
    if (result == null) return null;
    return PhotoContent(
      labels: result.labels,
      text: result.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      faces: result.faces,
    );
  }

  Future<void> _run() async {
    _running = true;
    try {
      while (!_disposed) {
        final queue = _photos.where(_waiting).toList();
        if (queue.isEmpty) break;
        for (final next in queue) {
          // Uploads go first.
          while (_drive.hasActiveUploads && !_disposed) {
            await Future<void>.delayed(const Duration(seconds: 5));
          }
          if (_disposed) break;
          final content = await _lookAt(next);
          if (content == null) {
            _skipped[next.messageId] = DateTime.now();
          } else {
            _skipped.remove(next.messageId);
            _found[next.messageId] = content;
            _albums = null;
            if (++_unsaved >= 25) await _save();
            if (!_disposed) notifyListeners();
          }
          // Stay light on the phone.
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    } on Object catch (e, st) {
      logError('content index', e, st);
    } finally {
      _running = false;
      await _save();
    }
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null || _unsaved == 0) return;
    _unsaved = 0;
    final present = {for (final f in _drive.allFiles) f.messageId};
    if (present.isNotEmpty) {
      _found.removeWhere((id, _) => !present.contains(id));
    }
    try {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'v': _version,
          'items': {
            for (final e in _found.entries) '${e.key}': e.value.toJson(),
          },
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } on FileSystemException {
      // Only a cache.
    }
  }
}
