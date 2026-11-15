// Grouping faces that look alike, and finding a chosen person's photos.
// Pure logic, no Flutter, so it is unit-testable.
//
// Each face has a fingerprint worked out on the phone (1,024 numbers from
// -128 to 127). Two faces that look alike have fingerprints that point the
// same way; the closeness is the cosine between them, from -1 to 1.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// How close two faces must be to count as the same person.
enum FaceMatch {
  close('Close match', 0.86),
  balanced('Balanced', 0.80),
  loose('More photos', 0.74);

  const FaceMatch(this.label, this.threshold);
  final String label;
  final double threshold;
}

/// How alike two face fingerprints are: 1 for the same, lower for less.
double faceSimilarity(Int8List a, Int8List b) {
  if (a.length != b.length || a.isEmpty) return -1;
  var dot = 0, na = 0, nb = 0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    dot += x * y;
    na += x * x;
    nb += y * y;
  }
  if (na == 0 || nb == 0) return -1;
  return dot / sqrt(na.toDouble() * nb.toDouble());
}

/// One face in one photo.
class FaceRef {
  const FaceRef(this.messageId, this.index, this.print);
  final int messageId;

  /// Which face of the photo (its picture is `<messageId>_<index>.jpg`).
  final int index;
  final Int8List print;
}

/// Faces that look like the same person.
class PersonGroup {
  PersonGroup(this.faces, this.center);
  final List<FaceRef> faces;

  /// The fingerprint in the middle of the group, to find more photos with.
  final Int8List center;

  Set<int> get photos => {for (final f in faces) f.messageId};

  /// The face shown for the group: the one closest to its middle.
  FaceRef get cover => faces.reduce(
    (a, b) => faceSimilarity(a.print, center) >= faceSimilarity(b.print, center)
        ? a
        : b,
  );
}

/// Groups [faces] by person, biggest group first. Groups in fewer than
/// [minPhotos] photos are left out. At most [maxFaces] faces are used, so
/// that a large library stays quick.
List<PersonGroup> groupFaces(
  List<FaceRef> faces, {
  double threshold = 0.80,
  int minPhotos = 2,
  int maxFaces = 4000,
}) {
  final sums = <Float64List>[];
  final members = <List<FaceRef>>[];
  final centers = <Float64List>[];
  for (final face in faces.take(maxFaces)) {
    final v = _unit(face.print);
    if (v == null) continue;
    var best = -1, bestScore = threshold;
    for (var g = 0; g < centers.length; g++) {
      final s = _dot(v, centers[g]);
      if (s >= bestScore) {
        best = g;
        bestScore = s;
      }
    }
    if (best < 0) {
      sums.add(Float64List.fromList(v));
      centers.add(Float64List.fromList(v));
      members.add([face]);
    } else {
      final sum = sums[best];
      for (var i = 0; i < v.length; i++) {
        sum[i] += v[i];
      }
      centers[best] = _unit64(sum);
      members[best].add(face);
    }
  }
  final groups = <PersonGroup>[
    for (var g = 0; g < members.length; g++)
      if ({for (final f in members[g]) f.messageId}.length >= minPhotos)
        PersonGroup(members[g], _toPrint(centers[g])),
  ];
  groups.sort((a, b) => b.photos.length.compareTo(a.photos.length));
  return groups;
}

/// Whether any of [prints] is the person whose fingerprint is [person].
bool showsPerson(List<Int8List> prints, Int8List person, FaceMatch match) =>
    prints.any((p) => faceSimilarity(p, person) >= match.threshold);

/// A chosen person, stored as text: `balanced|<fingerprint in base64>`.
String encodePerson(Int8List center, FaceMatch match) =>
    '${match.name}|${base64Encode(Uint8List.sublistView(center))}';

({Int8List center, FaceMatch match})? decodePerson(String value) {
  final bar = value.indexOf('|');
  if (bar < 0) return null;
  final match = FaceMatch.values
      .where((m) => m.name == value.substring(0, bar))
      .firstOrNull;
  if (match == null) return null;
  try {
    final bytes = base64Decode(value.substring(bar + 1));
    if (bytes.isEmpty) return null;
    return (center: Int8List.sublistView(bytes), match: match);
  } on FormatException {
    return null;
  }
}

List<double>? _unit(Int8List p) {
  var n = 0;
  for (final x in p) {
    n += x * x;
  }
  if (n == 0) return null;
  final len = sqrt(n.toDouble());
  return [for (final x in p) x / len];
}

Float64List _unit64(Float64List v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  final len = sqrt(n);
  return Float64List.fromList([for (final x in v) len == 0 ? 0 : x / len]);
}

double _dot(List<double> a, Float64List b) {
  var s = 0.0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

Int8List _toPrint(Float64List unit) {
  // Scale so the largest part is 127, the same range as the phone's prints.
  var top = 0.0;
  for (final x in unit) {
    top = max(top, x.abs());
  }
  final scale = top == 0 ? 0 : 127 / top;
  return Int8List.fromList([
    for (final x in unit) (x * scale).round().clamp(-128, 127),
  ]);
}
