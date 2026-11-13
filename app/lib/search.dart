// Search and smart albums. Pure logic, no Flutter, so it is unit-testable.

import 'stored_file.dart';

/// What was found inside a photo, on the phone: things ("Beach", "Food"),
/// printed text, and how many faces.
class PhotoContent {
  const PhotoContent({this.labels = const [], this.text = '', this.faces = 0});

  factory PhotoContent.fromJson(Map<Object?, Object?> m) => PhotoContent(
    labels: (m['l'] as List? ?? const []).whereType<String>().toList(),
    text: m['t'] as String? ?? '',
    faces: m['f'] as int? ?? 0,
  );

  final List<String> labels;
  final String text;
  final int faces;

  /// Enough printed text to be a document, screenshot, receipt or sign.
  bool get isTexty => text.length >= 60;

  Map<String, Object> toJson() => {
    if (labels.isNotEmpty) 'l': labels,
    if (text.isNotEmpty) 't': text,
    if (faces > 0) 'f': faces,
  };

  /// Everything a search word may match, lower case.
  String get searchText => [
    ...labels,
    text,
    if (faces >= 1) 'people person face faces',
    if (faces == 1) 'selfie portrait',
    if (faces >= 2) 'group together',
    if (isTexty) 'text document writing',
  ].join(' ').toLowerCase();
}

const _months = [
  'january', 'february', 'march', 'april', 'may', 'june', //
  'july', 'august', 'september', 'october', 'november', 'december',
];

String _kindWords(FileKind kind) => switch (kind) {
  FileKind.image => 'photo image picture pic',
  FileKind.video => 'video movie clip',
  FileKind.audio => 'audio music song sound',
  FileKind.pdf => 'pdf document',
  FileKind.document => 'document doc',
  FileKind.archive => 'archive zip',
  FileKind.apk => 'apk app',
  FileKind.other => 'other',
};

/// Everything about [file] that a search word may match: its name, album,
/// type, date, device and camera, and what is in the photo.
String searchTextOf(StoredFile file, [PhotoContent? content]) {
  final when = file.taken ?? file.date;
  return [
    file.name,
    file.folder ?? '',
    _kindWords(file.kind),
    '${when.year}',
    _months[when.month - 1],
    file.device ?? '',
    file.camera ?? '',
    if (file.starred) 'starred favourite favorite',
    if (file.location != null) 'location map place',
    content?.searchText ?? '',
  ].join(' ').toLowerCase();
}

/// The words of a search, lower case.
List<String> searchWords(String query) => query
    .toLowerCase()
    .split(RegExp(r'[\s,]+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// Whether every word of [query] is found somewhere in [file]. "photos"
/// also finds "photo", and "beaches" finds "beach".
bool matchesSearch(StoredFile file, String query, [PhotoContent? content]) {
  final words = searchWords(query);
  if (words.isEmpty) return true;
  final text = searchTextOf(file, content);
  return words.every((w) => _variants(w).any(text.contains));
}

Iterable<String> _variants(String word) sync* {
  yield word;
  if (word.length > 3 && word.endsWith('es')) {
    yield word.substring(0, word.length - 2);
  }
  if (word.length > 2 && word.endsWith('s')) {
    yield word.substring(0, word.length - 1);
  }
}

/// A group of photos found by what is in them. Opening it runs [query].
class SmartAlbum {
  const SmartAlbum(this.title, this.query, this.files);
  final String title;
  final String query;
  final List<StoredFile> files;
}

/// Albums made from what is in the photos: people first, then text, then
/// the most common things. Only groups with at least [minPhotos] photos.
List<SmartAlbum> smartAlbums(
  Iterable<StoredFile> photos,
  PhotoContent? Function(StoredFile file) contentOf, {
  int maxThings = 12,
  int minPhotos = 3,
}) {
  final people = <StoredFile>[];
  final single = <StoredFile>[];
  final groups = <StoredFile>[];
  final texty = <StoredFile>[];
  final byLabel = <String, List<StoredFile>>{};
  for (final f in photos) {
    final c = contentOf(f);
    if (c == null) continue;
    if (c.faces >= 1) people.add(f);
    if (c.faces == 1) single.add(f);
    if (c.faces >= 2) groups.add(f);
    if (c.isTexty) texty.add(f);
    for (final label in c.labels.toSet()) {
      (byLabel[label] ??= []).add(f);
    }
  }
  final things =
      byLabel.entries.where((e) => e.value.length >= minPhotos).toList()
        ..sort((a, b) {
          final byCount = b.value.length.compareTo(a.value.length);
          return byCount != 0 ? byCount : a.key.compareTo(b.key);
        });
  return [
    if (people.length >= minPhotos) SmartAlbum('People', 'people', people),
    if (single.length >= minPhotos)
      SmartAlbum('Selfies & portraits', 'portrait', single),
    if (groups.length >= minPhotos) SmartAlbum('Groups', 'group', groups),
    if (texty.length >= minPhotos)
      SmartAlbum('Text & documents', 'text', texty),
    for (final e in things.take(maxThings))
      SmartAlbum(e.key, e.key.toLowerCase(), e.value),
  ];
}
