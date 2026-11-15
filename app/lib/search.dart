// Search and smart albums. Pure logic, no Flutter, so it is unit-testable.

import 'dart:convert';
import 'dart:typed_data';

import 'stored_file.dart';

/// What was found inside a photo, on the phone: things ("Beach", "Food"),
/// printed text, and how many faces.
class PhotoContent {
  const PhotoContent({
    this.labels = const [],
    this.text = '',
    this.faces = 0,
    this.prints = const [],
  });

  factory PhotoContent.fromJson(Map<Object?, Object?> m) => PhotoContent(
    labels: (m['l'] as List? ?? const []).whereType<String>().toList(),
    text: m['t'] as String? ?? '',
    faces: m['f'] as int? ?? 0,
    prints: [
      for (final p in (m['p'] as List? ?? const []).whereType<String>())
        if (_decodePrint(p) case final print?) print,
    ],
  );

  final List<String> labels;
  final String text;
  final int faces;

  /// A fingerprint per face, in the same order as the saved face pictures
  /// (`<message id>_<n>.jpg`). Faces that look alike have close prints.
  final List<Int8List> prints;

  /// Enough printed text to be a document, screenshot, receipt or sign.
  bool get isTexty => text.length >= 60;

  Map<String, Object> toJson() => {
    if (labels.isNotEmpty) 'l': labels,
    if (text.isNotEmpty) 't': text,
    if (faces > 0) 'f': faces,
    if (prints.isNotEmpty)
      'p': [for (final p in prints) base64Encode(Uint8List.sublistView(p))],
  };

  /// Words a search may match by their start, lower case: what was found,
  /// plus other words for the same thing ("kitten" finds a cat).
  Set<String> get keywords => {
    for (final label in labels) ...[
      ..._wordsOf(label),
      ...?_related[label.toLowerCase()],
    ],
    if (faces >= 1) ...['people', 'person', 'face', 'faces'],
    if (faces == 1) ...['selfie', 'portrait'],
    if (faces >= 2) ...['group', 'together', 'friends'],
    if (isTexty) ...['text', 'document', 'writing'],
  };
}

Int8List? _decodePrint(String text) {
  try {
    final bytes = base64Decode(text);
    return bytes.isEmpty ? null : Int8List.sublistView(bytes);
  } on FormatException {
    return null;
  }
}

final _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

Iterable<String> _wordsOf(String text) =>
    text.toLowerCase().split(_notWord).where((w) => w.isNotEmpty);

/// The words a photo adds to a search, worked out once per photo.
final _photoWords = Expando<Set<String>>();

Set<String> _photoWordsOf(PhotoContent content) =>
    _photoWords[content] ??= {...content.keywords, ..._wordsOf(content.text)};

