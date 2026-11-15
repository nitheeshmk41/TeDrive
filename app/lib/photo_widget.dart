// Keeps the home-screen photo widget supplied with photos: picks some at
// random from what the user chose (all photos, an album, people…) and
// hands small copies to the widget, which shows them while the app is
// closed.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'content_index.dart';
import 'device.dart' as device;
import 'drive_controller.dart';
import 'error_log.dart';
import 'photo_widget_plan.dart';
import 'stored_file.dart';
import 'tedrive_service.dart';

class PhotoWidgetController extends ChangeNotifier {
  PhotoWidgetController(this._service, this._drive, this._contents);

  final TeDriveService _service;
  final DriveController _drive;
  final ContentIndex _contents;

  /// A new set of photos this often, when the app is opened.
  static const _refreshEvery = Duration(hours: 3);

  WidgetSource source = WidgetSource.all;
  bool _busy = false;
  bool _disposed = false;

  static bool get available => device.isAndroid;

  /// How many photos the current choice has to draw from.
  int countFor(WidgetSource source) =>
      widgetCandidates(_drive.files, source, _contents.contentOf).length;

  Future<void> init() async {
    if (!available) return;
    source = WidgetSource.decode(
      await _service.readSetting('photo_widget_source'),
    );
    await refreshIfDue();
  }

  /// A new set of photos if the last one is old. Called when the app
  /// starts and whenever it comes back to the screen.
  Future<void> refreshIfDue() async {
    if (!available || _disposed) return;
    final last = DateTime.tryParse(
      await _service.readSetting('photo_widget_refreshed') ?? '',
    );
    if (last == null || DateTime.now().difference(last) >= _refreshEvery) {
      await refresh();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Changes what the widget shows and fills it at once. Returns how many
  /// photos the widget now has.
  Future<int> setSource(WidgetSource next) async {
    source = next;
    if (!_disposed) notifyListeners();
    await _service.writeSetting('photo_widget_source', next.encode());
    return refresh();
  }

  /// Gives the widget a new random set. Returns how many it now has.
  Future<int> refresh() async {
    if (!available || _busy || _disposed) return 0;
    _busy = true;
    try {
      final picked = pickWidgetPhotos(
        widgetCandidates(_drive.files, source, _contents.contentOf),
        isOnPhone: (f) => _drive.localCopyOf(f) != null,
        random: Random(),
        max: 40,
      );
      final paths = <String>[];
      final captions = <String>[];
      final ids = <int>[];
      for (final StoredFile f in picked) {
        final path =
            _drive.localCopyOf(f) ??
            await _drive.thumbnail(f).catchError((_) => null);
        if (path == null) continue;
        paths.add(path);
        captions.add(widgetCaption(f));
        ids.add(f.messageId);
      }
      // Nothing to show yet (a new drive, or photos still being looked
      // at): leave the widget as it is and try again next time.
      if (paths.isEmpty) return 0;
      final saved = await device.setWidgetPhotos(paths, captions, ids);
      if (saved > 0) {
        await _service.writeSetting(
          'photo_widget_refreshed',
          DateTime.now().toIso8601String(),
        );
      }
      return saved;
    } on Object catch (e, st) {
      logError('photo widget', e, st);
      return 0;
    } finally {
      _busy = false;
    }
  }
}
