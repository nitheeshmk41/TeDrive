// Search photos by what is in them: labels ("beach", "food", "receipt"…)
// and printed text, worked out on the phone by Google ML Kit. Nothing is
// sent anywhere; the results stay in a file on this device.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'device.dart' as device;
import 'drive_controller.dart';
import 'stored_file.dart';

class ContentIndex extends ChangeNotifier {
  ContentIndex(this._drive);

  final DriveController _drive;

  /// Message id -> lower-case labels and text found in the photo.
  final Map<int, String> _found = {};

  /// Photos that could not be read this session (no preview yet, say).
  final Set<int> _skipped = {};
  File? _file;
  bool _disposed = false;
  bool _running = false;
  int _unsaved = 0;

  /// This device can look inside photos.
  static bool get available => device.isAndroid;

  List<StoredFile> get _photos => [
    for (final f in _drive.files)
      if (f.kind == FileKind.image && !f.isVault) f,
  ];

  /// How many photos have been looked at, of how many.
  ({int done, int total}) get progress {
    final photos = _photos;
    return (
      done: photos.where((f) => _found.containsKey(f.messageId)).length,
      total: photos.length,
    );
  }

  /// Whether [file]'s contents match the search [query].
  bool matches(StoredFile file, String query) {
    final text = _found[file.messageId];
    if (text == null) return false;
    final words = query.toLowerCase().split(RegExp(r'\s+'));
    return words.every((w) => w.isEmpty || text.contains(w));
  }

  Future<void> init() async {
    if (!available) return;
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/content_index.json');
    try {
      if (_file!.existsSync()) {
        final m = jsonDecode(await _file!.readAsString());
        if (m is Map && m['items'] is Map) {
          for (final e in (m['items'] as Map).entries) {
            final id = int.tryParse('${e.key}');
            if (id != null && e.value is String) _found[id] = e.value as String;
          }
        }
      }
    } on Object {
      // A damaged index is rebuilt.
    }
    _drive.addListener(_kick);
    _kick();
  }

  @override
  void dispose() {
    _disposed = true;
    _drive.removeListener(_kick);
    _save();
    super.dispose();
  }

  void _kick() {
    if (_running || _disposed || _drive.loading) return;
    _run();
  }

  Future<void> _run() async {
    _running = true;
    try {
      while (!_disposed) {
        final next = _photos
            .where(
              (f) =>
                  !_found.containsKey(f.messageId) &&
                  !_skipped.contains(f.messageId),
            )
            .firstOrNull;
        if (next == null) break;
        // Uploads and the user's own downloads go first.
        while (_drive.hasActiveUploads && !_disposed) {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        final path =
            _drive.localCopyOf(next) ??
            await _drive.thumbnail(next).catchError((_) => null);
        final result = path == null ? null : await device.analyzeImage(path);
        if (result == null) {
          _skipped.add(next.messageId);
        } else {
          _found[next.messageId] = [
            ...result.labels,
            result.text.replaceAll(RegExp(r'\s+'), ' '),
          ].join(' ').toLowerCase().trim();
          if (++_unsaved >= 25) await _save();
          if (!_disposed) notifyListeners();
        }
        // Stay light on the phone.
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
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
          'v': 1,
          'items': {for (final e in _found.entries) '${e.key}': e.value},
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } on FileSystemException {
      // Only a cache.
    }
  }
}
