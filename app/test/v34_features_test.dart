import 'dart:math';

import 'package:tedrive/photo_widget_plan.dart';
import 'package:tedrive/search.dart';
import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

StoredFile file(
  int id, {
  String name = 'image.png',
  String? folder,
  bool starred = false,
  bool vault = false,
  ({double lat, double lng})? location,
}) => StoredFile(
  messageId: id,
  fileId: id,
  name: name,
  size: 100,
  folder: folder,
  starred: starred,
  isVault: vault,
  location: location,
  date: DateTime(2024, 11, 3),
);

void main() {
  group('search by what is in a photo', () {
    const cat = PhotoContent(labels: ['Cat', 'Pet']);

    test('a cat in image.png is found by "cat"', () {
      expect(matchesSearch(file(1), 'cat', cat), isTrue);
      expect(matchesSearch(file(1), 'cats', cat), isTrue);
      expect(matchesSearch(file(1), 'Cat photo', cat), isTrue);
      expect(matchesSearch(file(1), 'cat'), isFalse);
    });

    test('other words for the same thing', () {
      expect(matchesSearch(file(1), 'kitten', cat), isTrue);
      expect(matchesSearch(file(1), 'animal', cat), isTrue);
      expect(matchesSearch(file(1), 'puppy', cat), isFalse);
      const beach = PhotoContent(labels: ['Beach']);
      expect(matchesSearch(file(1), 'sea', beach), isTrue);
      expect(matchesSearch(file(1), 'ocean', beach), isTrue);
    });

    test('labels of several words', () {
      const c = PhotoContent(labels: ['Musical instrument']);
      expect(matchesSearch(file(1), 'instrument', c), isTrue);
      expect(matchesSearch(file(1), 'music', c), isTrue);
    });

    test('a short word must start a word', () {
      // "cat" is inside "vacation" and "location", which are not cats.
      expect(matchesSearch(file(1, name: 'vacation.jpg'), 'cat'), isFalse);
      expect(
        matchesSearch(file(1, location: (lat: 1, lng: 2)), 'cat'),
        isFalse,
      );
      expect(matchesSearch(file(1, name: 'my_cat-01.jpg'), 'cat'), isTrue);
      expect(matchesSearch(file(1, name: 'Catalog.pdf'), 'cat'), isTrue);
    });

    test('longer words are also found inside names and text', () {
      final shot = file(1, name: 'Screenshot_2024.png');
      expect(matchesSearch(shot, 'shot'), isTrue);
      expect(matchesSearch(shot, 'screen 2024'), isTrue);
      const c = PhotoContent(text: 'Invoice no. INV-20391');
      expect(matchesSearch(file(1), '20391', c), isTrue);
      expect(matchesSearch(file(1), 'voice', c), isTrue);
    });

    test('starred and place', () {
      expect(matchesSearch(file(1, starred: true), 'starred'), isTrue);
      expect(matchesSearch(file(1), 'starred'), isFalse);
      expect(matchesSearch(file(1, location: (lat: 1, lng: 2)), 'map'), isTrue);
    });

    test('names in other scripts', () {
      expect(
        matchesSearch(file(1, name: 'குடும்பம் படம்.jpg'), 'படம்'),
        isTrue,
      );
    });
  });

  group('photo widget', () {
    final files = [
      file(1, folder: 'Camera'),
      file(2, folder: 'Camera', starred: true),
      file(3, folder: 'Trips/Goa'),
      file(4, folder: 'Trips'),
      file(5, name: 'clip.mp4', folder: 'Camera'),
      file(6, vault: true),
    ];
    PhotoContent? contentOf(StoredFile f) => switch (f.messageId) {
      1 => const PhotoContent(faces: 1, labels: ['Food']),
      2 => const PhotoContent(faces: 3),
      3 => const PhotoContent(labels: ['Food']),
      _ => null,
    };
    List<int> ids(WidgetSource s) => [
      for (final f in widgetCandidates(files, s, contentOf)) f.messageId,
    ];

    test('only photos, never the vault', () {
      expect(ids(WidgetSource.all), [1, 2, 3, 4]);
    });

    test('each kind of choice', () {
      expect(ids(const WidgetSource(WidgetSourceKind.starred)), [2]);
      expect(ids(const WidgetSource(WidgetSourceKind.people)), [1, 2]);
      expect(ids(const WidgetSource(WidgetSourceKind.portraits)), [1]);
      expect(ids(const WidgetSource(WidgetSourceKind.thing, 'Food')), [1, 3]);
      expect(ids(const WidgetSource(WidgetSourceKind.album, 'Camera')), [1, 2]);
      // An album includes its sub-albums.
      expect(ids(const WidgetSource(WidgetSourceKind.album, 'Trips')), [3, 4]);
    });

    test('the choice survives saving', () {
      const s = WidgetSource(WidgetSourceKind.album, 'Trips/Goa');
      expect(WidgetSource.decode(s.encode()), s);
      expect(s.title, 'Goa');
      expect(WidgetSource.decode(null), WidgetSource.all);
      expect(WidgetSource.decode('{"kind":"nope"}'), WidgetSource.all);
    });

    test('picks at random, photos on the phone first', () {
      final many = [for (var i = 1; i <= 100; i++) file(i)];
      final picked = pickWidgetPhotos(
        many,
        isOnPhone: (f) => f.messageId <= 10,
        random: Random(7),
        max: 24,
      );
      expect(picked, hasLength(24));
      expect(picked.toSet(), hasLength(24));
      expect(picked.take(10).every((f) => f.messageId <= 10), isTrue);
      final again = pickWidgetPhotos(
        many,
        isOnPhone: (f) => f.messageId <= 10,
        random: Random(8),
        max: 24,
      );
      expect(
        again.map((f) => f.messageId),
        isNot(picked.map((f) => f.messageId)),
      );
    });

    test('fewer photos than the widget holds', () {
      final picked = pickWidgetPhotos(
        [file(1), file(2)],
        isOnPhone: (_) => false,
        random: Random(1),
      );
      expect(picked, hasLength(2));
    });

    test('caption', () {
      expect(widgetCaption(file(1)), 'November 2024');
    });
  });
}
