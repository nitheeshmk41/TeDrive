import 'package:tedrive/backup_plan.dart';
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

  test('content search matches every word', () {
    final f = file(1, name: 'IMG_1.jpg');
    bool inPhoto(StoredFile _, String q) =>
        q.split(' ').every('beach sky sunset'.contains);
    expect(
      filterFiles([f], query: 'beach', contentMatches: inPhoto),
      hasLength(1),
    );
    expect(filterFiles([f], query: 'beach'), isEmpty);
    expect(
      filterFiles([f], query: 'receipt', contentMatches: inPhoto),
      isEmpty,
    );
  });
}
