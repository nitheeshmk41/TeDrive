import 'package:tedrive/backup_plan.dart';
import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

MediaItem item(
  int id, {
  String album = 'Camera',
  int size = 100,
  int modified = 1000,
  int? time,
  bool video = false,
}) => MediaItem(
  id: id,
  path: '/storage/emulated/0/DCIM/$album/$id.jpg',
  name: '$id.jpg',
  size: size,
  modified: modified,
  time: time ?? modified,
  album: album,
  video: video,
);

void main() {
  group('MediaItem', () {
    test('fromMap reads what the Android side sends', () {
      final m = MediaItem.fromMap({
        'id': 42,
        'path': '/sdcard/DCIM/Camera/a.mp4',
        'name': 'a.mp4',
        'size': 5000,
        'modified': 1794472320,
        'time': 1794400000,
        'album': 'Camera',
        'video': true,
      });
      expect(m.id, 42);
      expect(m.video, isTrue);
      expect(m.key, '/sdcard/DCIM/Camera/a.mp4|5000|1794472320');
      expect(m.takenAt, DateTime.fromMillisecondsSinceEpoch(1794400000 * 1000));
    });

    test('the key changes when the file is edited', () {
      expect(item(1).key, item(1).key);
      expect(item(1).key, isNot(item(1, size: 101).key));
      expect(item(1).key, isNot(item(1, modified: 1001).key));
    });
  });

  group('BackupIndex', () {
    test('remembers hashes per file version', () {
      final index = BackupIndex();
      index.record(item(1), 'aaa');
      expect(index.shaOf(item(1)), 'aaa');
      expect(index.shaOf(item(2)), isNull);
      // An edited file must be hashed again.
      expect(index.shaOf(item(1, size: 999)), isNull);
    });

    test('survives a save and load', () {
      final index = BackupIndex()
        ..record(item(1), 'aaa')
        ..record(item(2), 'bbb');
      final loaded = BackupIndex.decode(index.encode());
      expect(loaded.length, 2);
      expect(loaded.shaOf(item(2)), 'bbb');
    });

    test('a damaged file gives an empty index instead of crashing', () {
      expect(BackupIndex.decode('not json').length, 0);
      expect(BackupIndex.decode('[1,2]').length, 0);
      expect(BackupIndex.decode('{"a": 5, "b": "ok"}').length, 1);
    });

    test('prune forgets files that are gone', () {
      final index = BackupIndex()
        ..record(item(1), 'aaa')
        ..record(item(2), 'bbb');
      index.prune([item(2)]);
      expect(index.length, 1);
      expect(index.shaOf(item(1)), isNull);
    });
  });

  group('BackupSettings', () {
    test('safe defaults: off, Wi-Fi only', () {
      const s = BackupSettings();
      expect(s.auto, isFalse);
      expect(s.unmeteredOnly, isTrue);
      expect(s.chargingOnly, isFalse);
      expect(s.albums, isNull);
      expect(BackupSettings.decode(null).unmeteredOnly, isTrue);
      expect(BackupSettings.decode('garbage').auto, isFalse);
    });

    test('round-trips through its saved form', () {
      final s = const BackupSettings().copyWith(
        auto: true,
        unmeteredOnly: false,
        chargingOnly: true,
        albums: {'Camera', 'WhatsApp Images'},
      );
      final back = BackupSettings.decode(s.encode());
      expect(back.auto, isTrue);
      expect(back.unmeteredOnly, isFalse);
      expect(back.chargingOnly, isTrue);
      expect(back.albums, {'Camera', 'WhatsApp Images'});
    });

    test('an empty album choice is kept, not reset to defaults', () {
      final s = const BackupSettings().copyWith(albums: {});
      expect(BackupSettings.decode(s.encode()).albums, isEmpty);
    });
  });

  group('albums', () {
    final items = [
      item(1),
      item(2),
      item(3, album: 'WhatsApp Images', size: 50),
      item(4, album: 'Download', size: 7),
    ];

    test('albumsOf counts items and bytes, biggest first', () {
      final albums = albumsOf(items);
      expect(albums.map((a) => a.name), [
        'Camera',
        'Download',
        'WhatsApp Images',
      ]);
      expect(albums.first.count, 2);
      expect(albums.first.bytes, 200);
    });

    test('defaultAlbums picks the usual ones', () {
      expect(defaultAlbums(albumsOf(items)), {'Camera', 'WhatsApp Images'});
    });

    test('defaultAlbums falls back to the biggest album', () {
      final odd = [item(1, album: 'Pictures'), item(2, album: 'Pictures')];
      expect(defaultAlbums(albumsOf(odd)), {'Pictures'});
      expect(defaultAlbums(const []), isEmpty);
    });
  });

  group('pendingBackup', () {
    final a = item(1, time: 300);
    final b = item(2, time: 100);
    final c = item(3, album: 'Screenshots', time: 200);

    test('lists unknown items in chosen albums, oldest first', () {
      final pending = pendingBackup(
        [a, b, c],
        albums: {'Camera'},
        index: BackupIndex(),
        driveShas: {},
      );
      expect(pending.map((i) => i.id), [2, 1]);
    });

    test('skips items whose hash is already in the drive', () {
      final index = BackupIndex()
        ..record(a, 'in-drive')
        ..record(b, 'not-in-drive');
      final pending = pendingBackup(
        [a, b],
        albums: {'Camera'},
        index: index,
        driveShas: {'in-drive'},
      );
      expect(pending.map((i) => i.id), [2]);
    });

    test('a file deleted from the drive becomes pending again', () {
      final index = BackupIndex()..record(a, 'gone');
      expect(
        pendingBackup([a], albums: {'Camera'}, index: index, driveShas: {}),
        hasLength(1),
      );
    });

    test('nothing is pending when no album is chosen', () {
      expect(
        pendingBackup(
          [a, b, c],
          albums: {},
          index: BackupIndex(),
          driveShas: {},
        ),
        isEmpty,
      );
    });
  });

  group('freeable (what may be deleted from the phone)', () {
    final a = item(1, size: 100);

    test('needs a hash AND a drive file with that hash and size', () {
      final index = BackupIndex()..record(a, 'sha-a');
      expect(freeable([a], index: index, driveSizeBySha: {'sha-a': 100}), [a]);
    });

    test('never frees a file that was not hashed', () {
      expect(
        freeable([a], index: BackupIndex(), driveSizeBySha: {'sha-a': 100}),
        isEmpty,
      );
    });

    test('never frees a file missing from the drive', () {
      final index = BackupIndex()..record(a, 'sha-a');
      expect(freeable([a], index: index, driveSizeBySha: {}), isEmpty);
      expect(
        freeable([a], index: index, driveSizeBySha: {'other': 100}),
        isEmpty,
      );
    });

    test('never frees when the drive copy has a different size', () {
      final index = BackupIndex()..record(a, 'sha-a');
      expect(
        freeable([a], index: index, driveSizeBySha: {'sha-a': 99}),
        isEmpty,
      );
    });

    test('never frees a file edited after it was hashed', () {
      final index = BackupIndex()..record(a, 'sha-a');
      final edited = item(1, size: 100, modified: 2000);
      expect(
        freeable([edited], index: index, driveSizeBySha: {'sha-a': 100}),
        isEmpty,
      );
    });
  });

  group('blockedReason', () {
    const wifiOnly = BackupSettings();
    test('allows Wi-Fi, blocks mobile data when Wi-Fi only', () {
      expect(
        blockedReason(wifiOnly, online: true, unmetered: true, charging: false),
        isNull,
      );
      expect(
        blockedReason(wifiOnly, online: true, unmetered: false, charging: true),
        'Waiting for Wi-Fi',
      );
    });

    test('mobile data is fine when the user allows it', () {
      expect(
        blockedReason(
          wifiOnly.copyWith(unmeteredOnly: false),
          online: true,
          unmetered: false,
          charging: false,
        ),
        isNull,
      );
    });

    test('offline and not-charging are reported', () {
      expect(
        blockedReason(
          wifiOnly,
          online: false,
          unmetered: false,
          charging: true,
        ),
        'Waiting for an internet connection',
      );
      expect(
        blockedReason(
          wifiOnly.copyWith(chargingOnly: true),
          online: true,
          unmetered: true,
          charging: false,
        ),
        'Waiting for the charger',
      );
    });
  });

  group('capture time in captions', () {
    const sha =
        '383c77bfba9daab340231916497249bda3c31ea2ae72a3fdf67d61dd42bfdd66';
    Json message(String caption, {int uploaded = 2000000000, int id = 1}) => {
      'id': id,
      'date': uploaded,
      'content': {
        '@type': 'messageDocument',
        'document': {
          'file_name': 'a.jpg',
          'document': {'id': id, 'size': 10, 'expected_size': 10},
        },
        'caption': {'text': caption},
      },
    };

    test('buildCaption adds the time and it reads back', () {
      final taken = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      final caption = buildCaption(sha256: sha, folder: 'Camera', taken: taken);
      expect(caption, 'sha256:$sha\nfolder:Camera\ntime:1700000000');
      final f = StoredFile.fromMessage(message(caption))!;
      expect(f.taken, taken);
      expect(f.date, taken);
      expect(f.sha256, sha);
      expect(f.folder, 'Camera');
      // Moving it to another folder must keep the time.
      expect(f.withFolder('Trip').caption, contains('time:1700000000'));
    });

    test('without a time the upload date is used', () {
      final f = StoredFile.fromMessage(message('sha256:$sha'))!;
      expect(f.taken, isNull);
      expect(f.date, DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000));
    });

    test('sortNewestFirst orders by capture time, stable on ties', () {
      final files = [
        StoredFile.fromMessage(message('time:100', id: 1))!,
        StoredFile.fromMessage(message('time:300', id: 2))!,
        StoredFile.fromMessage(message('time:300', id: 3))!,
        StoredFile.fromMessage(message('time:200', id: 4))!,
      ];
      expect(sortNewestFirst(files).map((f) => f.messageId), [2, 3, 4, 1]);
    });
  });
}
