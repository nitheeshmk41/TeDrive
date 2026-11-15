import 'dart:math';
import 'dart:typed_data';

import 'package:tedrive/faces.dart';
import 'package:tedrive/photo_widget_plan.dart';
import 'package:tedrive/search.dart';
import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

/// A fingerprint near [base]: the same person with a little [noise].
Int8List near(List<double> base, Random r, double noise) => Int8List.fromList([
  for (final x in base)
    ((x + (r.nextDouble() * 2 - 1) * noise) * 100).round().clamp(-128, 127),
]);

List<double> randomFace(Random r) => [
  for (var i = 0; i < 64; i++) r.nextDouble() * 2 - 1,
];

StoredFile photo(int id) => StoredFile(
  messageId: id,
  fileId: id,
  name: 'image.png',
  size: 1,
  date: DateTime(2023, 5, 1),
);

void main() {
  final r = Random(3);
  final me = randomFace(r), friend = randomFace(r);

  test('similar prints are close, different people are not', () {
    final a = near(me, r, 0.2), b = near(me, r, 0.2), c = near(friend, r, 0.2);
    expect(faceSimilarity(a, b), greaterThan(0.86));
    expect(faceSimilarity(a, c), lessThan(0.5));
    expect(faceSimilarity(a, a), closeTo(1, 1e-9));
    expect(faceSimilarity(a, Int8List(3)), -1);
  });

  test('groups faces by person, biggest first', () {
    final faces = [
      for (var i = 0; i < 5; i++) FaceRef(i, 0, near(me, r, 0.2)),
      for (var i = 5; i < 8; i++) FaceRef(i, 0, near(friend, r, 0.2)),
      FaceRef(9, 0, near(randomFace(r), r, 0.2)), // seen once: left out
    ];
    final groups = groupFaces(faces);
    expect(groups, hasLength(2));
    expect(groups[0].photos, {0, 1, 2, 3, 4});
    expect(groups[1].photos, {5, 6, 7});
  });

  test('the widget finds the chosen person and nobody else', () {
    final content = {
      1: PhotoContent(faces: 1, prints: [near(me, r, 0.2)]),
      2: PhotoContent(
        faces: 2,
        prints: [near(friend, r, 0.2), near(me, r, 0.2)],
      ),
      3: PhotoContent(faces: 1, prints: [near(friend, r, 0.2)]),
      4: const PhotoContent(),
    };
    final group = groupFaces([
      for (var i = 0; i < 4; i++) FaceRef(100 + i, 0, near(me, r, 0.2)),
    ]).single;
    final source = WidgetSource(
      WidgetSourceKind.person,
      encodePerson(group.center, FaceMatch.balanced),
    );
    expect(WidgetSource.decode(source.encode()), source);
    final found = widgetCandidates(
      [for (var i = 1; i <= 4; i++) photo(i)],
      source,
      (f) => content[f.messageId],
    );
    expect(found.map((f) => f.messageId), [1, 2]);
  });

  test('a damaged person choice finds nothing instead of failing', () {
    expect(decodePerson('nope'), isNull);
    expect(decodePerson('balanced|%%%'), isNull);
    final found = widgetCandidates(
      [photo(1)],
      const WidgetSource(WidgetSourceKind.person, 'x|y'),
      (_) => const PhotoContent(faces: 1),
    );
    expect(found, isEmpty);
  });

  test('face prints survive saving', () {
    final c = PhotoContent(faces: 1, prints: [near(me, r, 0.1)]);
    final back = PhotoContent.fromJson(c.toJson());
    expect(back.prints.single, c.prints.single);
  });

  test('widget caption', () {
    final f = StoredFile(
      messageId: 1,
      fileId: 1,
      name: 'a.jpg',
      size: 1,
      folder: 'Trips/Goa',
      date: DateTime(2021, 11, 15),
    );
    expect(widgetCaption(f, DateTime(2026, 11, 15)), '5 years ago today · Goa');
    expect(widgetCaption(f, DateTime(2026, 3, 1)), 'November 2021 · Goa');
    expect(widgetCaption(photo(1), DateTime(2026, 3, 1)), 'May 2023');
  });
}
