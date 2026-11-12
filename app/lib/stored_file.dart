// The file model and the pure helpers around it. No Flutter or TDLib
// imports here, so everything in this file is unit-testable.

import 'dart:convert';

import 'json.dart';

export 'json.dart';

/// Largest file Telegram accepts: 2000 MiB, or 4000 MiB with Premium.
const int maxUploadBytes = 2000 * 1024 * 1024;
const int maxUploadBytesPremium = 4000 * 1024 * 1024;

enum FileKind { image, video, audio, pdf, document, archive, apk, other }

/// A file stored as a message in the storage channel.
class StoredFile {
  const StoredFile({
    required this.messageId,
    required this.fileId,
    required this.name,
    required this.size,
    required this.date,
    this.sha256,
    this.folder,
    this.taken,
    this.device,
    this.customName,
    this.localPath,
    this.thumbFileId,
    this.miniThumb,
  });

  final int messageId;

  /// TDLib's id for the file. Only valid in the current session.
  final int fileId;

  /// The name shown to the user: [customName] if the file was renamed,
  /// otherwise the name it was uploaded with.
  final String name;

  /// The name given with Rename, stored in the caption. Telegram cannot
  /// change the name of an uploaded file itself.
  final String? customName;
  final int size;

  /// When the photo or video was taken if known ([taken]), otherwise when
  /// it was uploaded. The gallery sorts and groups by this.
  final DateTime date;

  /// Original time of a backed-up photo or video, stored in the caption.
  final DateTime? taken;

  /// Name of the device that uploaded the file, stored in the caption.
  final String? device;

  /// Hash written into the caption at upload time, if any.
  final String? sha256;

  /// Folder name stored in the caption, or null for "no folder".
  final String? folder;

  /// Path of a complete copy on this phone, if TDLib has one.
  final String? localPath;

  /// TDLib's id for a small preview image, if Telegram has one.
  final int? thumbFileId;

  /// A tiny (about 40 px) JPEG preview as base64, shown while the real
  /// thumbnail loads.
  final String? miniThumb;

  FileKind get kind => kindOf(name);

  StoredFile _copy({
    String? Function()? localPath,
    String? Function()? folder,
    String? newName,
  }) => StoredFile(
    messageId: messageId,
    fileId: fileId,
    name: newName ?? name,
    size: size,
    date: date,
    sha256: sha256,
    folder: folder == null ? this.folder : folder(),
    taken: taken,
    device: device,
    customName: newName ?? customName,
    localPath: localPath == null ? this.localPath : localPath(),
    thumbFileId: thumbFileId,
    miniThumb: miniThumb,
  );

  StoredFile withLocalPath(String? path) => _copy(localPath: () => path);
  StoredFile withFolder(String? name) => _copy(folder: () => name);

  /// The file under a new name. [newName] must already be cleaned with
  /// [cleanNewName].
  StoredFile renamed(String newName) => _copy(newName: newName);

  /// The caption TeDrive writes for this file.
  String get caption => buildCaption(
    sha256: sha256,
    folder: folder,
    taken: taken,
    device: device,
    name: customName,
  );