/// Other words people search with, for things the phone finds in photos.
/// Keys are the labels it gives, lower case. A label not listed here is
/// still found by its own name.
const _related = <String, List<String>>{
  'cat': ['kitten', 'kitty', 'pet', 'animal'],
  'dog': ['puppy', 'pet', 'animal'],
  'pet': ['animal'],
  'bird': ['animal'],
  'horse': ['animal'],
  'cattle': ['cow', 'animal'],
  'bear': ['animal'],
  'butterfly': ['insect'],
  'food': ['meal', 'eat', 'eating', 'dish', 'lunch', 'dinner', 'breakfast'],
  'cuisine': ['food', 'meal', 'dish'],
  'fast food': ['food', 'burger', 'snack'],
  'cake': ['food', 'dessert', 'birthday'],
  'pizza': ['food'],
  'fruit': ['food'],
  'vegetable': ['food'],
  'coffee': ['drink', 'cafe'],
  'cup': ['drink'],
  'juice': ['drink'],
  'sky': ['outdoor', 'outside'],
  'cloud': ['sky'],
  'sunset': ['sky', 'evening', 'sunrise'],
  'beach': ['sea', 'ocean', 'sand', 'shore', 'coast'],
  'sea': ['ocean', 'beach', 'water'],
  'lake': ['water'],
  'river': ['water'],
  'waterfall': ['water', 'falls'],
  'mountain': ['hill', 'hills', 'trek', 'nature'],
  'forest': ['trees', 'woods', 'nature'],
  'tree': ['nature'],
  'plant': ['nature', 'green'],
  'flower': ['nature', 'bloom', 'garden'],
  'garden': ['nature'],
  'snow': ['winter'],
  'car': ['vehicle', 'auto'],
  'vehicle': ['car', 'transport'],
  'motorcycle': ['bike', 'vehicle'],
  'bicycle': ['bike', 'cycle'],
  'bus': ['vehicle'],
  'aircraft': ['plane', 'airplane', 'flight'],
  'boat': ['ship'],
  'building': ['house', 'architecture'],
  'skyscraper': ['building', 'city', 'tower'],
  'cityscape': ['city'],
  'room': ['indoor', 'inside', 'home'],
  'bedroom': ['room', 'home'],
  'couch': ['sofa', 'home'],
  'baby': ['child', 'kid', 'infant'],
  'toy': ['kid', 'child'],
  'smile': ['happy', 'smiling'],
  'fun': ['happy'],
  'wedding': ['marriage', 'bride', 'groom'],
  'bride': ['wedding', 'marriage'],
  'dance': ['dancing'],
  'concert': ['music', 'show'],
  'musical instrument': ['music'],
  'guitar': ['music'],
  'sports': ['game', 'match'],
  'soccer': ['football', 'sports'],
  'cricket': ['sports'],
  'swimming': ['pool', 'swim'],
  'computer': ['laptop', 'pc'],
  'mobile phone': ['smartphone'],
  'television': ['tv'],
  'paper': ['document', 'page'],
  'receipt': ['bill', 'invoice'],
  'poster': ['banner'],
  'eyelash': ['face'],
  'sunglasses': ['glasses', 'shades'],
  'jeans': ['clothes'],
  'dress': ['clothes'],
  'shoe': ['shoes', 'footwear'],
  'jewellery': ['jewelry', 'gold'],
  'christmas': ['xmas', 'festival'],
  'fireworks': ['festival', 'diwali'],
  'temple': ['worship'],
  'night': ['dark'],
};

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

/// Text of [file] in which a search word may be found: its name, album,
/// date, device and camera, and any printed text in the photo.
String searchTextOf(StoredFile file, [PhotoContent? content]) {
  final when = file.taken ?? file.date;
  return [
    file.name,
    file.folder ?? '',
    '${when.year}',
    _months[when.month - 1],
    file.device ?? '',
    file.camera ?? '',
    content?.text ?? '',
  ].join(' ').toLowerCase();
}

/// Words describing [file] that a search word may start: its type, what
/// is in the photo, starred, and whether it has a place.
Set<String> searchKeywordsOf(StoredFile file, [PhotoContent? content]) => {
  ..._kindWords(file.kind).split(' '),
  if (file.starred) ...['starred', 'favourite', 'favorite'],
  if (file.location != null) ...['location', 'map', 'place'],
  ...?content?.keywords,
};

/// The words of a search, lower case.
List<String> searchWords(String query) => query
    .toLowerCase()
    .split(RegExp(r'[\s,]+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// Whether every word of [query] is found in [file]. "photos" also finds
/// "photo", and "beaches" finds "beach". A word must start a word of the
/// file ("cat" finds "cat" and "cats", not "vacation" or "location");
/// words of four letters or more are also found inside its name and text
/// ("shot" finds "Screenshot").
bool matchesSearch(StoredFile file, String query, [PhotoContent? content]) {
  final words = searchWords(query);
  if (words.isEmpty) return true;
  final text = searchTextOf(file, content);
  final own = {..._wordsOf(searchTextOf(file)), ...searchKeywordsOf(file)};
  final inPhoto = content == null ? const <String>{} : _photoWordsOf(content);
  return words.every(
    (w) => _variants(w).any(
      (v) =>
          (v.length >= 4 && text.contains(v)) ||
          own.any((s) => s.startsWith(v)) ||
          inPhoto.any((s) => s.startsWith(v)),
    ),
  );
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
