// Which photos the home-screen photo widget shows. Pure logic, no Flutter,
// so it is unit-testable.

import 'dart:convert';
import 'dart:math';

import 'faces.dart';
import 'search.dart';
import 'stored_file.dart';

enum WidgetSourceKind {
  /// Every photo in the drive.
  all,

  /// Starred photos.
  starred,

  /// Photos with at least one face.
  people,

  /// Photos with exactly one face.
  portraits,

  /// One album; [WidgetSource.value] is its folder.
  album,

  /// Photos of one thing ("Food", "Sky"); [WidgetSource.value] is its label.
  thing,

  /// Photos of one person; [WidgetSource.value] is from [encodePerson].
  person,
}

/// The user's choice of what the photo widget shows.
class WidgetSource {
  const WidgetSource(this.kind, [this.value = '']);

  static const all = WidgetSource(WidgetSourceKind.all);

  /// Reads a saved choice. Anything unreadable means all photos.
  factory WidgetSource.decode(String? saved) {
    try {
      final m = jsonDecode(saved ?? '');
      if (m is Map) {
        final kind = WidgetSourceKind.values
            .where((k) => k.name == m['kind'])
            .firstOrNull;
        if (kind != null) {
          return WidgetSource(kind, m['value'] as String? ?? '');
        }
      }
    } on Object {
      // Fall through.
    }
    return all;
  }

  final WidgetSourceKind kind;
  final String value;

  String encode() => jsonEncode({'kind': kind.name, 'value': value});

  String get title => switch (kind) {
    WidgetSourceKind.all => 'All photos',
    WidgetSourceKind.starred => 'Starred',
    WidgetSourceKind.people => 'People',
    WidgetSourceKind.portraits => 'Selfies & portraits',
    WidgetSourceKind.album => folderBaseName(value),
    WidgetSourceKind.thing => value,
    WidgetSourceKind.person => 'A person',
  };

  @override
  bool operator ==(Object other) =>
      other is WidgetSource && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// The photos [source] stands for. Vault photos are never shown.
List<StoredFile> widgetCandidates(
  Iterable<StoredFile> files,
  WidgetSource source,
  PhotoContent? Function(StoredFile file) contentOf,
) {
  final person = source.kind == WidgetSourceKind.person
      ? decodePerson(source.value)
      : null;
  bool wanted(StoredFile f) => switch (source.kind) {
    WidgetSourceKind.all => true,
    WidgetSourceKind.starred => f.starred,
    WidgetSourceKind.people => (contentOf(f)?.faces ?? 0) >= 1,
    WidgetSourceKind.portraits => contentOf(f)?.faces == 1,
    WidgetSourceKind.album =>
      f.folder == source.value ||
          (f.folder?.startsWith('${source.value}/') ?? false),
    WidgetSourceKind.thing =>
      contentOf(f)?.labels.contains(source.value) ?? false,
    WidgetSourceKind.person =>
      person != null &&
          showsPerson(
            contentOf(f)?.prints ?? const [],
            person.center,
            person.match,
          ),
  };
  return [
    for (final f in files)
      if (f.kind == FileKind.image && !f.isVault && wanted(f)) f,
  ];
}

/// Up to [max] of [candidates] in random order. Photos that are also on
/// this phone come first, because those can be shown sharp; the others
/// only have a small preview. At most [checks] photos are asked [isOnPhone].
List<StoredFile> pickWidgetPhotos(
  List<StoredFile> candidates, {
  required bool Function(StoredFile file) isOnPhone,
  required Random random,
  int max = 24,
  int checks = 200,
}) {
  final shuffled = [...candidates]..shuffle(random);
  final sharp = <StoredFile>[];
  final rest = <StoredFile>[];
  for (final f in shuffled) {
    if (sharp.length >= max) break;
    if (sharp.length + rest.length < checks && isOnPhone(f)) {
      sharp.add(f);
    } else {
      rest.add(f);
    }
  }
  return [...sharp, ...rest].take(max).toList();
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// What the widget writes under a photo: "3 years ago · Goa" on the day
/// the photo was taken, otherwise "November 2024 · Goa".
String widgetCaption(StoredFile file, [DateTime? now]) {
  final when = file.taken ?? file.date;
  final today = now ?? DateTime.now();
  final years = today.year - when.year;
  final date = years >= 1 && when.month == today.month && when.day == today.day
      ? (years == 1 ? '1 year ago today' : '$years years ago today')
      : '${_monthNames[when.month - 1]} ${when.year}';
  final album = file.folder == null ? '' : folderBaseName(file.folder!);
  // Albums made by backup are named after the phone's folders.
  const plain = {'Camera', 'DCIM', 'Pictures', 'Screenshots', 'Download'};
  return album.isEmpty || plain.contains(album) ? date : '$date · $album';
}