  /// Turns a TDLib message into a [StoredFile], or null if it has no file.
  static StoredFile? fromMessage(Json message) {
    final content = message['content'] as Json;
    final id = message['id'] as int;
    Json? file;
    String? name;
    int? thumb;
    Json? mini;
    void media(Json holder, String key) {
      file = holder[key] as Json;
      name = holder['file_name'] as String?;
      thumb = _thumbnailFileId(holder['thumbnail'] as Json?);
      mini = holder['minithumbnail'] as Json?;
    }

    switch (content['@type']) {
      case 'messageDocument':
        media(content['document'] as Json, 'document');
      case 'messageVideo':
        media(content['video'] as Json, 'video');
      case 'messageAudio':
        media(content['audio'] as Json, 'audio');
      case 'messageAnimation':
        media(content['animation'] as Json, 'animation');
      case 'messagePhoto':
        final photo = content['photo'] as Json;
        final sizes = (photo['sizes'] as List).cast<Json>();
        if (sizes.isNotEmpty) {
          file = sizes.last['photo'] as Json;
          // The smallest size that is still sharp in a grid cell.
          final preview = sizes.firstWhere(
            (s) => ((s['width'] as int?) ?? 0) >= 200,
            orElse: () => sizes.last,
          );
          thumb = (preview['photo'] as Json)['id'] as int?;
        }
        name = 'photo_$id.jpg';
        mini = photo['minithumbnail'] as Json?;
    }
    final f = file;
    if (f == null) return null;
    final caption = (content['caption'] as Json?)?['text'] as String? ?? '';
    final local = f['local'] as Json?;
    final path = local?['path'] as String? ?? '';
    final n = name;
    final seconds = int.tryParse(
      _timePattern.firstMatch(caption)?.group(1) ?? '',
    );
    final taken = seconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final uploadedName = (n == null || n.isEmpty) ? 'file_$id' : n;
    final customName = cleanNewName(
      _namePattern.firstMatch(caption)?.group(1) ?? '',
      original: uploadedName,
    );
    return StoredFile(
      messageId: id,
      fileId: f['id'] as int,
      name: customName ?? uploadedName,
      customName: customName,
      size: fileSize(f),
      date:
          taken ??
          DateTime.fromMillisecondsSinceEpoch((message['date'] as int) * 1000),
      taken: taken,
      device: normalizeFolder(_devicePattern.firstMatch(caption)?.group(1)),
      sha256: _shaPattern.firstMatch(caption)?.group(1),
      folder: normalizeFolder(_folderPattern.firstMatch(caption)?.group(1)),
      localPath: local?['is_downloading_completed'] == true && path.isNotEmpty
          ? path
          : null,
      thumbFileId: thumb,
      miniThumb: mini?['data'] as String?,
    );
  }

  /// Only still-image thumbnails can be drawn in the grid.
  static int? _thumbnailFileId(Json? thumbnail) {
    if (thumbnail == null) return null;
    const drawable = {
      'thumbnailFormatJpeg',
      'thumbnailFormatPng',
      'thumbnailFormatWebp',
      'thumbnailFormatGif',
    };
    final format = (thumbnail['format'] as Json?)?['@type'];
    if (!drawable.contains(format)) return null;
    return (thumbnail['file'] as Json?)?['id'] as int?;
  }
}

final _shaPattern = RegExp(r'sha256:([0-9a-f]{64})');
final _folderPattern = RegExp(r'^folder:(.*)$', multiLine: true);

/// Captions carry TeDrive's metadata, one `key:value` per line, so the
/// whole catalogue can be rebuilt from the channel history alone.
String buildCaption({
  String? sha256,
  String? folder,
  DateTime? taken,
  String? device,
  String? name,
}) => [
  if (sha256 != null) 'sha256:$sha256',
  if (normalizeFolder(folder) != null) 'folder:${normalizeFolder(folder)}',
  if (taken != null) 'time:${taken.millisecondsSinceEpoch ~/ 1000}',
  if (normalizeFolder(device) != null) 'device:${normalizeFolder(device)}',
  if (name != null && name.trim().isNotEmpty) 'name:${name.trim()}',
].join('\n');

final _namePattern = RegExp(r'^name:(.*)$', multiLine: true);

