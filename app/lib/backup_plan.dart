// Pure logic for phone backup and "free up space": what needs uploading,
// and what is safe to delete. No Flutter imports, so it is unit-testable.
import 'dart:convert';

/// A photo or video on the phone, as reported by Android's media library.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.time,
    required this.album,
    required this.video,
  });

  factory MediaItem.fromMap(Map<Object?, Object?> m) => MediaItem(
    id: m['id'] as int,
    path: m['path'] as String,
    name: m['name'] as String,
    size: m['size'] as int,
    modified: m['modified'] as int,
    time: m['time'] as int,
    album: m['album'] as String,
    video: m['video'] as bool,
  );

  final int id;
  final String path;
  final String name;
  final int size;

  /// File modification time, seconds since 1970.
  final int modified;

  /// When it was taken (or modified, if unknown), seconds since 1970.
  final int time;
  final String album;
  final bool video;

  /// Identifies this exact version of the file. If the file is edited or
  /// replaced, the key changes and any remembered hash no longer applies.
  String get key => '$path|$size|$modified';

  DateTime get takenAt => DateTime.fromMillisecondsSinceEpoch(time * 1000);
}

/// Remembers the SHA-256 of phone files that have already been hashed, so
/// each file is read only once.
class BackupIndex {
  BackupIndex([Map<String, String>? entries]) : _sha = {...?entries};

  factory BackupIndex.decode(String text) {
    try {
      final map = jsonDecode(text);
      if (map is! Map) return BackupIndex();
      return BackupIndex({
        for (final e in map.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      });
    } on FormatException {
      return BackupIndex();
    }
  }

  final Map<String, String> _sha;

  int get length => _sha.length;
  String? shaOf(MediaItem item) => _sha[item.key];
  void record(MediaItem item, String sha) => _sha[item.key] = sha;

  /// Forgets files that are no longer on the phone (or have changed).
  void prune(Iterable<MediaItem> present) {
    final keys = {for (final i in present) i.key};
    _sha.removeWhere((key, _) => !keys.contains(key));
  }

  String encode() => jsonEncode(_sha);
}

class BackupSettings {
  const BackupSettings({
    this.auto = false,
    this.unmeteredOnly = true,
    this.chargingOnly = false,
    this.albums,
    this.frequency = BackupFrequency.instant,
  });

  factory BackupSettings.decode(String? text) {
    if (text == null) return const BackupSettings();
    try {
      final m = jsonDecode(text);
      if (m is! Map) return const BackupSettings();
      final albums = m['albums'];
      return BackupSettings(
        auto: m['auto'] == true,
        unmeteredOnly: m['unmeteredOnly'] != false,
        chargingOnly: m['chargingOnly'] == true,
        albums: albums is List ? albums.whereType<String>().toSet() : null,
        frequency: BackupFrequency.values.firstWhere(
          (f) => f.name == m['frequency'],
          orElse: () => BackupFrequency.instant,
        ),
      );
    } on FormatException {
      return const BackupSettings();
    }
  }

  /// Back up new photos and videos without being asked.
  final bool auto;

  /// Only upload on an unmetered connection (normally Wi-Fi).
  final bool unmeteredOnly;
  final bool chargingOnly;

  /// Albums to back up. Null until the user's albums have been seen once.
  final Set<String>? albums;

  /// How often automatic backup runs.
  final BackupFrequency frequency;

  BackupSettings copyWith({
    bool? auto,
    bool? unmeteredOnly,
    bool? chargingOnly,
    Set<String>? albums,
    BackupFrequency? frequency,
  }) => BackupSettings(
    auto: auto ?? this.auto,
    unmeteredOnly: unmeteredOnly ?? this.unmeteredOnly,
    chargingOnly: chargingOnly ?? this.chargingOnly,
    albums: albums ?? this.albums,
    frequency: frequency ?? this.frequency,
  );

  String encode() => jsonEncode({
    'auto': auto,
    'unmeteredOnly': unmeteredOnly,
    'chargingOnly': chargingOnly,
    if (albums != null) 'albums': albums!.toList()..sort(),
    'frequency': frequency.name,
  });
}

class AlbumInfo {
  const AlbumInfo(this.name, this.count, this.bytes);
  final String name;
  final int count;
  final int bytes;
}

/// Albums on the phone, biggest first.
List<AlbumInfo> albumsOf(Iterable<MediaItem> items) {
  final count = <String, int>{};
  final bytes = <String, int>{};
  for (final i in items) {
    count[i.album] = (count[i.album] ?? 0) + 1;
    bytes[i.album] = (bytes[i.album] ?? 0) + i.size;
  }
  final albums = [
    for (final name in count.keys) AlbumInfo(name, count[name]!, bytes[name]!),
  ];
  albums.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.name.compareTo(b.name);
  });
  return albums;
}

/// The albums most people want backed up, if the phone has them.
Set<String> defaultAlbums(Iterable<AlbumInfo> albums) {
  const wanted = {'camera', 'whatsapp images', 'whatsapp video', 'screenshots'};
  final picked = {
    for (final a in albums)
      if (wanted.contains(a.name.toLowerCase())) a.name,
  };
  return picked.isNotEmpty ? picked : {for (final a in albums.take(1)) a.name};
}

/// Items in the chosen albums that are not yet known to be in the drive,
/// oldest first so the drive fills in chronological order.
List<MediaItem> pendingBackup(
  Iterable<MediaItem> items, {
  required Set<String> albums,
  required BackupIndex index,
  required Set<String> driveShas,
}) {
  final pending = [
    for (final i in items)
      if (albums.contains(i.album) && !driveShas.contains(index.shaOf(i))) i,
  ];
  pending.sort((a, b) => a.time.compareTo(b.time));
  return pending;
}

/// Items that are safe to delete from the phone: this exact version of the
/// file has been hashed, and the drive holds a file with the same SHA-256
/// and the same size.
List<MediaItem> freeable(
  Iterable<MediaItem> items, {
  required BackupIndex index,
  required Map<String, int> driveSizeBySha,
}) => [
  for (final i in items)
    if (driveSizeBySha[index.shaOf(i)] == i.size) i,
];

/// Why a backup may not run right now, or null if it may.
String? blockedReason(
  BackupSettings settings, {
  required bool online,
  required bool unmetered,
  required bool charging,
}) {
  if (!online) return 'Waiting for an internet connection';
  if (settings.unmeteredOnly && !unmetered) return 'Waiting for Wi-Fi';
  if (settings.chargingOnly && !charging) return 'Waiting for the charger';
  return null;
}

/// How often automatic backup runs.
enum BackupFrequency {
  /// As soon as new photos and videos appear (while the app is running).
  instant('As soon as new photos appear'),
  daily('Once a day'),
  weekly('Once a week');

  const BackupFrequency(this.label);
  final String label;

  Duration? get interval => switch (this) {
    instant => null,
    daily => const Duration(hours: 20),
    weekly => const Duration(days: 6, hours: 20),
  };
}

/// Whether automatic backup should run now. Daily and weekly runs leave a
/// few hours' slack so the run can drift with the user's habits.
bool backupDue(BackupFrequency frequency, DateTime? lastRun, DateTime now) {
  final interval = frequency.interval;
  if (interval == null || lastRun == null) return true;
  return now.difference(lastRun) >= interval;
}

/// "Today 14:05", "Yesterday 09:30", "3 Nov 21:00".
String describeWhen(DateTime t, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final daysAgo = today.difference(day).inDays;
  if (daysAgo == 0) return 'Today $time';
  if (daysAgo == 1) return 'Yesterday $time';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${t.day} ${months[t.month - 1]} $time';
}
