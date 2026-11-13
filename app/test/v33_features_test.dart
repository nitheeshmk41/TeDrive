import 'package:tedrive/backup_plan.dart';
import 'package:tedrive/search.dart';
import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

StoredFile file(
  int id, {
  String? sha,
  String name = 'a.jpg',
  int size = 100,
  bool vault = false,
  DateTime? trashed,
}) => StoredFile(
  messageId: id,
  fileId: id,
  name: name,
  size: size,
  sha256: sha,
  isVault: vault,
  trashedAt: trashed,
  date: DateTime.fromMillisecondsSinceEpoch(1700000000000 + id * 1000),
);

void main() {
  group('findDuplicates', () {
    test('groups by SHA-256 and keeps the oldest first', () {
      final groups = findDuplicates([
        file(3, sha: 'x'),
        file(1, sha: 'x'),
        file(2, sha: 'y'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.first.map((f) => f.messageId), [1, 3]);
    });

    test('files without a hash match on name and size', () {
      final groups = findDuplicates([
        file(1, name: 'IMG.JPG'),
        file(2, name: 'img.jpg'),
        file(3, name: 'img.jpg', size: 101),
      ]);
      expect(groups.single.map((f) => f.messageId), [1, 2]);
    });

    test('ignores trash and vault', () {
      expect(
        findDuplicates([
          file(1, sha: 'x'),
          file(2, sha: 'x', vault: true),
          file(3, sha: 'x', trashed: DateTime(2026)),
        ]),
        isEmpty,
      );
    });

    test('biggest saving first', () {
      final groups = findDuplicates([
        file(1, sha: 's', size: 10),
        file(2, sha: 's', size: 10),
        file(3, sha: 'b', size: 1000),
        file(4, sha: 'b', size: 1000),
      ]);
      expect(groups.first.first.sha256, 'b');
    });
  });

  group('splitIntoParts', () {
    test('fills parts up to the limit', () {
      final parts = splitIntoParts([
        file(1, size: 40),
        file(2, size: 40),
        file(3, size: 40),
      ], 100);
      expect(parts.map((p) => p.length), [2, 1]);
    });

    test('a file bigger than a part gets its own', () {
      final parts = splitIntoParts([
        file(1, size: 10),
        file(2, size: 500),
        file(3, size: 10),
      ], 100);
      expect(parts.map((p) => p.map((f) => f.messageId).toList()), [
        [1],
        [2],
        [3],
      ]);
    });

    test('nothing to split', () {
      expect(splitIntoParts(const [], 100), isEmpty);
    });
  });

  group('backup frequency', () {
    final now = DateTime(2026, 11, 13, 21);

    test('instant always runs', () {
      expect(backupDue(BackupFrequency.instant, now, now), isTrue);
    });

    test('daily waits most of a day', () {
      expect(
        backupDue(
          BackupFrequency.daily,
          now.subtract(const Duration(hours: 3)),
          now,
        ),
        isFalse,
      );
      expect(
        backupDue(
          BackupFrequency.daily,
          now.subtract(const Duration(hours: 23)),
          now,
        ),
        isTrue,
      );
    });

    test('weekly waits most of a week', () {
      expect(
        backupDue(
          BackupFrequency.weekly,
          now.subtract(const Duration(days: 3)),
          now,
        ),
        isFalse,
      );
      expect(
        backupDue(
          BackupFrequency.weekly,
          now.subtract(const Duration(days: 7)),
          now,
        ),
        isTrue,
      );
    });

    test('never backed up runs at once', () {
      expect(backupDue(BackupFrequency.weekly, null, now), isTrue);
    });

    test('is saved with the settings', () {
      const s = BackupSettings(auto: true, frequency: BackupFrequency.weekly);
      expect(
        BackupSettings.decode(s.encode()).frequency,
        BackupFrequency.weekly,
      );
      expect(
        BackupSettings.decode('{"auto":true}').frequency,
        BackupFrequency.instant,
      );
    });
  });

  test('describeWhen', () {
    final now = DateTime(2026, 11, 13, 21);
    expect(describeWhen(DateTime(2026, 11, 13, 9, 5), now), 'Today 09:05');
    expect(describeWhen(DateTime(2026, 11, 12, 22), now), 'Yesterday 22:00');
    expect(describeWhen(DateTime(2026, 11, 3, 7, 30), now), '3 Nov 07:30');
  });

  group('search', () {
    final beach = file(1, name: 'IMG_1.jpg');
    const content = PhotoContent(labels: ['Beach', 'Sky'], faces: 2);
    PhotoContent? contentOf(StoredFile f) => f.messageId == 1 ? content : null;

    test('finds photos by what is in them', () {
      expect(
        filterFiles([beach], query: 'beach', contentOf: contentOf),
        hasLength(1),
      );
      expect(filterFiles([beach], query: 'beach'), isEmpty);
      expect(
        filterFiles([beach], query: 'receipt', contentOf: contentOf),
        isEmpty,
      );
    });

    test('every word must match, in any order, plurals too', () {
      expect(matchesSearch(beach, 'sky beaches', content), isTrue);
      expect(matchesSearch(beach, 'sky mountain', content), isFalse);
      expect(matchesSearch(beach, 'photos', content), isTrue);
    });

    test('faces', () {
      expect(matchesSearch(beach, 'people', content), isTrue);
      expect(matchesSearch(beach, 'group', content), isTrue);
      expect(matchesSearch(beach, 'selfie', content), isFalse);
      expect(
        matchesSearch(beach, 'selfie', const PhotoContent(faces: 1)),
        isTrue,
      );
    });

    test('type, year and month', () {
      final f = StoredFile(
        messageId: 9,
        fileId: 9,
        name: 'holiday.mp4',
        size: 1,
        folder: 'Trips/Goa',
        date: DateTime(2026, 11, 3),
      );
      expect(matchesSearch(f, 'video'), isTrue);
      expect(matchesSearch(f, 'videos 2026'), isTrue);
      expect(matchesSearch(f, 'november goa'), isTrue);
      expect(matchesSearch(f, 'photo'), isFalse);
      expect(matchesSearch(f, '2025'), isFalse);
    });

    test('text inside a photo', () {
      const c = PhotoContent(text: 'Total amount due 450.00 thank you');
      expect(matchesSearch(beach, 'amount 450', c), isTrue);
    });

    test('content survives saving', () {
      final back = PhotoContent.fromJson(content.toJson());
      expect(back.labels, content.labels);
      expect(back.faces, 2);
    });
  });

  group('smart albums', () {
    test('people, groups and common things', () {
      final photos = [for (var i = 1; i <= 6; i++) file(i)];
      PhotoContent? contentOf(StoredFile f) => switch (f.messageId) {
        1 || 2 || 3 => const PhotoContent(labels: ['Food'], faces: 1),
        4 => const PhotoContent(labels: ['Food'], faces: 3),
        5 => const PhotoContent(labels: ['Sky']),
        _ => null,
      };
      final albums = smartAlbums(photos, contentOf);
      expect(albums.map((a) => a.title), [
        'People',
        'Selfies & portraits',
        'Food',
      ]);
      expect(albums.first.files, hasLength(4));
      // Opening an album searches for it, and finds the same photos.
      for (final a in albums) {
        expect(
          filterFiles(photos, query: a.query, contentOf: contentOf),
          a.files,
        );
      }
    });

    test('nothing looked at yet', () {
      expect(smartAlbums([file(1)], (_) => null), isEmpty);
    });
  });

  test('groupThousands', () {
    expect(groupThousands(0), '0');
    expect(groupThousands(999), '999');
    expect(groupThousands(1234567), '1,234,567');
  });
}
