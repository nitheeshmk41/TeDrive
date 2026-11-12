import 'package:tedrive/stored_file.dart';
import 'package:test/test.dart';

const _sha =
    '383c77bfba9daab340231916497249bda3c31ea2ae72a3fdf67d61dd42bfdd66';

Json _file({
  int id = 7,
  int size = 1000,
  int expected = 1000,
  String path = '',
  bool complete = false,
}) => {
  '@type': 'file',
  'id': id,
  'size': size,
  'expected_size': expected,
  'local': {
    '@type': 'localFile',
    'path': path,
    'is_downloading_completed': complete,
    'downloaded_size': complete ? size : 0,
  },
  'remote': {'@type': 'remoteFile', 'uploaded_size': size},
};

Json _documentMessage({
  String name = 'VID_1.mp4',
  String caption = 'sha256:$_sha',
  Json? file,
}) => {
  '@type': 'message',
  'id': 3145728,
  'date': 1794472320,
  'content': {
    '@type': 'messageDocument',
    'document': {
      '@type': 'document',
      'file_name': name,
      'document': file ?? _file(),
    },
    'caption': {'@type': 'formattedText', 'text': caption},
  },
};

void main() {
  group('StoredFile.fromMessage', () {
    test('reads a document message with its hash', () {
      final f = StoredFile.fromMessage(_documentMessage())!;
      expect(f.messageId, 3145728);
      expect(f.fileId, 7);
      expect(f.name, 'VID_1.mp4');
      expect(f.size, 1000);
      expect(f.sha256, _sha);
      expect(f.localPath, isNull);
      expect(f.kind, FileKind.video);
      expect(f.date, DateTime.fromMillisecondsSinceEpoch(1794472320 * 1000));
    });

    test('has no hash when the caption has none or a malformed one', () {
      expect(
        StoredFile.fromMessage(_documentMessage(caption: ''))!.sha256,
        isNull,
      );
      expect(
        StoredFile.fromMessage(
          _documentMessage(caption: 'sha256:abc123'),
        )!.sha256,
        isNull,
      );
    });

    test('finds the hash inside a longer caption', () {
      final f = StoredFile.fromMessage(
        _documentMessage(caption: 'holiday\nsha256:$_sha'),
      )!;
      expect(f.sha256, _sha);
    });

    test('reports a local path only for a completed download', () {
      final partial = StoredFile.fromMessage(
        _documentMessage(file: _file(path: '/data/x.mp4')),
      )!;
      expect(partial.localPath, isNull);
      final complete = StoredFile.fromMessage(
        _documentMessage(file: _file(path: '/data/x.mp4', complete: true)),
      )!;
      expect(complete.localPath, '/data/x.mp4');
    });

    test('falls back to expected size and a generated name', () {
      final f = StoredFile.fromMessage(
        _documentMessage(name: '', file: _file(size: 0, expected: 555)),
      )!;
      expect(f.size, 555);
      expect(f.name, 'file_3145728');
    });

    test('reads video messages and the largest photo size', () {
      final video = StoredFile.fromMessage({
        'id': 1,
        'date': 0,
        'content': {
          '@type': 'messageVideo',
          'video': {'file_name': 'a.mov', 'video': _file(id: 11)},
          'caption': {'text': ''},
        },
      })!;
      expect(video.fileId, 11);
      expect(video.name, 'a.mov');

      final photo = StoredFile.fromMessage({
        'id': 2,
        'date': 0,
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            'sizes': [
              {'photo': _file(id: 20, size: 10)},
              {'photo': _file(id: 21, size: 900)},
            ],
          },
        },
      })!;
      expect(photo.fileId, 21);
      expect(photo.name, 'photo_2.jpg');
      expect(photo.kind, FileKind.image);
    });

    test('ignores messages without a file', () {
      expect(
        StoredFile.fromMessage({
          'id': 3,
          'date': 0,
          'content': {
            '@type': 'messageText',
            'text': {'text': 'hello'},
          },
        }),
        isNull,
      );
      expect(
        StoredFile.fromMessage({
          'id': 4,
          'date': 0,
          'content': {'@type': 'messageSupergroupChatCreate', 'title': 'x'},
        }),
        isNull,
      );
    });

    test('withLocalPath changes only the path', () {
      final f = StoredFile.fromMessage(_documentMessage())!;
      final g = f.withLocalPath('/cache/VID_1.mp4');
      expect(g.localPath, '/cache/VID_1.mp4');
      expect(g.messageId, f.messageId);
      expect(g.sha256, f.sha256);
      expect(g.withLocalPath(null).localPath, isNull);
    });
  });

  test('kindOf classifies by extension, ignoring case', () {
    expect(kindOf('IMG_1.JPG'), FileKind.image);
    expect(kindOf('clip.mp4'), FileKind.video);
    expect(kindOf('voice.opus'), FileKind.audio);
    expect(kindOf('bill.pdf'), FileKind.pdf);
    expect(kindOf('notes.docx'), FileKind.document);
    expect(kindOf('backup.tar.gz'), FileKind.archive);
    expect(kindOf('app.apk'), FileKind.apk);
    expect(kindOf('README'), FileKind.other);
    expect(kindOf('weird.'), FileKind.other);
  });

  test('formatBytes picks a readable unit', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(117043), '114.3 KB');
    expect(formatBytes(34603008), '33.0 MB');
    expect(formatBytes(maxUploadBytes), '1.95 GB');
  });

  test('formatDate is fixed-width and 24-hour', () {
    expect(formatDate(DateTime(2026, 11, 12, 14, 2)), '12 Nov 2026, 14:02');
    expect(formatDate(DateTime(2026, 1, 3, 9, 5)), '3 Jan 2026, 09:05');
  });

  test('safeFileName cannot escape its directory', () {
    expect(safeFileName('photo.jpg'), 'photo.jpg');
    expect(safeFileName('../../etc/passwd'), '.._.._etc_passwd');
    expect(safeFileName(r'a\b/c.txt'), 'a_b_c.txt');
    expect(safeFileName('..'), 'file');
    expect(safeFileName('  '), 'file');
  });

  test('searchFiles matches names case-insensitively', () {
    final files = [
      for (final n in ['Holiday.MP4', 'invoice.pdf', 'holiday2.jpg'])
        StoredFile.fromMessage(_documentMessage(name: n))!,
    ];
    expect(searchFiles(files, ''), files);
    expect(searchFiles(files, '  '), files);
    expect(searchFiles(files, 'HOLIDAY').map((f) => f.name), [
      'Holiday.MP4',
      'holiday2.jpg',
    ]);
    expect(searchFiles(files, 'zzz'), isEmpty);
  });

  group('captions and folders', () {
    test('buildCaption writes one key per line and skips empty ones', () {
      expect(buildCaption(sha256: _sha), 'sha256:$_sha');
      expect(
        buildCaption(sha256: _sha, folder: ' Goa  Trip '),
        'sha256:$_sha\nfolder:Goa Trip',
      );
      expect(buildCaption(folder: 'Bills'), 'folder:Bills');
      expect(buildCaption(sha256: _sha, folder: '   '), 'sha256:$_sha');
      expect(buildCaption(), '');
    });

    test('a caption round-trips through fromMessage', () {
      final f = StoredFile.fromMessage(
        _documentMessage(
          caption: buildCaption(sha256: _sha, folder: 'Goa Trip'),
        ),
      )!;
      expect(f.sha256, _sha);
      expect(f.folder, 'Goa Trip');
      expect(f.caption, 'sha256:$_sha\nfolder:Goa Trip');
      expect(f.withFolder(null).caption, 'sha256:$_sha');
      expect(f.withFolder('Bills').folder, 'Bills');
      // Changing the folder must not lose the hash or the local path.
      final moved = f.withLocalPath('/c/x').withFolder('Bills');
      expect(moved.sha256, _sha);
      expect(moved.localPath, '/c/x');
    });

    test('files uploaded before folders existed have none', () {
      expect(StoredFile.fromMessage(_documentMessage())!.folder, isNull);
      expect(
        StoredFile.fromMessage(
          _documentMessage(caption: 'sha256:$_sha\nfolder:'),
        )!.folder,
        isNull,
      );
    });

    test('normalizeFolder trims, flattens and caps the name', () {
      expect(normalizeFolder(null), isNull);
      expect(normalizeFolder(' \n '), isNull);
      expect(normalizeFolder('a\nb\tc'), 'a b c');
      expect(normalizeFolder('x' * 60)!.length, 40);
    });

    test('foldersOf lists each folder once, alphabetically', () {
      final files = [
        for (final folder in ['work', 'Bills', null, 'work', 'Aadhaar'])
          StoredFile.fromMessage(
            _documentMessage(caption: buildCaption(folder: folder)),
          )!,
      ];
      expect(foldersOf(files), ['Aadhaar', 'Bills', 'work']);
    });
  });

  group('thumbnails', () {
    Json withThumb(String format) => {
      'id': 9,
      'date': 0,
      'content': {
        '@type': 'messageDocument',
        'document': {
          'file_name': 'v.mp4',
          'document': _file(id: 30),
          'minithumbnail': {'width': 40, 'height': 22, 'data': 'AAAA'},
          'thumbnail': {
            'format': {'@type': format},
            'width': 320,
            'height': 180,
            'file': _file(id: 31),
          },
        },
        'caption': {'text': ''},
      },
    };

    test('reads the thumbnail file and inline preview', () {
      final f = StoredFile.fromMessage(withThumb('thumbnailFormatJpeg'))!;
      expect(f.thumbFileId, 31);
      expect(f.miniThumb, 'AAAA');
      expect(f.withFolder('x').thumbFileId, 31);
    });

    test('ignores animated thumbnail formats', () {
      final f = StoredFile.fromMessage(withThumb('thumbnailFormatMpeg4'))!;
      expect(f.thumbFileId, isNull);
      expect(f.miniThumb, 'AAAA');
    });

    test('has no thumbnail when the message carries none', () {
      final f = StoredFile.fromMessage(_documentMessage())!;
      expect(f.thumbFileId, isNull);
      expect(f.miniThumb, isNull);
    });

    test('photos use a mid-sized version as the preview', () {
      final f = StoredFile.fromMessage({
        'id': 2,
        'date': 0,
        'content': {
          '@type': 'messagePhoto',
          'photo': {
            'sizes': [
              {'width': 90, 'photo': _file(id: 20)},
              {'width': 320, 'photo': _file(id: 21)},
              {'width': 1280, 'photo': _file(id: 22)},
            ],
          },
        },
      })!;
      expect(f.fileId, 22);
      expect(f.thumbFileId, 21);
    });
  });

  group('gallery filters', () {
    StoredFile at(String name, DateTime date, {String? folder}) =>
        StoredFile.fromMessage({
          ..._documentMessage(
            name: name,
            caption: buildCaption(folder: folder),
          ),
          'date': date.millisecondsSinceEpoch ~/ 1000,
        })!;

    final files = [
      at('b.jpg', DateTime(2026, 11, 12), folder: 'Trip'),
      at('a.mp4', DateTime(2026, 11, 2), folder: 'Trip'),
      at('bill.pdf', DateTime(2026, 10, 30), folder: 'Bills'),
      at('song.mp3', DateTime(2026, 10, 1)),
      at('old.zip', DateTime(2025, 12, 31)),
    ];

    test('every file belongs to exactly one category besides All', () {
      for (final f in files) {
        final hits = Category.values
            .where((c) => c != Category.all && inCategory(f, c))
            .toList();
        expect(hits, hasLength(1), reason: f.name);
        expect(inCategory(f, Category.all), isTrue);
      }
    });

    test('filterFiles combines category, folder and search', () {
      expect(filterFiles(files), same(files));
      expect(
        filterFiles(files, category: Category.photos).map((f) => f.name),
        ['b.jpg'],
      );
      expect(filterFiles(files, folder: 'Trip').map((f) => f.name), [
        'b.jpg',
        'a.mp4',
      ]);
      expect(
        filterFiles(
          files,
          folder: 'Trip',
          category: Category.videos,
        ).map((f) => f.name),
        ['a.mp4'],
      );
      expect(
        filterFiles(files, category: Category.documents, query: 'BILL'),
        hasLength(1),
      );
      expect(filterFiles(files, folder: 'Trip', query: 'pdf'), isEmpty);
    });

    test('groupByMonth keeps order and splits on month and year', () {
      final groups = groupByMonth(files);
      expect(groups.map((g) => g.label), [
        'November 2026',
        'October 2026',
        'December 2025',
      ]);
      expect(groups.map((g) => g.files.length), [2, 2, 1]);
      expect(groups.first.files.first.name, 'b.jpg');
      expect(groupByMonth(const []), isEmpty);
    });
  });
}
