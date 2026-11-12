import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

const _sha = '383c77bfba9daab340231916497249bda3c31ea2ae72a3fdf67d61dd42bfdd66';

Json _message(
  String caption, {
  String name = 'IMG_2041.jpg',
  int id = 1,
  int size = 1000,
  int date = 1700000000,
  String localPath = '',
}) => {
  'id': id,
  'date': date,
  'content': {
    '@type': 'messageDocument',
    'document': {
      'file_name': name,
      'document': {
        'id': id,
        'size': size,
        'expected_size': size,
        'local': {
          'path': localPath,
          'is_downloading_completed': localPath.isNotEmpty,
        },
      },
    },
    'caption': {'text': caption},
  },
};

void main() {
  group('rename', () {
    test('a renamed file shows its new name everywhere', () {
      final f = StoredFile.fromMessage(_message('sha256:$_sha'))!;
      expect(f.name, 'IMG_2041.jpg');
      expect(f.customName, isNull);

      final renamed = f.renamed('Goa sunset.jpg');
      expect(renamed.name, 'Goa sunset.jpg');
      expect(renamed.caption, 'sha256:$_sha\nname:Goa sunset.jpg');

      // What another device reads back from the channel.
      final seenElsewhere = StoredFile.fromMessage(_message(renamed.caption))!;
      expect(seenElsewhere.name, 'Goa sunset.jpg');
      expect(seenElsewhere.customName, 'Goa sunset.jpg');
      expect(seenElsewhere.sha256, _sha);
    });

    test('renaming keeps album, date, device and local copy', () {
      final taken = DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000);
      final f = StoredFile.fromMessage(
        _message(
          buildCaption(
            sha256: _sha,
            folder: 'Camera',
            taken: taken,
            device: 'Pixel 7',
          ),
          localPath: '/data/x.jpg',
        ),
      )!;
      final r = f.renamed('Beach.jpg');
      expect(r.folder, 'Camera');
      expect(r.taken, taken);
      expect(r.device, 'Pixel 7');
      expect(r.localPath, '/data/x.jpg');
      expect(r.kind, FileKind.image);
      // And moving it afterwards keeps the new name.
      expect(r.withFolder('Trip').name, 'Beach.jpg');
      expect(r.withFolder('Trip').caption, contains('name:Beach.jpg'));
    });

    test('cleanNewName restores a missing extension', () {
      expect(
        cleanNewName('Goa sunset', original: 'IMG_1.jpg'),
        'Goa sunset.jpg',
      );
      expect(cleanNewName('Goa.JPG', original: 'IMG_1.jpg'), 'Goa.JPG');
      expect(cleanNewName('notes', original: 'README'), 'notes');
      expect(cleanNewName('clip', original: 'VID.final.mp4'), 'clip.mp4');
    });

    test('cleanNewName strips path characters and line breaks', () {
      expect(
        cleanNewName('../../etc/passwd', original: 'a.txt'),
        '.. .. etc passwd.txt',
      );
      expect(cleanNewName('a\nb\\c', original: 'a.txt'), 'a b c.txt');
    });

    test('cleanNewName rejects empty names and caps the length', () {
      expect(cleanNewName('   ', original: 'a.jpg'), isNull);
      expect(cleanNewName('..', original: 'a.jpg'), isNull);
      expect(cleanNewName('', original: 'a.jpg'), isNull);
      final long = cleanNewName('x' * 300, original: 'a.jpg')!;
      expect(long.length, 124); // 120 characters plus ".jpg"
      expect(long, endsWith('.jpg'));
    });

    test('a caption cannot smuggle in a name with a path', () {
      final f = StoredFile.fromMessage(_message('name:../../evil.jpg'))!;
      expect(f.name, isNot(contains('/')));
    });

    test('an empty name line means not renamed', () {
      final f = StoredFile.fromMessage(_message('sha256:$_sha\nname:'))!;
      expect(f.name, 'IMG_2041.jpg');
      expect(f.customName, isNull);
    });
  });

  group('day labels', () {
    final now = DateTime(2026, 11, 12, 15, 30);

    test('today, yesterday, this year, other years', () {
      expect(dayLabel(DateTime(2026, 11, 12, 0, 5), now), 'Today');
      expect(dayLabel(DateTime(2026, 11, 11, 23, 59), now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 11, 10), now), 'Tue, 10 Nov');
      expect(dayLabel(DateTime(2026, 1, 1), now), 'Thu, 1 Jan');
      expect(dayLabel(DateTime(2025, 12, 31), now), '31 Dec 2025');
    });

    test('groupByDay splits newest-first files into day sections', () {
      StoredFile at(DateTime d, int id) => StoredFile.fromMessage(
        _message('', id: id, date: d.millisecondsSinceEpoch ~/ 1000),
      )!;
      final groups = groupByDay([
        at(DateTime(2026, 11, 12, 14), 1),
        at(DateTime(2026, 11, 12, 9), 2),
        at(DateTime(2026, 11, 11, 20), 3),
        at(DateTime(2026, 10, 30, 8), 4),
        at(DateTime(2025, 6, 1, 8), 5),
      ], now: now);
      expect(groups.map((g) => g.label), [
        'Today',
        'Yesterday',
        'Fri, 30 Oct',
        '1 Jun 2025',
      ]);
      expect(groups.map((g) => g.files.length), [2, 1, 1, 1]);
      expect(groupByDay(const [], now: now), isEmpty);
    });
  });

  test('DriveStats totals by type, device and local copies', () {
    final files = [
      StoredFile.fromMessage(
        _message(
          buildCaption(device: 'Pixel 7'),
          name: 'a.jpg',
          id: 1,
          size: 100,
          date: 1700000000,
          localPath: '/c/a.jpg',
        ),
      )!,
      StoredFile.fromMessage(
        _message(
          buildCaption(device: 'Pixel 7'),
          name: 'b.mp4',
          id: 2,
          size: 900,
          date: 1600000000,
        ),
      )!,
      StoredFile.fromMessage(
        _message('', name: 'c.pdf', id: 3, size: 50, date: 1650000000),
      )!,
    ];
    final stats = DriveStats(files);
    expect(stats.count, 3);
    expect(stats.bytes, 1050);
    expect(stats.localCount, 1);
    expect(stats.localBytes, 100);
    expect(
      stats.oldest,
      DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000),
    );
    expect(stats.byCategory[Category.photos], (count: 1, bytes: 100));
    expect(stats.byCategory[Category.videos], (count: 1, bytes: 900));
    expect(stats.byCategory[Category.documents], (count: 1, bytes: 50));
    expect(stats.byCategory[Category.audio], isNull);
    expect(stats.byDevice['Pixel 7'], (count: 2, bytes: 1000));
    expect(stats.byDevice['Unknown device'], (count: 1, bytes: 50));

    final empty = DriveStats(const []);
    expect(empty.count, 0);
    expect(empty.oldest, isNull);
  });
  group('share links', () {
    test('parseShareLink accepts public t.me post links only', () {
      expect(parseShareLink('https://t.me/tedrive_ab12cd34ef/57'), (
        link: 'https://t.me/tedrive_ab12cd34ef/57',
        username: 'tedrive_ab12cd34ef',
        post: 57,
      ));
      expect(parseShareLink('  https://t.me/abcde/1  ')?.post, 1);
      for (final bad in [
        null,
        '',
        'http://t.me/abcde/1',
        'https://t.me/c/123456/7',
        'https://t.me/abcde/0',
        'https://t.me/abc/7',
        'https://evil.example/abcde/7',
        'https://t.me/abcde/7?x=1',
        'https://t.me/abcde/7/extra',
      ]) {
        expect(parseShareLink(bad), isNull, reason: '$bad');
      }
    });

    test('a share link round-trips through the caption', () {
      final f = StoredFile.fromMessage(
        _message(buildCaption(sha256: _sha, folder: 'Trip')),
      )!;
      expect(f.shareLink, isNull);
      final shared = f.withShareLink('https://t.me/tedrive_x1y2z3w4v5/12');
      expect(
        shared.caption,
        'sha256:$_sha\nfolder:Trip\nshare:https://t.me/tedrive_x1y2z3w4v5/12',
      );
      final seen = StoredFile.fromMessage(_message(shared.caption))!;
      expect(seen.shareLink, 'https://t.me/tedrive_x1y2z3w4v5/12');
      expect(seen.renamed('B.jpg').shareLink, seen.shareLink);
      expect(seen.withFolder(null).shareLink, seen.shareLink);
      expect(seen.withShareLink(null).caption, isNot(contains('share:')));
    });

    test('a bad share line in a caption is ignored', () {
      final f = StoredFile.fromMessage(
        _message('share:https://phishing.example/x'),
      )!;
      expect(f.shareLink, isNull);
      expect(f.caption, isNot(contains('share:')));
    });

    test('randomShareUsername makes a valid public username', () {
      var i = 0;
      final name = randomShareUsername((max) => (i++ * 7) % max);
      expect(name, matches(RegExp(r'^tedrive_[a-z0-9]{10}$')));
      expect(parseShareLink('https://t.me/$name/1'), isNotNull);
    });
  });
}