/// Cleans a name typed in the Rename box. Path separators and line breaks
/// are removed, and the original extension is put back if the user left it
/// off, so a renamed photo is still recognised as a photo. Returns null
/// when nothing usable is left.
String? cleanNewName(String typed, {required String original}) {
  var name = typed
      .replaceAll(RegExp(r'[\\/\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isEmpty || name == '.' || name == '..') return null;
  if (name.length > 120) name = name.substring(0, 120).trim();
  final dot = original.lastIndexOf('.');
  final extension = dot > 0 ? original.substring(dot) : '';
  if (extension.isNotEmpty &&
      !name.toLowerCase().endsWith(extension.toLowerCase())) {
    name = '$name$extension';
  }
  return name;
}

final _devicePattern = RegExp(r'^device:(.*)$', multiLine: true);
final _timePattern = RegExp(r'^time:(\d{1,12})$', multiLine: true);

/// Newest first; files with the same time keep their channel order.
List<StoredFile> sortNewestFirst(List<StoredFile> files) {
  final indexed = [for (var i = 0; i < files.length; i++) (i, files[i])];
  indexed.sort((a, b) {
    final byDate = b.$2.date.compareTo(a.$2.date);
    return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Cleans a folder name typed by the user. Returns null for "no folder".
String? normalizeFolder(String? name) {
  if (name == null) return null;
  final oneLine = name.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty) return null;
  return oneLine.length > 40 ? oneLine.substring(0, 40).trim() : oneLine;
}

/// Folder names in use, sorted alphabetically ignoring case.
List<String> foldersOf(Iterable<StoredFile> files) {
  final names = {
    for (final f in files)
      if (f.folder != null) f.folder!,
  }.toList();
  names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return names;
}

/// The tabs of the gallery.
enum Category { all, photos, videos, audio, documents, other }

bool inCategory(StoredFile file, Category category) => switch (category) {
  Category.all => true,
  Category.photos => file.kind == FileKind.image,
  Category.videos => file.kind == FileKind.video,
  Category.audio => file.kind == FileKind.audio,
  Category.documents =>
    file.kind == FileKind.pdf || file.kind == FileKind.document,
  Category.other =>
    file.kind == FileKind.archive ||
        file.kind == FileKind.apk ||
        file.kind == FileKind.other,
};

/// Applies the gallery's category, folder and search filters together.
List<StoredFile> filterFiles(
  List<StoredFile> files, {
  Category category = Category.all,
  String? folder,
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  if (category == Category.all && folder == null && q.isEmpty) return files;
  return files
      .where(
        (f) =>
            inCategory(f, category) &&
            (folder == null || f.folder == folder) &&
            (q.isEmpty || f.name.toLowerCase().contains(q)),
      )
      .toList();
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Splits files (already newest first) into month sections for the grid.
List<({String label, List<StoredFile> files})> groupByMonth(
  List<StoredFile> files,
) {
  final groups = <({String label, List<StoredFile> files})>[];
  int? year, month;
  for (final f in files) {
    if (f.date.year != year || f.date.month != month) {
      year = f.date.year;
      month = f.date.month;
      groups.add((label: '${_monthNames[month - 1]} $year', files: []));
    }
    groups.last.files.add(f);
  }
  return groups;
}

/// Size of a TDLib file object; falls back to the expected size while the
/// real one is still unknown.
int fileSize(Json file) {
  final size = file['size'] as int? ?? 0;
  return size != 0 ? size : file['expected_size'] as int? ?? 0;
}

FileKind kindOf(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'heic' ||
    'heif' ||
    'bmp' => FileKind.image,
    'mp4' ||
    'mkv' ||
    'mov' ||
    'webm' ||
    '3gp' ||
    'avi' ||
    'm4v' => FileKind.video,
    'mp3' ||
    'm4a' ||
    'aac' ||
    'ogg' ||
    'opus' ||
    'wav' ||
    'flac' ||
    'amr' => FileKind.audio,
    'pdf' => FileKind.pdf,
    'doc' ||
    'docx' ||
    'xls' ||
    'xlsx' ||
    'ppt' ||
    'pptx' ||
    'txt' ||
    'csv' ||
    'odt' => FileKind.document,
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => FileKind.archive,
    'apk' => FileKind.apk,
    _ => FileKind.other,
  };
}

String formatBytes(int n) {
  const kb = 1024, mb = kb * 1024, gb = mb * 1024;
  if (n < kb) return '$n B';
  if (n < mb) return '${(n / kb).toStringAsFixed(1)} KB';
  if (n < gb) return '${(n / mb).toStringAsFixed(1)} MB';
  return '${(n / gb).toStringAsFixed(2)} GB';
}

String formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]} ${d.year}, '
      '${two(d.hour)}:${two(d.minute)}';
}

/// A file name that is safe to use as a single path segment.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
  return cleaned.isEmpty || cleaned == '.' || cleaned == '..'
      ? 'file'
      : cleaned;
}

/// Case-insensitive name search. An empty query matches everything.
List<StoredFile> searchFiles(List<StoredFile> files, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return files;
  return files.where((f) => f.name.toLowerCase().contains(q)).toList();
}

/// MIME type for a file name, used when sharing and streaming.
String mimeOf(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return _mimeTypes[ext] ?? 'application/octet-stream';
}

const _mimeTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mkv': 'video/x-matroska',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'avi': 'video/x-msvideo',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'amr': 'audio/amr',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'csv': 'text/csv',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
  'apk': 'application/vnd.android.package-archive',
};

