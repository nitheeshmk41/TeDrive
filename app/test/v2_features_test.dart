import 'package:tedrive/countries.dart';
import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

StoredFile _file({
  int id = 1,
  String name = 'a.jpg',
  int size = 100,
  int uploaded = 1700000000,
  String caption = '',
}) => StoredFile.fromMessage({
  'id': id,
  'date': uploaded,
  'content': {
    '@type': 'messageDocument',
    'document': {
      'file_name': name,
      'document': {'id': id, 'size': size, 'expected_size': size},
    },
    'caption': {'text': caption},
  },
})!;

const _sha = '383c77bfba9daab340231916497249bda3c31ea2ae72a3fdf67d61dd42bfdd66';

void main() {
  group('star and trash in captions', () {
    test('round-trip and survive other edits', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      final f = _file(caption: 'sha256:$_sha').withStar(true).withTrashedAt(at);
      expect(f.caption, 'sha256:$_sha\nstar:1\ntrash:1700000000');
      final back = _file(caption: f.caption);
      expect(back.starred, isTrue);
      expect(back.inTrash, isTrue);
      expect(back.trashedAt, at);
      final moved = back.withFolder('Trip').renamed('B.jpg');
      expect(moved.starred, isTrue);
      expect(moved.trashedAt, at);
      final restored = back.withTrashedAt(null).withStar(false);
      expect(restored.caption, 'sha256:$_sha');
    });

    test('old files have neither', () {
      final f = _file(caption: 'sha256:$_sha');
      expect(f.starred, isFalse);
      expect(f.inTrash, isFalse);
    });

    test('expiredTrash finds items older than 30 days', () {
      final now = DateTime(2026, 11, 30);
      final old = _file(id: 1).withTrashedAt(DateTime(2026, 10, 30));
      final fresh = _file(id: 2).withTrashedAt(DateTime(2026, 11, 20));
      final live = _file(id: 3);
      expect(expiredTrash([old, fresh, live], now), [old]);
    });
  });

  test('upload time is kept apart from the capture date', () {
    final f = _file(uploaded: 1700000000, caption: 'time:1600000000');
    expect(f.date, DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000));
    expect(f.uploaded, DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    expect(f.withStar(true).uploaded, f.uploaded);
  });

  test('recentFiles: last 30 days by upload, newest first', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
    final day = 86400;
    final a = _file(id: 1, uploaded: 1700000000 - day);
    final b = _file(id: 2, uploaded: 1700000000 - 2 * day);
    final c = _file(id: 3, uploaded: 1700000000 - 40 * day);
    expect(recentFiles([b, c, a], now).map((f) => f.messageId), [1, 2]);
  });

  test('largeFiles: biggest first, above the threshold', () {
    final files = [
      _file(id: 1, size: 5),
      _file(id: 2, size: 50),
      _file(id: 3, size: 20),
    ];
    expect(largeFiles(files, minBytes: 10).map((f) => f.messageId), [2, 3]);
  });

  test(
    'duplicateGroups: same SHA-256, oldest kept first, most waste first',
    () {
      const other =
          '1111111111111111111111111111111111111111111111111111111111111111';
      final files = [
        _file(id: 1, size: 10, uploaded: 300, caption: 'sha256:$_sha'),
        _file(id: 2, size: 10, uploaded: 100, caption: 'sha256:$_sha'),
        _file(id: 3, size: 500, uploaded: 200, caption: 'sha256:$other'),
        _file(id: 4, size: 500, uploaded: 100, caption: 'sha256:$other'),
        _file(id: 5, size: 999),
      ];
      final groups = duplicateGroups(files);
      expect(groups.map((g) => g.map((f) => f.messageId).toList()), [
        [4, 3],
        [2, 1],
      ]);
    },
  );

  test('onThisDay: same day in earlier years, photos and videos only', () {
    final now = DateTime(2026, 11, 12);
    DateTime at(int y) => DateTime(y, 11, 12, 10);
    StoredFile taken(int id, DateTime d, String name) => _file(
      id: id,
      name: name,
      caption: 'time:${d.millisecondsSinceEpoch ~/ 1000}',
    );
    final m = onThisDay([
      taken(1, at(2025), 'a.jpg'),
      taken(2, at(2023), 'b.mp4'),
      taken(3, at(2023), 'c.jpg'),
      taken(4, at(2026), 'today.jpg'),
      taken(5, at(2024), 'doc.pdf'),
      taken(6, DateTime(2025, 11, 13), 'next.jpg'),
    ], now);
    expect(m.map((e) => e.yearsAgo), [1, 3]);
    expect(m.last.files.length, 2);
  });

  group('phone numbers', () {
    final india = countryForIso('IN');
    test('country code is added, trunk zero dropped', () {
      expect(fullPhoneNumber(india, '98765 43210'), '+919876543210');
      expect(fullPhoneNumber(india, '098765-43210'), '+919876543210');
    });
    test('a number with its own code wins', () {
      expect(fullPhoneNumber(india, '+1 (415) 555-0100'), '+14155550100');
      expect(fullPhoneNumber(india, '0044 20 7946 0000'), '+442079460000');
    });
    test('lookup and search', () {
      expect(countryForIso('us').name, 'United States');
      expect(countryForIso('ZZ').iso, 'IN');
      expect(countryForIso(null).iso, 'IN');
      expect(searchCountries('ind').map((c) => c.iso), contains('IN'));
      expect(searchCountries('+44').map((c) => c.iso), contains('GB'));
      expect(countryForIso('IN').flag, '🇮🇳');
    });
  });
}
