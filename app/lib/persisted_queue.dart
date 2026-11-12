// Persisted upload queue: saves pending uploads so they survive phone reboots,
// app restarts, and process kills by the OS.

import 'dart:convert';
import 'dart:io';

typedef DirectoryResolver = Future<Directory> Function();

class QueuedUploadItem {
  const QueuedUploadItem({
    required this.path,
    required this.name,
    required this.size,
    this.folder,
    this.taken,
    this.knownSha,
    this.isVault = false,
  });

  final String path;
  final String name;
  final int size;
  final String? folder;
  final DateTime? taken;
  final String? knownSha;
  final bool isVault;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'size': size,
    if (folder != null) 'folder': folder,
    if (taken != null) 'taken': taken!.millisecondsSinceEpoch,
    if (knownSha != null) 'sha': knownSha,
    if (isVault) 'vault': true,
  };

  static QueuedUploadItem? fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String?;
    final name = json['name'] as String?;
    final size = json['size'] as int?;
    if (path == null || name == null || size == null) return null;
    final takenMs = json['taken'] as int?;
    return QueuedUploadItem(
      path: path,
      name: name,
      size: size,
      folder: json['folder'] as String?,
      taken: takenMs != null ? DateTime.fromMillisecondsSinceEpoch(takenMs) : null,
      knownSha: json['sha'] as String?,
      isVault: json['vault'] == true,
    );
  }
}

class PersistedUploadQueue {
  PersistedUploadQueue._();
  static final PersistedUploadQueue instance = PersistedUploadQueue._();

  static const _fileName = 'tedrive_pending_uploads.json';

  DirectoryResolver? directoryProvider;

  Future<File?> _getFile() async {
    if (directoryProvider == null) return null;
    final dir = await directoryProvider!();
    return File('${dir.path}/$_fileName');
  }

  Future<void> save(List<QueuedUploadItem> items) async {
    try {
      final file = await _getFile();
      if (file == null) return;
      final data = jsonEncode(items.map((i) => i.toJson()).toList());
      await file.writeAsString(data, flush: true);
    } catch (_) {}
  }

  Future<List<QueuedUploadItem>> load() async {
    try {
      final file = await _getFile();
      if (file == null || !await file.exists()) return const [];
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as List;
      final results = <QueuedUploadItem>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final parsed = QueuedUploadItem.fromJson(item);
          if (parsed != null && File(parsed.path).existsSync()) {
            results.add(parsed);
          }
        }
      }
      return results;
    } catch (_) {
      return const [];
    }
  }

  Future<void> clear() async {
    try {
      final file = await _getFile();
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}