/// The catalogue as the native side expects it.
String encodePickerCatalogue(
  List<StoredFile> files,
  Map<int, String> thumbPaths,
) => jsonEncode({
  'files': [
    for (final f in files)
      {
        'id': f.messageId,
        'name': f.name,
        'size': f.size,
        'time': f.date.millisecondsSinceEpoch,
        'folder': f.folder,
        'mime': mimeOf(f.name),
        'path': f.localPath,
        'thumb': thumbPaths[f.messageId],
      },
  ],
});

const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Today", "Yesterday", "Tue, 10 Nov", or "10 Nov 2025" for other years.
String dayLabel(DateTime day, DateTime now) {
  final d = DateTime(day.year, day.month, day.day);
  final today = DateTime(now.year, now.month, now.day);
  final daysAgo = today.difference(d).inHours ~/ 24;
  if (d == today) return 'Today';
  if (daysAgo == 1 && d.isBefore(today)) return 'Yesterday';
  final date = '${d.day} ${_shortMonths[d.month - 1]}';
  return d.year == now.year
      ? '${_weekdays[d.weekday - 1]}, $date'
      : '$date ${d.year}';
}

/// Splits files (already newest first) into one section per day, the way
/// a phone gallery does.
List<({String label, List<StoredFile> files})> groupByDay(
  List<StoredFile> files, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final groups = <({String label, List<StoredFile> files})>[];
  DateTime? current;
  for (final f in files) {
    final day = DateTime(f.date.year, f.date.month, f.date.day);
    if (day != current) {
      current = day;
      groups.add((label: dayLabel(day, clock), files: []));
    }
    groups.last.files.add(f);
  }
  return groups;
}

/// Totals shown on the account page.
class DriveStats {
  DriveStats(Iterable<StoredFile> files) {
    for (final f in files) {
      count++;
      bytes += f.size;
      if (f.localPath != null) {
        localCount++;
        localBytes += f.size;
      }
      final category = Category.values.firstWhere(
        (c) => c != Category.all && inCategory(f, c),
      );
      final c = byCategory[category] ?? (count: 0, bytes: 0);
      byCategory[category] = (count: c.count + 1, bytes: c.bytes + f.size);
      final device = f.device ?? 'Unknown device';
      final d = byDevice[device] ?? (count: 0, bytes: 0);
      byDevice[device] = (count: d.count + 1, bytes: d.bytes + f.size);
      if (oldest == null || f.date.isBefore(oldest!)) oldest = f.date;
    }
  }

  int count = 0;
  int bytes = 0;

  /// Files with a copy on this device.
  int localCount = 0;
  int localBytes = 0;
  DateTime? oldest;
  final Map<Category, ({int count, int bytes})> byCategory = {};
  final Map<String, ({int count, int bytes})> byDevice = {};
}
